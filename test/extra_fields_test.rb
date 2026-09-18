# frozen_string_literal: true

require "test_helper"

# Top-level request fields beyond model, state, and questions.
class ExtraFieldsTest < Minitest::Test
  def questions
    { "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?") }
  end

  def success_body
    JSON.generate("answers" => { "urgent" => { "type" => "noul", "noul" => 0.5 } }, "usage" => {})
  end

  def transport
    @transport ||= FakeTransport.new([[200, success_body]])
  end

  def client(**options)
    RubyDecisionModel::Client.new(**{ api_key: "k", transport: transport, sleeper: no_sleep }.merge(options))
  end

  def sent_body
    JSON.parse(transport.calls.first[:body])
  end

  def test_no_extra_fields_by_default
    client.ask(state: "hello", questions: questions)

    assert_equal %w[model questions state], sent_body.keys.sort
  end

  def test_open_routers_documented_fields_can_be_sent
    client.ask(state: "hello", questions: questions,
               extra: { "session_id" => "conv_1", "user" => "u_42" })

    assert_equal "conv_1", sent_body["session_id"]
    assert_equal "u_42", sent_body["user"]
  end

  def test_symbol_keys_are_stringified
    client.ask(state: "hello", questions: questions, extra: { session_id: "conv_1" })

    assert_equal "conv_1", sent_body["session_id"]
  end

  def test_structured_values_survive
    client.ask(state: "hello", questions: questions,
               extra: { "provider" => { "order" => %w[typesafe] }, "trace" => { "enabled" => true } })

    assert_equal({ "order" => %w[typesafe] }, sent_body["provider"])
    assert_equal({ "enabled" => true }, sent_body["trace"])
  end

  def test_the_required_fields_still_arrive
    client.ask(state: "hello", questions: questions, extra: { "user" => "u" })

    assert_equal "typesafe/jev-1.13", sent_body["model"]
    assert_equal "hello", sent_body["state"]
    assert_equal %w[urgent], sent_body["questions"].keys
  end

  def test_extra_may_not_overwrite_the_required_fields
    %w[model state questions].each do |reserved|
      error = assert_raises(RubyDecisionModel::RequestError) do
        client.ask(state: "hello", questions: questions, extra: { reserved => "hijacked" })
      end
      assert_match(/must not set #{reserved}/, error.message)
    end
  end

  def test_keys_that_collide_once_stringified_are_refused
    assert_raises(RubyDecisionModel::RequestError) do
      client.ask(state: "hello", questions: questions, extra: { :user => "a", "user" => "b" })
    end
  end

  def test_extra_must_be_a_hash
    assert_raises(RubyDecisionModel::RequestError) do
      client.ask(state: "hello", questions: questions, extra: [%w[user u]])
    end
  end

  def test_extra_does_not_leak_between_calls
    transport = FakeTransport.new([[200, success_body], [200, success_body]])
    c = RubyDecisionModel::Client.new(api_key: "k", transport: transport, sleeper: no_sleep)

    c.ask(state: {}, questions: questions, extra: { "user" => "u" })
    c.ask(state: {}, questions: questions)

    assert_equal "u", JSON.parse(transport.calls[0][:body])["user"]
    refute JSON.parse(transport.calls[1][:body]).key?("user")
  end

  # --- providers written against the old signature ---

  def legacy_provider_class
    Class.new(RubyDecisionModel::Providers::Base) do
      def name = :legacy
      def env_var = "LEGACY_API_KEY"
      def default_base_url = "https://legacy.example"
      def endpoint_path = "/decide"
      def default_model = "legacy-1"

      def request_body(model:, state:, questions:)
        JSON.generate("m" => model, "s" => state, "q" => questions)
      end
    end
  end

  def test_a_provider_without_the_extra_keyword_still_works_without_extra
    c = RubyDecisionModel::Client.new(provider: legacy_provider_class.new(api_key: "k"),
                                       transport: transport, sleeper: no_sleep)

    c.ask(state: "hello", questions: questions)

    assert_equal %w[m q s], sent_body.keys.sort
  end

  def test_a_provider_without_the_extra_keyword_says_so_rather_than_dropping_fields
    c = RubyDecisionModel::Client.new(provider: legacy_provider_class.new(api_key: "k"),
                                       transport: transport, sleeper: no_sleep)

    error = assert_raises(RubyDecisionModel::ConfigurationError) do
      c.ask(state: "hello", questions: questions, extra: { "user" => "u" })
    end
    assert_match(/cannot send extra fields/, error.message)
    assert_empty transport.calls
  end
end
