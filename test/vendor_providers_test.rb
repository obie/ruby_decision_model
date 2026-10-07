# frozen_string_literal: true

require "test_helper"

# Cloudflare, Perplexity, Databricks, and generic System One servers. Each
# speaks a near relative of System One; these pin the differences.
class VendorProvidersTest < Minitest::Test
  Q = RubyDecisionModel::Questions

  def questions
    {
      "urgent" => Q.noul("Is this urgent?"),
      "team" => Q.choice("Which team?", criteria: { "billing" => "Payments", "technical" => nil }),
      "severity" => Q.score("How severe?", criteria: ["No impact", "Minor", "Major"])
    }
  end

  def system_one_answers
    {
      "urgent" => { "type" => "noul", "noul" => 0.9 },
      "team" => { "type" => "choice", "choice" => "billing", "confidence" => 0.8,
                  "probabilities" => { "billing" => 0.85, "technical" => 0.15 } },
      "severity" => { "type" => "score", "score" => 1.6, "confidence" => 0.7,
                      "probabilities" => { "0" => 0.1, "1" => 0.2, "2" => 0.7 },
                      "legend" => { "0" => "No impact", "1" => "Minor", "2" => "Major" } }
    }
  end

  def png
    RubyDecisionModel::Images.data_url("\x89PNG".b, content_type: "image/png")
  end

  # --- Cloudflare ---

  def cloudflare_body
    JSON.generate(
      "result" => { "model" => "clef", "answers" => system_one_answers,
                    "usage" => { "input_tokens" => 50, "output_tokens" => 0 } },
      "success" => true, "errors" => [], "messages" => []
    )
  end

  def cloudflare(transport, **options)
    provider = RubyDecisionModel::Providers::Cloudflare.new(api_key: "cf-token", account_id: "acc123")
    RubyDecisionModel::Client.new(provider: provider, transport: transport, sleeper: no_sleep, **options)
  end

  def test_cloudflare_requires_an_account_id
    without_provider_env do
      error = assert_raises(RubyDecisionModel::ConfigurationError) do
        RubyDecisionModel::Client.new(provider: :cloudflare, api_key: "cf-token", transport: FakeTransport.new([]))
      end
      assert_includes error.message, "CLOUDFLARE_ACCOUNT_ID"
    end
  end

  def test_cloudflare_reads_token_and_account_from_env
    without_provider_env do
      with_env("CLOUDFLARE_AUTH_TOKEN" => "auth-token", "CLOUDFLARE_ACCOUNT_ID" => "env-acc") do
        provider = RubyDecisionModel::Client.new(provider: :cloudflare, transport: FakeTransport.new([])).provider
        assert_equal "auth-token", provider.api_key
        assert_equal "env-acc", provider.account_id
      end

      with_env("CLOUDFLARE_API_TOKEN" => "api-token", "CLOUDFLARE_AUTH_TOKEN" => "auth-token",
               "CLOUDFLARE_ACCOUNT_ID" => "env-acc") do
        assert_equal "api-token", RubyDecisionModel::Providers::Cloudflare.new.api_key
      end
    end
  end

  def test_cloudflare_puts_the_model_in_the_path_and_the_body
    transport = FakeTransport.new([[200, cloudflare_body, {}]])
    cloudflare(transport, model: "cloudflare/clef-flash").ask(state: "Checkout is down", questions: questions)

    call = transport.calls.first
    assert_equal "https://api.cloudflare.com/client/v4/accounts/acc123/ai/run/@cf/cloudflare/clef-flash", call[:url]
    assert_equal "Bearer cf-token", call[:headers]["Authorization"]
    body = JSON.parse(call[:body])
    assert_equal "clef-flash", body["model"]
    assert_equal %w[model state questions], body.keys
  end

  def test_cloudflare_default_model_is_clef
    transport = FakeTransport.new([[200, cloudflare_body, {}]])
    client = cloudflare(transport)
    client.ask(state: "x", questions: questions)

    assert_equal "clef", client.model
    assert transport.calls.first[:url].end_with?("/@cf/cloudflare/clef")
  end

  def test_cloudflare_unwraps_the_envelope
    transport = FakeTransport.new([[200, cloudflare_body, { "cf-ray" => "8a1b2c3d-SJC" }]])
    response = cloudflare(transport).ask(state: "x", questions: questions)

    assert_in_delta 0.9, response["urgent"].noul
    assert_in_delta 0.1, response["urgent"].probabilities["false"]
    assert_equal "billing", response["team"].choice
    assert_equal "Major", response["severity"].legend["2"]
    assert_equal "clef", response.model
    assert_equal 50, response.usage.input_tokens
    assert_nil response.usage.cost
    assert_equal "8a1b2c3d-SJC", response.request_id
    assert response.raw["success"]
  end

  def test_cloudflare_accepts_an_unwrapped_body
    body = JSON.generate("model" => "clef", "answers" => system_one_answers, "usage" => {})
    response = cloudflare(FakeTransport.new([[200, body, {}]])).ask(state: "x", questions: questions)

    assert_equal "billing", response["team"].choice
  end

  def test_cloudflare_sends_images_as_the_images_extension
    transport = FakeTransport.new([[200, cloudflare_body, {}]])
    cloudflare(transport).ask(state: "What is shown?", questions: questions, images: [png])

    assert_equal [png], JSON.parse(transport.calls.first[:body])["images"]
  end

  def test_cloudflare_blank_api_token_falls_back_to_auth_token
    without_provider_env do
      with_env("CLOUDFLARE_API_TOKEN" => "  ", "CLOUDFLARE_AUTH_TOKEN" => "auth-token", "CLOUDFLARE_ACCOUNT_ID" => "acc") do
        assert_equal "auth-token", RubyDecisionModel::Providers::Cloudflare.new.api_key
      end
    end
  end

  def test_cloudflare_rejects_account_ids_and_models_that_would_leave_the_path
    assert_raises(RubyDecisionModel::ConfigurationError) do
      RubyDecisionModel::Client.new(provider: RubyDecisionModel::Providers::Cloudflare.new(api_key: "k", account_id: "../user/tokens"),
                                    transport: FakeTransport.new([]))
    end
    assert_raises(RubyDecisionModel::ConfigurationError) do
      cloudflare(FakeTransport.new([]), model: "../../user/tokens?x=")
    end
  end

  def test_cloudflare_success_false_raises_with_the_vendor_errors
    body = JSON.generate("result" => nil, "success" => false,
                         "errors" => [{ "code" => 3040, "message" => "Capacity temporarily exceeded" }], "messages" => [])
    error = assert_raises(RubyDecisionModel::InvalidResponse) do
      cloudflare(FakeTransport.new([[200, body, {}]])).ask(state: "x", questions: questions)
    end
    refute_kind_of RubyDecisionModel::MissingAnswers, error
    assert_equal "cloudflare reported failure: Capacity temporarily exceeded", error.message
  end

  def test_cloudflare_rechecks_the_path_after_configure
    provider = RubyDecisionModel::Providers::Cloudflare.new(api_key: "k", account_id: "acc123")
    transport = FakeTransport.new([[200, cloudflare_body, {}]])
    client = RubyDecisionModel::Client.new(provider: provider, transport: transport, sleeper: no_sleep)
    provider.configure(account_id: "acc1/../../user/tokens")

    assert_raises(RubyDecisionModel::ConfigurationError) { client.ask(state: "x", questions: questions) }
    assert_empty transport.calls
  end

  def test_cloudflare_account_id_is_stripped
    provider = RubyDecisionModel::Providers::Cloudflare.new(api_key: "k", account_id: "acc123\n")
    assert provider.configured?
    assert_equal "acc123", provider.account_id
    assert_equal "acc456", provider.dup.configure(account_id: " acc456 ").account_id
  end

  def test_cloudflare_and_databricks_failure_messages_mask_the_key
    key = "cf-secret-token-123456"
    body = JSON.generate("success" => false, "errors" => [{ "message" => "bad token #{key}" }])
    provider = RubyDecisionModel::Providers::Cloudflare.new(api_key: key, account_id: "acc123")
    client = RubyDecisionModel::Client.new(provider: provider, transport: FakeTransport.new([[200, body, {}]]),
                                           sleeper: no_sleep)
    error = assert_raises(RubyDecisionModel::InvalidResponse) { client.ask(state: "x", questions: questions) }
    refute_includes error.message, key
    assert_includes error.message, "[REDACTED]"

    body = JSON.generate("response" => nil, "error_message" => "token dapi-0123456789 rejected")
    client = RubyDecisionModel::Client.new(provider: :databricks, api_key: "dapi-0123456789", base_url: "https://h",
                                           transport: FakeTransport.new([[200, body, {}]]), sleeper: no_sleep)
    error = assert_raises(RubyDecisionModel::InvalidResponse) { client.ask(state: "x", questions: questions) }
    assert_equal "databricks ai_decide error: token [REDACTED] rejected", error.message
  end

  def test_cloudflare_instance_with_api_key_override_keeps_account_id
    shared = RubyDecisionModel::Providers::Cloudflare.new(api_key: "shared", account_id: "acc123")
    client = RubyDecisionModel::Client.new(provider: shared, api_key: "other", transport: FakeTransport.new([]))

    assert_equal "acc123", client.provider.account_id
    assert_equal "other", client.provider.api_key
    assert_equal "shared", shared.api_key
  end

  # --- Perplexity ---

  # Verbatim from Perplexity's Decisions quickstart.
  def perplexity_body
    '{"model":"pplx-decider-v1.1-27b","answers":{"defect":{"type":"noul","noul":0.9424522889347015},' \
      '"sentiment":{"type":"choice","choice":"mixed","confidence":0.9255246944002182,"probabilities":' \
      '{"positive":0.020649883775315993,"mixed":0.9503497962668123,"negative":0.02900031995787183}},' \
      '"severity":{"type":"score","score":1.7838686319784252,"confidence":0.7838686319784252,"legend":' \
      '{"0":"Cosmetic","1":"Inconvenient","2":"Product unusable"},"probabilities":{"0":0.008423954913615923,' \
      '"1":0.199283458194343,"2":0.7922925868920411}}},"usage":{"input_tokens":367,"output_tokens":3}}'
  end

  def perplexity_questions
    {
      "defect" => Q.noul("Does the review report a product defect?"),
      "sentiment" => Q.choice("What is the overall sentiment of the review?",
                              criteria: { "positive" => "Mostly satisfied", "mixed" => "Praise and complaints",
                                          "negative" => "Mostly dissatisfied" }),
      "severity" => Q.score("How severe is the reported problem?",
                            criteria: ["Cosmetic", "Inconvenient", "Product unusable"])
    }
  end

  def perplexity(transport, **options)
    RubyDecisionModel::Client.new(provider: :perplexity, api_key: "pplx-key", transport: transport, sleeper: no_sleep,
                                  **options)
  end

  def test_perplexity_defaults_and_aliases
    provider = RubyDecisionModel::Providers::Perplexity.new(api_key: "k")
    assert_equal "https://api.perplexity.ai/v1/decisions", provider.url
    assert_equal "pplx-decider-v1.1-27b", provider.resolve_model(nil)
    assert_equal "pplx-decider-v1.1-27b", provider.resolve_model("pplx-decider")
    assert_equal "pplx-decider-v1-27b", provider.resolve_model("perplexity/pplx-decider-v1-27b")
    assert_equal "PERPLEXITY_API_KEY", provider.env_var
  end

  def test_perplexity_speaks_system_one
    transport = FakeTransport.new([[200, perplexity_body, { "x-request-id" => "pplx-req" }]])
    response = perplexity(transport).ask(state: { title: "Battery died" }, questions: perplexity_questions)

    call = transport.calls.first
    assert_equal "https://api.perplexity.ai/v1/decisions", call[:url]
    assert_equal "Bearer pplx-key", call[:headers]["Authorization"]
    body = JSON.parse(call[:body])
    assert_equal %w[model state questions], body.keys
    assert_equal({ "title" => "Battery died" }, body["state"])

    assert_in_delta 0.9424, response["defect"].noul, 0.0001
    assert_in_delta 0.0575, response["defect"].probabilities["false"], 0.0001
    assert_equal "mixed", response["sentiment"].choice
    assert_equal "Product unusable", response["severity"].legend["2"]
    assert_equal 367, response.usage.input_tokens
    assert_equal "pplx-req", response.request_id
    assert_nil response.id
  end

  def test_perplexity_moves_images_into_a_state_array
    transport = FakeTransport.new([[200, perplexity_body, {}]])
    perplexity(transport).ask(state: { title: "Square" }, questions: perplexity_questions, images: [png])

    state = JSON.parse(transport.calls.first[:body])["state"]
    assert_equal ['{"title":"Square"}', { "type" => "image_url", "image_url" => { "url" => png } }], state
  end

  def test_perplexity_image_only_state
    transport = FakeTransport.new([[200, perplexity_body, {}]])
    perplexity(transport).ask(state: "", questions: perplexity_questions, images: [png])

    assert_equal [{ "type" => "image_url", "image_url" => { "url" => png } }],
                 JSON.parse(transport.calls.first[:body])["state"]
  end

  # Value: protects=array and non-string states keep their content when Perplexity images are appended
  # Value: fails_when=state_parts drops an Array state or sends a Hash state unencoded
  # Value: why_new=existing tests cover only Hash-as-JSON and empty-string states with images
  # Value: seam=none
  def test_perplexity_array_state_keeps_its_parts_before_the_images
    transport = FakeTransport.new([[200, perplexity_body, {}]])
    perplexity(transport).ask(state: %w[one two], questions: perplexity_questions, images: [png])

    state = JSON.parse(transport.calls.first[:body])["state"]
    assert_equal ["one", "two", { "type" => "image_url", "image_url" => { "url" => png } }], state
  end

  # --- Databricks ---

  def databricks_body
    JSON.generate(
      "response" => {
        "answers" => {
          "urgent" => { "type" => "noul", "probability" => 0.8 },
          "team" => { "type" => "choice", "choice" => "billing",
                      "probabilities" => { "billing" => 0.85, "technical" => 0.15 }, "confidence" => 0.9 },
          "severity" => { "type" => "score", "score" => 1.6, "probabilities" => { "0" => 0.1, "1" => 0.2, "2" => 0.7 },
                          "legend" => { "0" => "No impact", "1" => "Minor", "2" => "Major" }, "confidence" => 0.85 }
        }
      },
      "metadata" => { "version" => "1.0" }
    )
  end

  def databricks(transport, **options)
    RubyDecisionModel::Client.new(provider: :databricks, api_key: "dapi-token", base_url: "https://adb-1.azuredatabricks.net",
                                  transport: transport, sleeper: no_sleep, **options)
  end

  def test_databricks_requires_a_host
    without_provider_env do
      error = assert_raises(RubyDecisionModel::ConfigurationError) do
        RubyDecisionModel::Client.new(provider: :databricks, api_key: "t", transport: FakeTransport.new([]))
      end
      assert_includes error.message, "DATABRICKS_HOST"
    end
  end

  def test_databricks_reads_host_without_a_scheme_from_env
    without_provider_env do
      with_env("DATABRICKS_HOST" => "adb-1.azuredatabricks.net/", "DATABRICKS_TOKEN" => "dapi") do
        provider = RubyDecisionModel::Client.new(provider: :databricks, transport: FakeTransport.new([])).provider
        assert_equal "https://adb-1.azuredatabricks.net/api/2.0/ai-functions/ai-decide", provider.url
        assert_equal "dapi", provider.api_key
      end
    end
  end

  def test_databricks_sends_no_model
    transport = FakeTransport.new([[200, databricks_body, {}]])
    client = databricks(transport)
    client.ask(state: "Ticket text", questions: questions)

    assert_nil client.model
    call = transport.calls.first
    assert_equal "https://adb-1.azuredatabricks.net/api/2.0/ai-functions/ai-decide", call[:url]
    assert_equal %w[state questions], JSON.parse(call[:body]).keys
  end

  def test_databricks_rejects_a_model
    assert_raises(RubyDecisionModel::ConfigurationError) { databricks(FakeTransport.new([]), model: "jev") }
  end

  def test_databricks_reads_answers_under_response
    response = databricks(FakeTransport.new([[200, databricks_body, {}]])).ask(state: "x", questions: questions)

    assert_in_delta 0.8, response["urgent"].noul
    assert_in_delta 0.2, response["urgent"].probabilities["false"]
    assert_equal "billing", response["team"].choice
    assert_in_delta 1.6, response["severity"].score
    assert_nil response.model
    assert_nil response.usage.input_tokens
    assert_equal "1.0", response.raw["metadata"]["version"]
  end

  def test_databricks_error_message_raises_invalid_response
    body = JSON.generate("response" => nil, "error_message" => "AI_FUNCTION_DISABLED")
    error = assert_raises(RubyDecisionModel::InvalidResponse) do
      databricks(FakeTransport.new([[200, body, {}]])).ask(state: "x", questions: questions)
    end
    assert_includes error.message, "AI_FUNCTION_DISABLED"
  end

  # Value: protects=a noul that already carries "noul" keeps it, and a response with no answers reports all missing
  # Value: fails_when=Databricks overwrites "noul" with a nil "probability" or crashes on a non-Hash response
  # Value: why_new=existing databricks tests only send the probability-only shape or an error_message
  # Value: seam=none
  def test_databricks_keeps_an_existing_noul_value_and_reports_missing_when_response_is_absent
    body = JSON.generate("response" => { "answers" => { "urgent" => { "type" => "noul", "noul" => 0.6 } } })
    qs = { "urgent" => Q.noul("Urgent?") }
    assert_in_delta 0.6, databricks(FakeTransport.new([[200, body, {}]])).ask(state: "x", questions: qs)["urgent"].noul

    error = assert_raises(RubyDecisionModel::MissingAnswers) do
      databricks(FakeTransport.new([[200, "{}", {}]])).ask(state: "x", questions: qs)
    end
    assert_equal ["urgent"], error.missing
  end

  def test_databricks_error_message_is_capped
    body = JSON.generate("response" => nil, "error_message" => "x" * 2000)
    error = assert_raises(RubyDecisionModel::InvalidResponse) do
      databricks(FakeTransport.new([[200, body, {}]])).ask(state: "x", questions: questions)
    end
    assert_operator error.message.length, :<, 600
  end

  def test_databricks_refuses_images_before_sending
    transport = FakeTransport.new([[200, databricks_body, {}]])
    error = assert_raises(RubyDecisionModel::RequestError) do
      databricks(transport).ask(state: "x", questions: questions, images: [png])
    end
    assert_includes error.message, "databricks"
    assert_empty transport.calls
  end

  # --- generic System One servers ---

  # Shape of strands-decider's local server, including its extra latency_ms.
  def strands_body
    JSON.generate("model" => "strands-decider-2B-hobson-v21", "answers" => system_one_answers,
                  "usage" => { "input_tokens" => 86, "output_tokens" => 1 }, "latency_ms" => 140.03)
  end

  def test_system_one_requires_a_base_url
    without_provider_env do
      error = assert_raises(RubyDecisionModel::ConfigurationError) do
        RubyDecisionModel::Client.new(provider: :system_one, transport: FakeTransport.new([]))
      end
      assert_includes error.message, "SYSTEM_ONE_BASE_URL"
    end
  end

  def test_system_one_base_url_needs_a_scheme_and_a_host
    ["localhost:11434", "http://:11434", "http:// bad host"].each do |base_url|
      transport = FakeTransport.new([[200, strands_body, {}]])
      client = RubyDecisionModel::Client.new(provider: :system_one, base_url: base_url, transport: transport)

      error = assert_raises(RubyDecisionModel::ConfigurationError, base_url) { client.ask(state: "x", questions: questions) }
      assert_includes error.message, base_url.inspect
      assert_empty transport.calls, base_url
    end
    assert_equal "HTTPS://decisions.example.com/v1/systemone",
                 RubyDecisionModel::Providers::SystemOne.new(base_url: "HTTPS://decisions.example.com").url
  end

  def test_client_base_url_replaces_an_unusable_system_one_base_url
    with_env("SYSTEM_ONE_BASE_URL" => "localhost:11434") do
      transport = FakeTransport.new([[200, strands_body, {}]])
      client = RubyDecisionModel::Client.new(base_url: "http://ollama.internal:11434", transport: transport, sleeper: no_sleep)

      client.ask(state: "x", questions: questions)
      assert_equal :system_one, client.provider.name
      assert_equal "http://ollama.internal:11434/v1/systemone", transport.calls.first[:url]
    end
  end

  def test_system_one_runs_without_a_key_and_omits_a_nil_model
    without_provider_env do
      transport = FakeTransport.new([[200, strands_body, {}]])
      client = RubyDecisionModel::Client.new(provider: :system_one, base_url: "http://localhost:8000/",
                                             transport: transport, sleeper: no_sleep)
      response = client.ask(state: "Payouts failing", questions: questions)

      call = transport.calls.first
      assert_equal "http://localhost:8000/v1/systemone", call[:url]
      refute call[:headers].key?("Authorization")
      assert_equal %w[state questions], JSON.parse(call[:body]).keys
      assert_equal "strands-decider-2B-hobson-v21", response.model
      assert_in_delta 0.9, response["urgent"].noul
    end
  end

  def test_system_one_from_env_with_key_and_model
    without_provider_env do
      with_env("SYSTEM_ONE_BASE_URL" => "http://localhost:11434", "SYSTEM_ONE_API_KEY" => "local-key") do
        transport = FakeTransport.new([[200, strands_body, {}]])
        client = RubyDecisionModel::Client.new(model: "nimble", transport: transport, sleeper: no_sleep)
        client.ask(state: "x", questions: questions, images: [png])

        call = transport.calls.first
        assert_equal :system_one, client.provider.name
        assert_equal "http://localhost:11434/v1/systemone", call[:url]
        assert_equal "Bearer local-key", call[:headers]["Authorization"]
        body = JSON.parse(call[:body])
        assert_equal "nimble", body["model"]
        assert_equal [png], body["images"]
      end
    end
  end
end
