# frozen_string_literal: true

require "test_helper"

# A transport that records the method it was asked for.
class MethodRecordingTransport
  attr_reader :calls

  def initialize(responses)
    @responses = responses
    @calls = []
  end

  def call(url:, headers:, body:, method: :post)
    @calls << { url: url, headers: headers, body: body, method: method }
    response = @responses.length > 1 ? @responses.shift : @responses.first
    raise response if response.is_a?(Exception)

    response
  end
end

class ModelsTest < Minitest::Test
  def model_list
    JSON.generate(
      "models" => [
        { "name" => "jev-latest", "description" => "Most recent stable release", "release_date" => "2026-02-11" },
        { "name" => "jev-preview", "description" => "Most recent release", "release_date" => "2026-02-11" }
      ]
    )
  end

  def typesafe_client(transport)
    RubyDecisionModel::Client.new(provider: :typesafe, api_key: "ts-key", transport: transport, sleeper: no_sleep,
                                  retry: { max_retries: 0 })
  end

  def test_models_returns_typed_cards
    client = typesafe_client(MethodRecordingTransport.new([[200, model_list]]))

    models = client.models

    assert_equal 2, models.size
    assert_equal "jev-latest", models.first.name
    assert_equal "Most recent stable release", models.first.description
    assert_equal "2026-02-11", models.first.release_date
    assert_instance_of RubyDecisionModel::ModelCard, models.first
  end

  def test_models_gets_the_documented_endpoint
    transport = MethodRecordingTransport.new([[200, model_list]])
    typesafe_client(transport).models

    call = transport.calls.first
    assert_equal "https://api.typesafe.ai/v1/models", call[:url]
    assert_equal :get, call[:method]
    assert_nil call[:body]
    assert_equal "Bearer ts-key", call[:headers]["Authorization"]
  end

  def test_asking_still_posts
    transport = MethodRecordingTransport.new([[200, JSON.generate(
      "answers" => { "q" => { "type" => "noul", "noul" => 0.5 } }, "usage" => {}
    )]])
    typesafe_client(transport).ask(state: {}, questions: { "q" => RubyDecisionModel::Questions.noul("Urgent?") })

    assert_equal :post, transport.calls.first[:method]
  end

  def test_a_provider_without_a_model_list_says_so
    client = RubyDecisionModel::Client.new(provider: :open_router, api_key: "or-key",
                                           transport: MethodRecordingTransport.new([]))

    error = assert_raises(RubyDecisionModel::ConfigurationError) { client.models }
    assert_match(/does not publish a model list/, error.message)
  end

  def test_a_transport_that_cannot_get_says_so
    # The old three-keyword contract has no way to ask for anything but a POST.
    client = typesafe_client(FakeTransport.new([[200, model_list]]))

    error = assert_raises(RubyDecisionModel::ConfigurationError) { client.models }
    assert_match(/no method: keyword/, error.message)
  end

  def test_errors_use_the_same_classes_as_asking
    client = typesafe_client(MethodRecordingTransport.new([[401, "nope", {}]]))

    assert_raises(RubyDecisionModel::Unauthorized) { client.models }
  end

  def test_a_model_list_that_is_not_an_object_is_rejected
    client = typesafe_client(MethodRecordingTransport.new([[200, "[]"]]))

    error = assert_raises(RubyDecisionModel::InvalidResponse) { client.models }
    assert_match(/not a JSON object/, error.message)
  end

  def test_a_missing_models_array_is_rejected
    client = typesafe_client(MethodRecordingTransport.new([[200, "{}"]]))

    error = assert_raises(RubyDecisionModel::InvalidResponse) { client.models }
    assert_match(/no models array/, error.message)
  end

  def test_an_entry_without_a_name_is_rejected
    body = JSON.generate("models" => [{ "description" => "nameless" }])
    client = typesafe_client(MethodRecordingTransport.new([[200, body]]))

    error = assert_raises(RubyDecisionModel::InvalidResponse) { client.models }
    assert_match(/no name/, error.message)
  end

  def test_an_entry_may_omit_description_and_release_date
    body = JSON.generate("models" => [{ "name" => "jev-1.13.0" }])
    client = typesafe_client(MethodRecordingTransport.new([[200, body]]))

    card = client.models.first
    assert_equal "jev-1.13.0", card.name
    assert_nil card.description
    assert_nil card.release_date
  end

  def test_an_empty_list_is_an_empty_array
    client = typesafe_client(MethodRecordingTransport.new([[200, JSON.generate("models" => [])]]))

    assert_empty client.models
  end

  def test_listing_is_retried_like_asking
    transport = MethodRecordingTransport.new([[503, "{}"], [200, model_list]])
    client = RubyDecisionModel::Client.new(provider: :typesafe, api_key: "k", transport: transport,
                                           sleeper: no_sleep, random: -> { 0.0 })

    assert_equal 2, client.models.size
    assert_equal 2, transport.calls.length
    assert_equal [:get, :get], transport.calls.map { |c| c[:method] }
  end

  # --- the provider's own view of it ---

  def test_provider_reports_whether_it_lists_models
    assert_predicate RubyDecisionModel::Providers::Typesafe.new, :lists_models?
    refute_predicate RubyDecisionModel::Providers::OpenRouter.new, :lists_models?
    assert_nil RubyDecisionModel::Providers::OpenRouter.new.models_url
  end

  def test_models_url_follows_a_base_url_override
    provider = RubyDecisionModel::Providers::Typesafe.new(base_url: "https://staging.typesafe.example")
    assert_equal "https://staging.typesafe.example/v1/models", provider.models_url
  end
end
