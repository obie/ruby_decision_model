# frozen_string_literal: true

require "test_helper"

# What a provider living in another gem can rely on: register itself, skip the
# API key when it has no service to authenticate against, and answer in-process
# instead of over HTTP. The fixture below is the whole contract, and needs no
# dependency to prove it.
class ExtensionTest < Minitest::Test
  # A provider that runs "the model" in this process. A real local provider,
  # such as one wrapping an on-disk model, differs only in what #answer does.
  class Local < RubyDecisionModel::Providers::Base
    attr_reader :calls

    def initialize(api_key: nil, base_url: nil, answer: 0.5)
      super(api_key: api_key, base_url: base_url)
      @answer = answer
      @calls = []
    end

    def name = :local
    def requires_api_key? = false
    def default_base_url = "local://memory"
    def endpoint_path = ""
    def default_model = "in-memory"

    def transport
      lambda do |url:, headers:, body:|
        @calls << { url: url, headers: headers, body: body }
        request = JSON.parse(body)
        answers = request["questions"].keys.to_h do |id|
          [id, { "type" => "noul", "noul" => @answer, "probabilities" => {} }]
        end
        [200, JSON.generate("model" => request["model"], "answers" => answers,
                            "usage" => { "input_tokens" => 7, "output_tokens" => 0 }), {}]
      end
    end
  end

  def questions
    { "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?") }
  end

  def teardown
    RubyDecisionModel::Providers::REGISTRY.delete(:local)
  end

  def test_a_provider_can_register_itself_and_be_named
    assert_equal :local, RubyDecisionModel::Providers.register(:local, Local)
    assert RubyDecisionModel::Providers.registered?(:local)
    assert_includes RubyDecisionModel::Providers.names, :local
    assert_instance_of Local, RubyDecisionModel::Providers.build(:local)

    client = RubyDecisionModel::Client.new(provider: :local)
    assert_equal :local, client.provider.name
    assert_equal "in-memory", client.model
  end

  def test_registering_refuses_anything_that_is_not_a_provider
    assert_raises(RubyDecisionModel::ConfigurationError) { RubyDecisionModel::Providers.register(:nope, String) }
    assert_raises(RubyDecisionModel::ConfigurationError) { RubyDecisionModel::Providers.register(:nope, "Local") }
    assert_raises(RubyDecisionModel::ConfigurationError) { RubyDecisionModel::Providers.register("", Local) }
  end

  def test_a_provider_with_no_credential_starts_without_one
    without_provider_env do
      provider = Local.new
      refute_predicate provider, :requires_api_key?
      assert_nil provider.env_var
      assert_silent { RubyDecisionModel::Client.new(provider: provider) }
    end
  end

  def test_a_hosted_provider_still_demands_its_key
    without_provider_env do
      error = assert_raises(RubyDecisionModel::ConfigurationError) do
        RubyDecisionModel::Client.new(provider: :typesafe)
      end
      assert_match(/api_key is required for typesafe/, error.message)
    end
  end

  def test_its_own_transport_answers_without_http
    provider = Local.new(answer: 0.82)
    response = RubyDecisionModel::Client.new(provider: provider).ask(state: "the site is down", questions: questions)

    assert_in_delta 0.82, response["urgent"].probability, 1e-9
    assert_equal 7, response.usage.input_tokens
    assert_equal "in-memory", response.model
    assert_equal 1, provider.calls.length, "the request went to the provider, not over the wire"
    assert_equal "local://memory", provider.calls.first[:url]
  end

  def test_an_injected_transport_still_wins
    provider = Local.new
    fake = FakeTransport.new([[200, JSON.generate(
      "model" => "stub",
      "answers" => { "urgent" => { "type" => "noul", "noul" => 0.1, "probabilities" => {} } },
      "usage" => { "input_tokens" => 1, "output_tokens" => 0 }
    )]])
    response = RubyDecisionModel::Client.new(provider: provider, transport: fake).ask(state: "x", questions: questions)

    assert_in_delta 0.1, response["urgent"].probability, 1e-9
    assert_empty provider.calls
    assert_equal 1, fake.calls.length
  end

  def test_the_retry_policy_still_applies_to_a_local_provider
    failing = Class.new(Local) do
      def transport
        @attempts = 0
        lambda do |url:, headers:, body:| # rubocop:disable Lint/UnusedBlockArgument
          @attempts += 1
          @attempts == 1 ? [529, "overloaded", {}] : [200, JSON.generate(
            "model" => "in-memory",
            "answers" => { "urgent" => { "type" => "noul", "noul" => 0.3, "probabilities" => {} } },
            "usage" => { "input_tokens" => 1, "output_tokens" => 0 }
          ), {}]
        end
      end
    end

    client = RubyDecisionModel::Client.new(provider: failing.new, sleeper: no_sleep)
    assert_in_delta 0.3, client.ask(state: "x", questions: questions)["urgent"].probability, 1e-9
  end
end
