# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  def questions
    {
      "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?"),
      "category" => RubyDecisionModel::Questions.choice("Pick a category", criteria: { "bug" => nil, "feature" => nil }),
      "severity" => RubyDecisionModel::Questions.score("Rate severity", criteria: %w[low medium high])
    }
  end

  def success_body
    JSON.generate(
      "id" => "resp_1",
      "model" => "typesafe/jev-1.13",
      "answers" => {
        "urgent" => { "type" => "noul", "noul" => 0.82, "probabilities" => { "true" => 0.82, "false" => 0.18 } },
        "category" => { "type" => "choice", "choice" => "bug", "confidence" => 0.9,
                         "probabilities" => { "bug" => 0.9, "feature" => 0.1 } },
        "severity" => { "type" => "score", "score" => 1.4, "confidence" => 0.7,
                         "probabilities" => { "low" => 0.1, "medium" => 0.6, "high" => 0.3 },
                         "legend" => { "low" => "cosmetic" } }
      },
      "usage" => { "input_tokens" => 120, "output_tokens" => 30, "cost" => 0.0012 }
    )
  end

  def build_client(transport)
    RubyDecisionModel::Client.new(api_key: "test-key", transport: transport, sleeper: no_sleep)
  end

  # --- configuration ---

  def test_requires_api_key
    without_provider_env do
      assert_raises(RubyDecisionModel::ConfigurationError) do
        RubyDecisionModel::Client.new(api_key: nil)
      end
    end
  end

  def test_requires_non_blank_api_key
    assert_raises(RubyDecisionModel::ConfigurationError) do
      RubyDecisionModel::Client.new(api_key: "  ")
    end
  end

  def test_rejects_empty_questions
    client = build_client(FakeTransport.new([[200, success_body]]))
    assert_raises(RubyDecisionModel::RequestError) do
      client.ask(state: {}, questions: {})
    end
  end

  def test_legacy_constants_remain_available
    assert_equal "https://openrouter.ai/api/alpha", RubyDecisionModel::Client::DEFAULT_BASE_URL
    assert_equal "typesafe/jev-1.13", RubyDecisionModel::Client::DEFAULT_MODEL
    assert_equal 3, RubyDecisionModel::Client::MAX_ATTEMPTS
    assert_includes RubyDecisionModel::Client::RETRYABLE_STATUSES, 503
    assert_includes RubyDecisionModel::Client::RETRYABLE_EXCEPTIONS, Net::ReadTimeout
  end

  # --- happy path ---

  def test_happy_path_all_answer_types
    transport = FakeTransport.new([[200, success_body]])
    client = build_client(transport)

    response = client.ask(state: { title: "x" }, questions: questions)

    assert_instance_of RubyDecisionModel::Response, response
    assert_equal "resp_1", response.id
    assert_equal "typesafe/jev-1.13", response.model

    urgent = response["urgent"]
    assert_instance_of RubyDecisionModel::Answers::Noul, urgent
    assert_in_delta 0.82, urgent.noul
    assert_in_delta 0.82, urgent.probability

    category = response.answers["category"]
    assert_instance_of RubyDecisionModel::Answers::Choice, category
    assert_equal "bug", category.choice
    assert_in_delta 0.9, category.confidence

    severity = response.answers["severity"]
    assert_instance_of RubyDecisionModel::Answers::Score, severity
    assert_in_delta 1.4, severity.score
    assert_equal({ "low" => "cosmetic" }, severity.legend)

    assert_equal 120, response.usage.input_tokens
    assert_equal 30, response.usage.output_tokens
    assert_in_delta 0.0012, response.usage.cost
  end

  # --- status mapping ---

  def test_401_raises_unauthorized
    transport = FakeTransport.new([[401, "{}"]])
    client = build_client(transport)
    error = assert_raises(RubyDecisionModel::Unauthorized) { client.ask(state: {}, questions: questions) }
    assert_equal 401, error.status
  end

  def test_413_raises_payload_too_large
    transport = FakeTransport.new([[413, "{}"], [413, "{}"]])
    client = build_client(transport)
    error = assert_raises(RubyDecisionModel::PayloadTooLarge) { client.ask(state: {}, questions: questions) }
    assert_equal 413, error.status
  end

  def test_429_retries_twice_then_raises_rate_limited
    transport = FakeTransport.new([[429, "{}"], [429, "{}"], [429, "{}"]])
    client = build_client(transport)
    error = assert_raises(RubyDecisionModel::RateLimited) { client.ask(state: {}, questions: questions) }
    assert_equal 429, error.status
    assert_equal 3, transport.calls.length
  end

  def test_500_raises_api_error
    transport = FakeTransport.new([[500, "{}"], [500, "{}"]])
    client = build_client(transport)
    error = assert_raises(RubyDecisionModel::ApiError) { client.ask(state: {}, questions: questions) }
    assert_equal 500, error.status
  end

  # --- retry ---

  def test_retries_once_on_503_then_succeeds
    transport = FakeTransport.new([[503, "{}"], [200, success_body]])
    client = build_client(transport)

    response = client.ask(state: {}, questions: questions)

    assert_equal 2, transport.calls.length
    assert_equal "resp_1", response.id
  end


  def test_symbol_question_ids_and_keys_match_string_answers
    transport = FakeTransport.new([[200, success_body]])
    client = build_client(transport)
    symbol_questions = {
      urgent: { type: "noul", instructions: "Is this urgent?" },
      category: { type: "choice", instructions: "Pick", criteria: { "bug" => nil, "feature" => nil } },
      severity: { type: "score", instructions: "Rate", criteria: %w[low medium high] }
    }

    response = client.ask(state: {}, questions: symbol_questions)

    assert_in_delta 0.82, response["urgent"].noul
    assert_equal "bug", response["category"].choice
  end

  def test_exception_then_retryable_status_raises_after_three_attempts
    transport = FakeTransport.new([Net::ReadTimeout.new, [503, "{}"], [503, "{}"]])
    client = build_client(transport)

    assert_raises(RubyDecisionModel::ApiError) { client.ask(state: {}, questions: questions) }
    assert_equal 3, transport.calls.length
  end

  # --- malformed / invalid responses ---

  def test_nil_body_on_success_raises_invalid_response
    transport = FakeTransport.new([[200, nil]])
    client = build_client(transport)
    assert_raises(RubyDecisionModel::InvalidResponse) { client.ask(state: {}, questions: questions) }
  end

  def test_empty_body_on_success_raises_invalid_response
    transport = FakeTransport.new([[204, ""]])
    client = build_client(transport)
    assert_raises(RubyDecisionModel::InvalidResponse) { client.ask(state: {}, questions: questions) }
  end

  def test_non_json_body_raises_invalid_response
    transport = FakeTransport.new([[200, "not json"]])
    client = build_client(transport)
    assert_raises(RubyDecisionModel::InvalidResponse) { client.ask(state: {}, questions: questions) }
  end

  def test_wrong_type_answer_raises_missing_answers_with_good_answers_attached
    body = JSON.generate(
      "id" => "resp_2",
      "model" => "typesafe/jev-1.13",
      "answers" => {
        "urgent" => { "type" => "choice", "choice" => "oops" },
        "category" => { "type" => "choice", "choice" => "bug", "confidence" => 0.9, "probabilities" => {} },
        "severity" => { "type" => "score", "score" => 1.4, "confidence" => 0.7, "probabilities" => {}, "legend" => {} }
      },
      "usage" => {}
    )
    transport = FakeTransport.new([[200, body]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::MissingAnswers) { client.ask(state: {}, questions: questions) }
    assert_equal ["urgent"], error.missing
    assert_equal %w[category severity], error.answers.keys.sort
  end

  def test_malformed_numeric_field_raises_invalid_response
    body = JSON.generate(
      "id" => "resp_3",
      "model" => "typesafe/jev-1.13",
      "answers" => {
        "urgent" => { "type" => "noul", "noul" => "not-a-number" },
        "category" => { "type" => "choice", "choice" => "bug", "confidence" => 0.9, "probabilities" => {} },
        "severity" => { "type" => "score", "score" => 1.4, "confidence" => 0.7, "probabilities" => {}, "legend" => {} }
      },
      "usage" => {}
    )
    transport = FakeTransport.new([[200, body]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::InvalidResponse) { client.ask(state: {}, questions: questions) }
    refute_kind_of RubyDecisionModel::MissingAnswers, error
  end

  def test_json_body_that_is_not_an_object_raises_invalid_response
    transport = FakeTransport.new([[200, "[]"]])
    client = build_client(transport)
    assert_raises(RubyDecisionModel::InvalidResponse) { client.ask(state: {}, questions: questions) }
  end

  def test_missing_answers_key_raises_missing_answers_for_all_questions
    body = JSON.generate("id" => "resp_5", "model" => "typesafe/jev-1.13")
    transport = FakeTransport.new([[200, body]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::MissingAnswers) { client.ask(state: {}, questions: questions) }
    assert_equal %w[category severity urgent], error.missing.sort
  end

  def test_malformed_takes_priority_over_missing_when_both_present
    body = JSON.generate(
      "id" => "resp_6",
      "model" => "typesafe/jev-1.13",
      "answers" => {
        "urgent" => { "type" => "noul", "noul" => "not-a-number" }
      },
      "usage" => {}
    )
    transport = FakeTransport.new([[200, body]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::InvalidResponse) { client.ask(state: {}, questions: questions) }
    refute_kind_of RubyDecisionModel::MissingAnswers, error
    assert_includes error.message, "urgent"
  end

  def test_malformed_choice_missing_confidence_raises_invalid_response
    body = JSON.generate(
      "id" => "resp_7",
      "model" => "typesafe/jev-1.13",
      "answers" => { "category" => { "type" => "choice", "choice" => "bug" } },
      "usage" => {}
    )
    transport = FakeTransport.new([[200, body]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::InvalidResponse) do
      client.ask(state: {}, questions: { "category" => questions["category"] })
    end
    assert_includes error.message, "category"
  end

  def test_malformed_score_missing_confidence_raises_invalid_response
    body = JSON.generate(
      "id" => "resp_8",
      "model" => "typesafe/jev-1.13",
      "answers" => { "severity" => { "type" => "score", "score" => 1.4 } },
      "usage" => {}
    )
    transport = FakeTransport.new([[200, body]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::InvalidResponse) do
      client.ask(state: {}, questions: { "severity" => questions["severity"] })
    end
    assert_includes error.message, "severity"
  end

  def test_unsupported_question_type_raises_invalid_response
    weird_questions = { "mystery" => { "type" => "unknown", "instructions" => "huh" } }
    body = JSON.generate(
      "id" => "resp_9",
      "model" => "typesafe/jev-1.13",
      "answers" => { "mystery" => { "type" => "unknown", "value" => "x" } },
      "usage" => {}
    )
    transport = FakeTransport.new([[200, body]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::InvalidResponse) do
      client.ask(state: {}, questions: weird_questions)
    end
    assert_includes error.message, "mystery"
  end

  def test_non_hash_probabilities_fall_back_to_empty_hash
    body = JSON.generate(
      "id" => "resp_10",
      "model" => "typesafe/jev-1.13",
      "answers" => { "urgent" => { "type" => "noul", "noul" => 0.5, "probabilities" => %w[not a hash] } },
      "usage" => {}
    )
    transport = FakeTransport.new([[200, body]])
    client = build_client(transport)

    response = client.ask(state: {}, questions: { "urgent" => questions["urgent"] })
    assert_equal({}, response["urgent"].probabilities)
  end

  def test_junk_usage_fields_are_rejected_rather_than_nilled
    body = JSON.generate(
      "id" => "resp_4",
      "model" => "typesafe/jev-1.13",
      "answers" => {
        "urgent" => { "type" => "noul", "noul" => 0.5 },
        "category" => { "type" => "choice", "choice" => "bug", "confidence" => 0.9, "probabilities" => {} },
        "severity" => { "type" => "score", "score" => 1.4, "confidence" => 0.7, "probabilities" => {}, "legend" => {} }
      },
      "usage" => { "input_tokens" => "junk", "output_tokens" => nil, "cost" => "junk" }
    )
    transport = FakeTransport.new([[200, body]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::InvalidResponse) { client.ask(state: {}, questions: questions) }
    assert_match(/usage\.input_tokens is not a token count/, error.message)
  end

  def test_an_absent_usage_field_is_still_nil
    body = JSON.generate(
      "id" => "resp_4b",
      "model" => "typesafe/jev-1.13",
      "answers" => { "urgent" => { "type" => "noul", "noul" => 0.5 } },
      "usage" => { "input_tokens" => 120 }
    )
    client = build_client(FakeTransport.new([[200, body]]))

    usage = client.ask(state: {}, questions: { "urgent" => questions["urgent"] }).usage

    assert_equal 120, usage.input_tokens
    assert_nil usage.output_tokens
    assert_nil usage.cost
  end
end
