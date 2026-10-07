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

  def test_open_router_aliases_for_other_vendors_models
    provider = RubyDecisionModel::Providers::OpenRouter.new(api_key: "k")
    assert_equal "openai/gpt-6-luna-decisions", provider.resolve_model("luna")
    assert_equal "openai/gpt-6-luna-decisions", provider.resolve_model("gpt-6-luna")
    assert_equal "cloudflare/clef", provider.resolve_model("clef")
    assert_equal "cloudflare/clef-flash", provider.resolve_model("clef-flash")
    assert_equal "perplexity/pplx-decider-v1-27b", provider.resolve_model("pplx-decider")
    assert_equal "liquid/d1", provider.resolve_model("liquid/d1")
  end

  def test_short_names_work_on_the_vendors_own_provider
    assert_equal "gpt-6-luna", RubyDecisionModel::Providers::OpenAI.new(api_key: "k").resolve_model("luna")
    cloudflare = RubyDecisionModel::Providers::Cloudflare.new(api_key: "k", account_id: "a")
    assert_equal "clef-flash", cloudflare.resolve_model("clef-flash")
    assert_equal "clef", cloudflare.resolve_model("cloudflare/clef")
    assert_equal "jev-latest", RubyDecisionModel::Providers::Typesafe.new(api_key: "k").resolve_model("~typesafe/jev-latest")
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

  # --- environment selection beyond the first two providers ---

  def test_provider_env_var_names_a_provider
    without_provider_env do
      with_env("RUBY_DECISION_MODEL_PROVIDER" => "openai", "OPENAI_API_KEY" => "sk-env", "TYPESAFE_API_KEY" => "ts") do
        client = RubyDecisionModel::Client.new(transport: FakeTransport.new([]))
        assert_equal :openai, client.provider.name
        assert_equal "sk-env", client.provider.api_key
        assert_equal "gpt-6-luna", client.model
      end
    end
  end

  def test_provider_env_var_without_that_providers_key_names_the_key
    without_provider_env do
      with_env("RUBY_DECISION_MODEL_PROVIDER" => "perplexity", "TYPESAFE_API_KEY" => "ts") do
        error = assert_raises(RubyDecisionModel::ConfigurationError) do
          RubyDecisionModel::Client.new(transport: FakeTransport.new([]))
        end
        assert_includes error.message, "PERPLEXITY_API_KEY"
      end
    end
  end

  def test_provider_env_var_with_unknown_name_raises
    without_provider_env do
      with_env("RUBY_DECISION_MODEL_PROVIDER" => "nope") do
        assert_raises(RubyDecisionModel::ConfigurationError) do
          RubyDecisionModel::Client.new(transport: FakeTransport.new([]))
        end
      end
    end
  end

  def test_general_purpose_keys_do_not_pick_a_provider
    without_provider_env do
      with_env("OPENAI_API_KEY" => "sk", "PERPLEXITY_API_KEY" => "pplx", "CLOUDFLARE_API_TOKEN" => "cf",
               "CLOUDFLARE_ACCOUNT_ID" => "acc", "DATABRICKS_HOST" => "h", "DATABRICKS_TOKEN" => "t") do
        error = assert_raises(RubyDecisionModel::ConfigurationError) do
          RubyDecisionModel::Client.new(transport: FakeTransport.new([]))
        end
        assert_includes error.message, "RUBY_DECISION_MODEL_PROVIDER"
        assert_includes error.message, "SYSTEM_ONE_BASE_URL"
      end
    end
  end

  def test_open_router_beats_a_system_one_base_url
    without_provider_env do
      with_env("OPENROUTER_API_KEY" => "or", "SYSTEM_ONE_BASE_URL" => "http://localhost:11434") do
        assert_equal :open_router, RubyDecisionModel::Client.new(transport: FakeTransport.new([])).provider.name
      end
    end
  end

  def test_every_registered_provider_builds
    RubyDecisionModel::Providers.names.each do |name|
      provider = RubyDecisionModel::Providers.build(name, api_key: "k", base_url: "https://example.test")
      assert_equal name, provider.name
    end
  end

  # --- images ---

  def test_images_are_refused_by_providers_that_do_not_read_them
    transport = FakeTransport.new([[200, success_body, {}]])
    client = RubyDecisionModel::Client.new(provider: :typesafe, api_key: "k", transport: transport, sleeper: no_sleep)
    image = RubyDecisionModel::Images.data_url("x", content_type: "image/png")

    error = assert_raises(RubyDecisionModel::RequestError) { client.ask(state: {}, questions: questions, images: [image]) }
    assert_includes error.message, "typesafe"
    assert_empty transport.calls
  end

  def test_images_must_be_data_urls
    transport = FakeTransport.new([[200, success_body, {}]])
    client = RubyDecisionModel::Client.new(provider: :openai, api_key: "k", transport: transport, sleeper: no_sleep)

    assert_raises(RubyDecisionModel::RequestError) do
      client.ask(state: {}, questions: questions, images: ["https://example.test/cat.png"])
    end
    assert_empty transport.calls
  end

  def test_empty_images_are_ignored
    transport = FakeTransport.new([[200, success_body, {}]])
    client = RubyDecisionModel::Client.new(provider: :typesafe, api_key: "k", transport: transport, sleeper: no_sleep)

    client.ask(state: {}, questions: questions, images: [])
    refute JSON.parse(transport.calls.first[:body]).key?("images")
  end

  def test_image_data_url_and_from_file
    assert_equal "data:image/png;base64,aGk=", RubyDecisionModel::Images.data_url("hi", content_type: "image/png")
    assert_raises(ArgumentError) { RubyDecisionModel::Images.data_url("hi", content_type: "text/plain") }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "photo.JPG")
      File.binwrite(path, "\xFF\xD8".b)
      assert_equal "data:image/jpeg;base64,/9g=", RubyDecisionModel::Images.from_file(path)

      other = File.join(dir, "photo.bmp")
      File.binwrite(other, "BM")
      assert_raises(ArgumentError) { RubyDecisionModel::Images.from_file(other) }
      assert_equal "data:image/bmp;base64,Qk0=", RubyDecisionModel::Images.from_file(other, content_type: "image/bmp")
    end
  end

  # --- timeouts ---

  def test_timeout_defaults_come_from_the_provider
    build = lambda do |name, **options|
      RubyDecisionModel::Client.new(provider: name, api_key: "k", transport: FakeTransport.new([]), **options)
    end

    assert_equal 5, build.call(:open_router).timeout
    assert_equal 5, build.call(:typesafe).timeout
    assert_equal 30, build.call(:perplexity).timeout
    assert_equal 30, build.call(:openai).timeout
    assert_equal 30, build.call(:system_one, base_url: "http://localhost:11434").timeout
    assert_equal 12, build.call(:perplexity, timeout: 12).timeout
  end

  # --- vendor error messages ---

  def error_for(body, status: 400, provider: :open_router)
    transport = FakeTransport.new([[status, body, {}]])
    client = RubyDecisionModel::Client.new(provider: provider, api_key: "k", transport: transport, sleeper: no_sleep,
                                           retry: { max_retries: 0 })
    assert_raises(RubyDecisionModel::ApiError) { client.ask(state: {}, questions: questions) }
  end

  def test_error_message_reads_openai_style_bodies
    error = error_for('{"error":{"message":"Invalid model \'x\'.","type":"invalid_request_error","code":null}}')
    assert_equal "api error (status 400): Invalid model 'x'.", error.message
    assert_equal 400, error.status
  end

  def test_error_message_reads_cloudflare_errors_array
    body = '{"result":null,"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"messages":[]}'
    error = error_for(body, status: 401)
    assert_instance_of RubyDecisionModel::Unauthorized, error
    assert_equal "unauthorized: Authentication error", error.message
  end

  def test_error_message_reads_fastapi_detail
    body = '{"detail":[{"loc":["body","questions","urgency","score","criteria"],"msg":"List should have at least 2 items","type":"too_short"}]}'
    error = error_for(body, status: 422, provider: :typesafe)
    assert_instance_of RubyDecisionModel::UnprocessableEntity, error
    assert_equal "unprocessable entity: body.questions.urgency.score.criteria: List should have at least 2 items",
                 error.message
  end

  def test_error_message_reads_plain_message_and_string_error
    assert_equal "api error (status 403): AI functions are not enabled",
                 error_for('{"error_code":"PERMISSION_DENIED","message":"AI functions are not enabled"}', status: 403).message
    assert_equal "api error (status 404): Not Found", error_for('{"error":"Not Found"}', status: 404).message
  end

  def test_error_body_with_invalid_utf8_still_raises_api_error
    body = "{\"error\":{\"message\":\"upstream \xFF failed\"}}".b
    error = error_for(body, status: 502, provider: :openai)

    assert_instance_of RubyDecisionModel::ApiError, error
    assert_equal 502, error.status
    assert_equal "api error (status 502): upstream \uFFFD failed", error.message
  end

  def test_error_message_is_omitted_for_unreadable_bodies
    assert_equal "api error (status 500)", error_for("<html>oops</html>", status: 500).message
    assert_equal "api error (status 500)", error_for("{}", status: 500).message
    assert_equal "api error (status 500)", error_for('{"error":{"message":"  "}}', status: 500).message
  end

  def test_error_message_is_truncated
    error = error_for(JSON.generate("error" => { "message" => "x" * 2000 }))
    assert_operator error.message.length, :<, 600
    assert error.message.end_with?("...")
  end

  # --- request ids ---

  def test_open_router_keeps_reading_the_typesafe_request_id_header_as_in_0_1_0
    transport = FakeTransport.new([[200, success_body, { "x-typesafe-request-id" => "ts-req" }]])
    client = RubyDecisionModel::Client.new(provider: :open_router, api_key: "k", transport: transport, sleeper: no_sleep)

    assert_equal "ts-req", client.ask(state: {}, questions: questions).request_id
  end

  # --- providers written against 0.1.0 ---

  def legacy_provider_class
    Class.new(RubyDecisionModel::Providers::Base) do
      def name = :legacy
      def env_var = "LEGACY_DECISIONS_KEY"
      def default_base_url = "https://legacy.test"
      def endpoint_path = "/v1/systemone"
      def default_model = "m"
      def url = "https://legacy.test/custom"
    end
  end

  def test_provider_with_the_0_1_0_request_body_signature_still_works
    klass = Class.new(legacy_provider_class) do
      def request_body(model:, state:, questions:)
        JSON.generate("model" => model, "state" => state, "questions" => questions)
      end
    end
    transport = FakeTransport.new([[200, success_body, {}]])
    client = RubyDecisionModel::Client.new(provider: klass.new(api_key: "k"), transport: transport, sleeper: no_sleep)

    assert_in_delta 0.6, client.ask(state: {}, questions: questions)["urgent"].noul
    assert_equal %w[model state questions], JSON.parse(transport.calls.first[:body]).keys
    image = RubyDecisionModel::Images.data_url("x", content_type: "image/png")
    assert_raises(RubyDecisionModel::RequestError) { client.ask(state: {}, questions: questions, images: [image]) }
  end

  def test_provider_overriding_url_with_keyword_options_still_works
    klass = Class.new(legacy_provider_class) do
      def url(version: "v2") = "https://legacy.test/#{version}/systemone"
    end
    transport = FakeTransport.new([[200, success_body, {}]])
    client = RubyDecisionModel::Client.new(provider: klass.new(api_key: "k"), transport: transport, sleeper: no_sleep)

    client.ask(state: {}, questions: questions)
    assert_equal "https://legacy.test/v2/systemone", transport.calls.first[:url]
  end

  def test_provider_overriding_url_without_the_model_argument_still_works
    transport = FakeTransport.new([[200, success_body, { "x-typesafe-request-id" => "legacy-req" }]])
    client = RubyDecisionModel::Client.new(provider: legacy_provider_class.new(api_key: "k"), transport: transport,
                                           sleeper: no_sleep)

    response = client.ask(state: {}, questions: questions)
    assert_equal "https://legacy.test/custom", transport.calls.first[:url]
    assert_equal "legacy-req", response.request_id
  end

  # --- api_key: with a provider named in the environment ---

  def test_provider_names_ignore_case_and_dashes
    without_provider_env do
      with_env("RUBY_DECISION_MODEL_PROVIDER" => " OpenAI ", "OPENAI_API_KEY" => "sk") do
        assert_equal :openai, RubyDecisionModel::Client.new(transport: FakeTransport.new([])).provider.name
      end
    end
    assert_equal :open_router, RubyDecisionModel::Providers.build("Open-Router", api_key: "k").name
  end

  def test_whitespace_only_provider_env_var_is_ignored
    without_provider_env do
      with_env("RUBY_DECISION_MODEL_PROVIDER" => "   ", "OPENROUTER_API_KEY" => "or") do
        assert_equal :open_router, RubyDecisionModel::Client.new(transport: FakeTransport.new([])).provider.name
      end
    end
  end

  def test_api_key_goes_to_the_provider_named_in_the_environment
    without_provider_env do
      with_env("RUBY_DECISION_MODEL_PROVIDER" => "perplexity") do
        client = RubyDecisionModel::Client.new(api_key: "pplx-explicit", transport: FakeTransport.new([]))
        assert_equal :perplexity, client.provider.name
        assert_equal "pplx-explicit", client.provider.api_key
      end
    end
  end

  # --- keys and timeouts ---

  def test_trailing_newline_in_a_key_is_not_sent
    provider = RubyDecisionModel::Providers::OpenAI.new(api_key: "sk-from-a-file\n")
    assert_equal "Bearer sk-from-a-file", provider.headers["Authorization"]
  end

  def test_open_timeout_stays_short_unless_timeout_is_given
    perplexity = RubyDecisionModel::Client.new(provider: :perplexity, api_key: "k", transport: FakeTransport.new([]))
    assert_equal 30, perplexity.timeout
    assert_equal 5, perplexity.open_timeout

    explicit = RubyDecisionModel::Client.new(provider: :typesafe, api_key: "k", timeout: 12, transport: FakeTransport.new([]))
    assert_equal 12, explicit.timeout
    assert_equal 12, explicit.open_timeout
  end

  def test_default_transport_hands_both_timeouts_to_net_http
    http = RecordingHTTP.new(success_body)
    client = RubyDecisionModel::Client.new(provider: :perplexity, api_key: "k", sleeper: no_sleep)

    with_net_http(http) { client.ask(state: {}, questions: questions) }

    assert_equal 5, http.open_timeout
    assert_equal 30, http.read_timeout
    assert_equal 30, http.write_timeout
    assert http.use_ssl
    assert_equal 1, http.requests.length
  end

  def test_control_characters_in_vendor_text_become_spaces
    body = JSON.generate("error" => { "message" => "bad input\nINFO transaction approved\e[2J" })
    assert_equal "api error (status 400): bad input INFO transaction approved [2J", error_for(body).message
  end

  def test_keys_are_masked_from_eight_characters
    { "abc" => "bad abc", "abcdefg" => "bad abcdefg", "abcdefgh" => "bad [REDACTED]" }.each do |key, expected|
      provider = RubyDecisionModel::Providers::OpenAI.new(api_key: key)
      assert_equal expected, provider.error_message(JSON.generate("error" => { "message" => "bad #{key}" })), key
    end
  end

  def test_test_suite_hides_the_developers_provider_settings
    PROVIDER_ENV_VARS.each { |key| assert_nil ENV.fetch(key, nil), key }
  end

  def test_base_urls_from_the_environment_are_stripped
    with_env("SYSTEM_ONE_BASE_URL" => " http://localhost:11434/ \n", "DATABRICKS_HOST" => "adb-1.net \n") do
      assert_equal "http://localhost:11434/v1/systemone", RubyDecisionModel::Providers::SystemOne.new.url
      assert_equal "https://adb-1.net/api/2.0/ai-functions/ai-decide", RubyDecisionModel::Providers::Databricks.new.url
    end
  end

  def test_error_message_masks_an_echoed_api_key
    body = '{"error":{"message":"Incorrect API key provided: sk-live-0123456789abcdef"}}'
    transport = FakeTransport.new([[401, body, {}]])
    client = RubyDecisionModel::Client.new(provider: :openai, api_key: "sk-live-0123456789abcdef", transport: transport,
                                           sleeper: no_sleep)

    error = assert_raises(RubyDecisionModel::Unauthorized) { client.ask(state: "x", questions: questions) }
    refute_includes error.message, "sk-live-0123456789abcdef"
    assert_equal "unauthorized: Incorrect API key provided: [REDACTED]", error.message
    assert_includes error.body, "sk-live-0123456789abcdef"
  end

  def test_typesafe_reads_its_request_id_header
    transport = FakeTransport.new([[200, success_body, { "X-Typesafe-Request-Id" => "ts-req" }]])
    client = RubyDecisionModel::Client.new(provider: :typesafe, api_key: "k", transport: transport, sleeper: no_sleep)

    assert_equal "ts-req", client.ask(state: {}, questions: questions).request_id
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
