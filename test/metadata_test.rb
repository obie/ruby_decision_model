# frozen_string_literal: true

require "test_helper"

# Whatever the response carried should still be reachable afterwards, on the
# way out and on the way down.
class MetadataTest < Minitest::Test
  def questions
    { "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?") }
  end

  def success_body
    JSON.generate(
      "answers" => { "urgent" => { "type" => "noul", "noul" => 0.5 } },
      "usage" => { "input_tokens" => 1, "output_tokens" => 1 }
    )
  end

  def build_client(transport, **options)
    RubyDecisionModel::Client.new(
      **{ api_key: "test-key", transport: transport, sleeper: no_sleep, retry: { max_retries: 0 } }.merge(options)
    )
  end

  # --- on a successful response ---

  def test_response_keeps_every_header
    headers = { "X-Typesafe-Request-Id" => "req_123", "x-ratelimit-remaining" => "998",
                "Content-Type" => "application/json" }
    client = build_client(FakeTransport.new([[200, success_body, headers]]))

    response = client.ask(state: {}, questions: questions)

    assert_equal headers, response.headers
    assert_equal "998", response.header("X-RateLimit-Remaining")
    assert_equal "req_123", response.request_id
  end

  def test_response_headers_default_to_empty_for_a_two_element_transport
    client = build_client(FakeTransport.new([[200, success_body]]))

    response = client.ask(state: {}, questions: questions)

    assert_empty response.headers
    assert_nil response.request_id
    assert_nil response.header("x-anything")
  end

  # --- on a failure, which is when you actually report one ---

  def test_api_error_exposes_the_request_id
    headers = { "x-typesafe-request-id" => "req_abc" }
    client = build_client(FakeTransport.new([[500, "boom", headers]]))

    error = assert_raises(RubyDecisionModel::ApiError) { client.ask(state: {}, questions: questions) }

    assert_equal "req_abc", error.request_id
  end

  def test_request_id_on_an_error_ignores_header_case
    client = build_client(FakeTransport.new([[429, "slow down", { "X-TypeSafe-Request-Id" => "req_xyz" }]]))

    error = assert_raises(RubyDecisionModel::RateLimited) { client.ask(state: {}, questions: questions) }

    assert_equal "req_xyz", error.request_id
  end

  def test_request_id_is_nil_when_the_provider_does_not_send_one
    client = build_client(FakeTransport.new([[401, "nope", {}]]))

    error = assert_raises(RubyDecisionModel::Unauthorized) { client.ask(state: {}, questions: questions) }

    assert_nil error.request_id
  end

  def test_api_error_names_the_endpoint_it_came_from
    client = build_client(FakeTransport.new([[422, "bad", {}]]), provider: :typesafe)

    error = assert_raises(RubyDecisionModel::UnprocessableEntity) { client.ask(state: {}, questions: questions) }

    assert_equal "https://api.typesafe.ai/v1/systemone", error.endpoint
  end

  def test_rate_limit_headers_survive_on_the_error
    headers = { "retry-after" => "30", "x-ratelimit-remaining" => "0" }
    client = build_client(FakeTransport.new([[429, "slow down", headers]]))

    error = assert_raises(RubyDecisionModel::RateLimited) { client.ask(state: {}, questions: questions) }

    assert_equal "30", RubyDecisionModel::Headers.fetch(error.headers, "Retry-After")
  end

  # --- the header lookup itself ---

  def test_headers_fetch_matches_without_regard_to_case
    assert_equal "v", RubyDecisionModel::Headers.fetch({ "X-Thing" => "v" }, "x-thing")
    assert_equal "v", RubyDecisionModel::Headers.fetch({ "x-thing" => "v" }, "X-THING")
  end

  def test_headers_fetch_takes_the_first_of_an_array_value
    # Net::HTTP hands repeated headers back as an Array.
    assert_equal "first", RubyDecisionModel::Headers.fetch({ "x-thing" => %w[first second] }, "x-thing")
  end

  def test_headers_fetch_on_junk
    assert_nil RubyDecisionModel::Headers.fetch(nil, "x-thing")
    assert_nil RubyDecisionModel::Headers.fetch("not a hash", "x-thing")
    assert_nil RubyDecisionModel::Headers.fetch({}, "x-thing")
  end
end
