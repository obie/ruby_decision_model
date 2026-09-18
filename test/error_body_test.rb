# frozen_string_literal: true

require "test_helper"

# The server says what went wrong. The exception should say it too.
class ErrorBodyTest < Minitest::Test
  def questions
    { "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?") }
  end

  def raise_for(status, body)
    client = RubyDecisionModel::Client.new(
      api_key: "k", sleeper: no_sleep, retry: { max_retries: 0 },
      transport: FakeTransport.new([[status, body, {}]])
    )
    client.ask(state: {}, questions: questions)
  end

  def error_for(status, body, klass = RubyDecisionModel::ApiError)
    assert_raises(klass) { raise_for(status, body) }
  end

  # --- the shapes the two providers actually send ---

  def test_a_nested_error_object_is_read
    # OpenRouter: {"error": {"code": ..., "message": ...}}
    error = error_for(400, JSON.generate("error" => { "code" => "invalid_request",
                                                     "message" => "questions is required" }))

    assert_equal "questions is required", error.detail
    assert_equal "invalid_request", error.error_code
  end

  def test_a_top_level_message_is_read
    # Typesafe's 422 details the offending field.
    error = error_for(422, JSON.generate("message" => "questions.sev.criteria must have at least 2 entries"),
                      RubyDecisionModel::UnprocessableEntity)

    assert_equal "questions.sev.criteria must have at least 2 entries", error.detail
  end

  def test_the_detail_is_appended_to_the_exception_message
    error = error_for(422, JSON.generate("message" => "criteria is required"),
                      RubyDecisionModel::UnprocessableEntity)

    assert_match(/unprocessable entity: criteria is required/, error.message)
  end

  def test_an_integer_code_is_stringified
    error = error_for(429, JSON.generate("error" => { "code" => 429, "message" => "slow down" }),
                      RubyDecisionModel::RateLimited)

    assert_equal "429", error.error_code
  end

  def test_the_whole_parsed_body_is_available
    error = error_for(422, JSON.generate("message" => "bad", "field" => "questions.sev"),
                      RubyDecisionModel::UnprocessableEntity)

    assert_equal "questions.sev", error.parsed_body["field"]
  end

  # --- bodies that are not that ---

  def test_a_plain_text_body_leaves_the_message_alone
    error = error_for(500, "upstream connect error")

    assert_nil error.detail
    assert_nil error.error_code
    assert_nil error.parsed_body
    assert_equal "api error (status 500)", error.message
    assert_equal "upstream connect error", error.body
  end

  def test_an_html_error_page_does_not_raise
    error = error_for(502, "<html><body>502 Bad Gateway</body></html>")

    assert_nil error.detail
    assert_equal "api error (status 502)", error.message
  end

  def test_a_json_array_body_is_not_treated_as_an_error_object
    error = error_for(500, "[1,2,3]")

    assert_nil error.parsed_body
    assert_nil error.detail
  end

  def test_an_empty_body_does_not_raise
    error = error_for(500, "")

    assert_nil error.detail
    assert_nil error.parsed_body
  end

  def test_a_message_that_is_not_a_string_is_ignored
    error = error_for(500, JSON.generate("message" => { "nested" => "object" }))

    assert_nil error.detail
    assert_equal "api error (status 500)", error.message
  end

  def test_an_empty_message_is_ignored
    error = error_for(500, JSON.generate("message" => ""))

    assert_nil error.detail
  end

  def test_the_body_is_still_the_raw_string
    body = JSON.generate("message" => "nope")
    error = error_for(500, body)

    assert_equal body, error.body
  end

  def test_parsing_happens_once
    error = error_for(500, JSON.generate("message" => "nope"))

    assert_same error.parsed_body, error.parsed_body
  end

  def test_an_error_built_by_hand_still_works
    error = RubyDecisionModel::ApiError.new("boom", status: 500, body: nil)

    assert_equal "boom", error.message
    assert_nil error.detail
    assert_empty error.headers
  end
end
