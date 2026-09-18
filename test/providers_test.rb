# frozen_string_literal: true

require "test_helper"

class ProvidersTest < Minitest::Test
  def success_body
    JSON.generate(
      "id" => "resp_1",
      "model" => "jev-1.13",
      "answers" => { "urgent" => { "type" => "noul", "noul" => 0.6, "probabilities" => {} } },
      "usage" => { "input_tokens" => 10, "output_tokens" => 2, "cost" => 0.5 }
    )
  end

  def questions
    { "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?") }
  end

  # --- selection ---

  def test_env_picks_typesafe_when_only_typesafe_key_is_set
    with_env("TYPESAFE_API_KEY" => "ts-key", "OPENROUTER_API_KEY" => nil) do
      client = RubyDecisionModel::Client.new(transport: FakeTransport.new([]))
      assert_instance_of RubyDecisionModel::Providers::Typesafe, client.provider
      assert_equal :typesafe, client.provider.name
      assert_equal "ts-key", client.provider.api_key
    end
  end

  def test_env_picks_open_router_when_only_open_router_key_is_set
    with_env("TYPESAFE_API_KEY" => nil, "OPENROUTER_API_KEY" => "or-key") do
      client = RubyDecisionModel::Client.new(transport: FakeTransport.new([]))
      assert_instance_of RubyDecisionModel::Providers::OpenRouter, client.provider
      assert_equal "or-key", client.provider.api_key
    end
  end

  def test_env_prefers_typesafe_when_both_keys_are_set
    with_env("TYPESAFE_API_KEY" => "ts-key", "OPENROUTER_API_KEY" => "or-key") do
      client = RubyDecisionModel::Client.new(transport: FakeTransport.new([]))
      assert_equal :typesafe, client.provider.name
    end
  end

  def test_explicit_provider_wins_over_env
    with_env("TYPESAFE_API_KEY" => "ts-key", "OPENROUTER_API_KEY" => "or-key") do
      client = RubyDecisionModel::Client.new(provider: :open_router, transport: FakeTransport.new([]))
      assert_equal :open_router, client.provider.name
      assert_equal "or-key", client.provider.api_key
    end
  end

  def test_explicit_provider_instance_is_used_as_is
    provider = RubyDecisionModel::Providers::Typesafe.new(api_key: "inst-key", base_url: "https://example.test/")
    client = RubyDecisionModel::Client.new(provider: provider, transport: FakeTransport.new([]))

    assert_same provider, client.provider
    assert_equal "https://example.test", client.base_url
  end

  def test_provider_instance_with_overrides_is_copied_not_mutated
    shared = RubyDecisionModel::Providers::OpenRouter.new(api_key: "shared-key")
    client_a = RubyDecisionModel::Client.new(provider: shared, api_key: "key-a", transport: FakeTransport.new([]))
    client_b = RubyDecisionModel::Client.new(provider: shared, api_key: "key-b", transport: FakeTransport.new([]))

    assert_equal "shared-key", shared.api_key
    assert_equal "key-a", client_a.provider.api_key
    assert_equal "key-b", client_b.provider.api_key
    refute_same shared, client_a.provider
  end

  def test_api_key_only_defaults_to_open_router
    with_env("TYPESAFE_API_KEY" => "ts-key", "OPENROUTER_API_KEY" => nil) do
      client = RubyDecisionModel::Client.new(api_key: "explicit", transport: FakeTransport.new([]))
      assert_equal :open_router, client.provider.name
      assert_equal "explicit", client.provider.api_key
      assert_equal "typesafe/jev-1.13", client.model
    end
  end

  def test_configuration_error_names_both_env_vars
    without_provider_env do
      error = assert_raises(RubyDecisionModel::ConfigurationError) do
        RubyDecisionModel::Client.new(transport: FakeTransport.new([]))
      end
      assert_includes error.message, "TYPESAFE_API_KEY"
      assert_includes error.message, "OPENROUTER_API_KEY"
    end
  end

  def test_explicit_provider_without_key_names_its_env_var
    without_provider_env do
      error = assert_raises(RubyDecisionModel::ConfigurationError) do
        RubyDecisionModel::Client.new(provider: :typesafe, transport: FakeTransport.new([]))
      end
      assert_includes error.message, "TYPESAFE_API_KEY"
    end
  end

  def test_explicit_provider_symbol_reads_key_from_env_when_api_key_omitted
    with_env("TYPESAFE_API_KEY" => "ts-key", "OPENROUTER_API_KEY" => nil) do
      client = RubyDecisionModel::Client.new(provider: :typesafe, transport: FakeTransport.new([]))
      assert_equal "ts-key", client.provider.api_key
    end
  end

  def test_provider_inspect_redacts_api_key
    provider = RubyDecisionModel::Providers::Typesafe.new(api_key: "super-secret")
    refute_includes provider.inspect, "super-secret"
    assert_includes provider.inspect, "[REDACTED]"
  end

  def test_open_router_usage_cost_missing_is_nil
    body = JSON.generate(
      "id" => "r", "model" => "m",
      "answers" => { "urgent" => { "type" => "noul", "noul" => 0.5, "probabilities" => {} } },
      "usage" => { "input_tokens" => 1, "output_tokens" => 1 }
    )
    transport = FakeTransport.new([[200, body, {}]])
    client = RubyDecisionModel::Client.new(provider: :open_router, api_key: "k", transport: transport, sleeper: no_sleep)
    assert_nil client.ask(state: {}, questions: questions).usage.cost
  end

  def test_unknown_provider_symbol_raises_configuration_error
    assert_raises(RubyDecisionModel::ConfigurationError) do
      RubyDecisionModel::Client.new(provider: :nope, api_key: "k", transport: FakeTransport.new([]))
    end
  end

  def test_provider_of_unsupported_type_raises_configuration_error
    assert_raises(RubyDecisionModel::ConfigurationError) do
      RubyDecisionModel::Client.new(provider: 123, api_key: "k", transport: FakeTransport.new([]))
    end
  end

  def test_base_url_overrides_provider_default
    client = RubyDecisionModel::Client.new(provider: :typesafe, api_key: "k", base_url: "http://localhost:9999/",
                                           transport: FakeTransport.new([]))
    assert_equal "http://localhost:9999", client.base_url
  end

  # --- aliases ---

  def test_open_router_aliases
    provider = RubyDecisionModel::Providers::OpenRouter.new(api_key: "k")
    assert_equal "typesafe/jev-1.13", provider.resolve_model("jev")
    assert_equal "typesafe/jev-1.13", provider.resolve_model("jev-latest")
    assert_equal "typesafe/jev-1.13", provider.resolve_model(nil)
    assert_equal "typesafe/jev-1.13", provider.resolve_model("typesafe/jev-1.13")
    assert_equal "some/other-model", provider.resolve_model("some/other-model")
  end

  def test_typesafe_aliases
    provider = RubyDecisionModel::Providers::Typesafe.new(api_key: "k")
    assert_equal "jev-latest", provider.resolve_model("typesafe/jev-1.13")
    assert_equal "jev-latest", provider.resolve_model("jev")
    assert_equal "jev-latest", provider.resolve_model(nil)
    assert_equal "jev-latest", provider.resolve_model("jev-latest")
    assert_equal "jev-1.12", provider.resolve_model("jev-1.12")
  end

  def test_client_model_is_resolved_after_aliasing
    client = RubyDecisionModel::Client.new(provider: :typesafe, api_key: "k", model: "jev",
                                           transport: FakeTransport.new([]))
    assert_equal "jev-latest", client.model
  end

  def test_configure_with_nil_overrides_preserves_existing_values
    provider = RubyDecisionModel::Providers::Typesafe.new(api_key: "key1", base_url: "https://a.test")
    provider.configure(api_key: nil, base_url: nil)

    assert_equal "key1", provider.api_key
    assert_equal "https://a.test", provider.base_url
  end

  def test_blank_api_key_is_not_present
    provider = RubyDecisionModel::Providers::Typesafe.new(api_key: "   ")
    refute provider.api_key?
  end

  # --- wire format ---

  def test_typesafe_request_url_headers_and_body
    transport = FakeTransport.new([[200, success_body, {}]])
    client = RubyDecisionModel::Client.new(provider: :typesafe, api_key: "ts-key", model: "jev",
                                           transport: transport, sleeper: no_sleep)

    client.ask(state: { a: 1 }, questions: questions)

    call = transport.calls.first
    assert_equal "https://api.typesafe.ai/v1/systemone", call[:url]
    assert_equal "Bearer ts-key", call[:headers]["Authorization"]
    assert_equal "application/json", call[:headers]["Content-Type"]
    assert_equal "ruby_decision_model/#{RubyDecisionModel::VERSION}", call[:headers]["User-Agent"]

    body = JSON.parse(call[:body])
    assert_equal "jev-latest", body["model"]
    assert_equal({ "a" => 1 }, body["state"])
    assert_equal %w[model state questions], body.keys
  end

  def test_open_router_request_url_and_user_agent
    transport = FakeTransport.new([[200, success_body, {}]])
    client = RubyDecisionModel::Client.new(api_key: "or-key", transport: transport, sleeper: no_sleep)

    client.ask(state: {}, questions: questions)

    call = transport.calls.first
    assert_equal "https://openrouter.ai/api/alpha/decisions", call[:url]
    assert_equal "Bearer or-key", call[:headers]["Authorization"]
    assert_equal "ruby_decision_model/#{RubyDecisionModel::VERSION}", call[:headers]["User-Agent"]
    assert_equal "typesafe/jev-1.13", JSON.parse(call[:body])["model"]
  end

  # --- usage and response passthrough ---

  def test_typesafe_usage_has_no_cost
    transport = FakeTransport.new([[200, success_body, {}]])
    client = RubyDecisionModel::Client.new(provider: :typesafe, api_key: "k", transport: transport, sleeper: no_sleep)

    response = client.ask(state: {}, questions: questions)

    assert_equal 10, response.usage.input_tokens
    assert_equal 2, response.usage.output_tokens
    assert_nil response.usage.cost
  end

  def test_open_router_usage_has_cost
    transport = FakeTransport.new([[200, success_body, {}]])
    client = RubyDecisionModel::Client.new(provider: :open_router, api_key: "k", transport: transport,
                                           sleeper: no_sleep)

    response = client.ask(state: {}, questions: questions)

    assert_in_delta 0.5, response.usage.cost
  end

  def test_response_model_is_passed_through_as_returned
    transport = FakeTransport.new([[200, success_body, {}]])
    client = RubyDecisionModel::Client.new(provider: :typesafe, api_key: "k", model: "jev", transport: transport,
                                           sleeper: no_sleep)

    response = client.ask(state: {}, questions: questions)

    assert_equal "jev-1.13", response.model
  end

  # --- module-level default client ---

  def test_module_client_is_memoized_and_resettable
    with_env("TYPESAFE_API_KEY" => "ts-key", "OPENROUTER_API_KEY" => nil) do
      RubyDecisionModel.client = nil
      first = RubyDecisionModel.client
      assert_same first, RubyDecisionModel.client
      assert_equal :typesafe, first.provider.name

      RubyDecisionModel.client = nil
      refute_same first, RubyDecisionModel.client
    end
  ensure
    RubyDecisionModel.client = nil
  end
end
