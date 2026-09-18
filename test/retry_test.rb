# frozen_string_literal: true

require "test_helper"

class RetryTest < Minitest::Test
  def questions
    { "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?") }
  end

  def success_body
    JSON.generate(
      "id" => "resp_1",
      "model" => "typesafe/jev-1.13",
      "answers" => { "urgent" => { "type" => "noul", "noul" => 0.6, "probabilities" => {} } },
      "usage" => {}
    )
  end

  def build_client(transport, sleeper: no_sleep, random: -> { 0.0 }, clock: nil, **options)
    args = { api_key: "test-key", transport: transport, sleeper: sleeper, random: random }
    args[:clock] = clock if clock
    RubyDecisionModel::Client.new(**args, **options)
  end

  # --- policy defaults ---

  def test_default_policy_matches_official_sdks
    policy = RubyDecisionModel::RetryPolicy.new

    assert_equal 2, policy.max_retries
    assert_in_delta 0.5, policy.backoff_initial
    assert_in_delta 5.0, policy.backoff_max
    assert_in_delta 0.25, policy.backoff_jitter
    assert_includes policy.http_statuses, 408
    assert_includes policy.http_statuses, 429
    assert_includes policy.http_statuses, 500
    assert_includes policy.http_statuses, 529
    assert_includes policy.http_statuses, 599
    refute_includes policy.http_statuses, 422
    assert policy.respect_retry_after
    assert_in_delta 60.0, policy.max_retry_after
    assert policy.retry_connection_errors
    assert policy.retry_timeouts
    assert_in_delta 30.0, policy.total_timeout
  end

  def test_policy_rejects_invalid_settings_at_construction
    error = RubyDecisionModel::ConfigurationError
    assert_raises(error) { RubyDecisionModel::RetryPolicy.new(max_retries: "2") }
    assert_raises(error) { RubyDecisionModel::RetryPolicy.new(max_retries: -1) }
    assert_raises(error) { RubyDecisionModel::RetryPolicy.new(max_retry_after: -1) }
    assert_raises(error) { RubyDecisionModel::RetryPolicy.new(backoff_jitter: 2.0) }
    assert_raises(error) { RubyDecisionModel::RetryPolicy.new(total_timeout: Float::NAN) }
    assert_raises(error) { RubyDecisionModel::RetryPolicy.new(backoff_initial: Float::INFINITY) }
    assert_raises(error) { build_client(FakeTransport.new([]), retry: { max_retries: "2" }) }
  end

  def test_client_accepts_hash_overrides_and_policy_object
    from_hash = build_client(FakeTransport.new([]), retry: { max_retries: 5 })
    assert_equal 5, from_hash.retry_policy.max_retries
    assert_in_delta 0.5, from_hash.retry_policy.backoff_initial

    policy = RubyDecisionModel::RetryPolicy.new(max_retries: 0)
    from_object = build_client(FakeTransport.new([]), retry: policy)
    assert_same policy, from_object.retry_policy
  end

  def test_from_nil_returns_default_policy
    policy = RubyDecisionModel::RetryPolicy.from(nil)
    assert_equal 2, policy.max_retries
    assert_in_delta 0.5, policy.backoff_initial
  end

  def test_from_rejects_unsupported_types
    assert_raises(RubyDecisionModel::ConfigurationError) { RubyDecisionModel::RetryPolicy.from("bogus") }
  end

  # --- attempts ---

  def test_two_retries_then_raise
    transport = FakeTransport.new([[503, "{}"], [503, "{}"], [503, "{}"], [200, success_body]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::ApiError) { client.ask(state: {}, questions: questions) }

    assert_equal 503, error.status
    assert_equal 3, transport.calls.length
  end

  def test_third_attempt_can_succeed
    transport = FakeTransport.new([[503, "{}"], [503, "{}"], [200, success_body]])
    client = build_client(transport)

    response = client.ask(state: {}, questions: questions)

    assert_equal "resp_1", response.id
    assert_equal 3, transport.calls.length
  end

  def test_max_retries_zero_means_single_attempt
    transport = FakeTransport.new([[503, "{}"], [200, success_body]])
    client = build_client(transport, retry: { max_retries: 0 })

    assert_raises(RubyDecisionModel::ApiError) { client.ask(state: {}, questions: questions) }
    assert_equal 1, transport.calls.length
  end

  def test_408_is_retried
    transport = FakeTransport.new([[408, "{}"], [200, success_body]])
    client = build_client(transport)

    client.ask(state: {}, questions: questions)

    assert_equal 2, transport.calls.length
  end

  def test_422_is_not_retried_and_maps_to_unprocessable_entity
    transport = FakeTransport.new([[422, "{\"error\":\"bad\"}"], [200, success_body]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::UnprocessableEntity) { client.ask(state: {}, questions: questions) }

    assert_equal 422, error.status
    assert_equal 1, transport.calls.length
  end

  def test_529_is_retried_then_maps_to_overloaded
    transport = FakeTransport.new([[529, "{}"]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::Overloaded) { client.ask(state: {}, questions: questions) }

    assert_equal 529, error.status
    assert_equal 3, transport.calls.length
  end

  # --- backoff ---

  def test_backoff_sequence_with_injected_random
    sleeper = RecordingSleeper.new
    transport = FakeTransport.new([[503, "{}"]])
    client = build_client(transport, sleeper: sleeper, random: -> { 0.0 }, retry: { max_retries: 4 })

    assert_raises(RubyDecisionModel::ApiError) { client.ask(state: {}, questions: questions) }

    assert_equal 4, sleeper.delays.length
    assert_in_delta 0.5, sleeper.delays[0]
    assert_in_delta 1.0, sleeper.delays[1]
    assert_in_delta 2.0, sleeper.delays[2]
    assert_in_delta 4.0, sleeper.delays[3]
  end

  def test_backoff_is_capped_and_jitter_subtracts_a_fraction
    sleeper = RecordingSleeper.new
    transport = FakeTransport.new([[503, "{}"]])
    client = build_client(transport, sleeper: sleeper, random: -> { 1.0 }, retry: { max_retries: 5 })

    assert_raises(RubyDecisionModel::ApiError) { client.ask(state: {}, questions: questions) }

    # 0.5, 1, 2, 4, then capped at 5; each times (1 - 0.25 * 1.0)
    assert_in_delta 0.375, sleeper.delays[0]
    assert_in_delta 0.75, sleeper.delays[1]
    assert_in_delta 1.5, sleeper.delays[2]
    assert_in_delta 3.0, sleeper.delays[3]
    assert_in_delta 3.75, sleeper.delays[4]
  end

  def test_backoff_never_goes_negative
    policy = RubyDecisionModel::RetryPolicy.new(backoff_jitter: 1.0)
    assert_in_delta 0.0, policy.backoff(0, random: -> { 1.0 })
  end

  def test_exception_backoff_uses_same_sequence
    sleeper = RecordingSleeper.new
    transport = FakeTransport.new([Errno::ECONNRESET.new, Net::ReadTimeout.new, [200, success_body]])
    client = build_client(transport, sleeper: sleeper, random: -> { 0.0 })

    client.ask(state: {}, questions: questions)

    assert_equal [0.5, 1.0], sleeper.delays.map { |d| d.round(3) }
  end

  # --- Retry-After ---

  def test_retry_after_seconds_is_honored
    sleeper = RecordingSleeper.new
    transport = FakeTransport.new([[429, "{}", { "Retry-After" => "3" }], [200, success_body]])
    client = build_client(transport, sleeper: sleeper)

    client.ask(state: {}, questions: questions)

    assert_equal [3.0], sleeper.delays
  end

  def test_retry_after_header_lookup_is_case_insensitive
    sleeper = RecordingSleeper.new
    transport = FakeTransport.new([[429, "{}", { "retry-after" => "2" }], [200, success_body]])
    client = build_client(transport, sleeper: sleeper)

    client.ask(state: {}, questions: questions)

    assert_equal [2.0], sleeper.delays
  end

  def test_retry_after_is_capped_at_max_retry_after
    sleeper = RecordingSleeper.new
    transport = FakeTransport.new([[429, "{}", { "Retry-After" => "600" }], [200, success_body]])
    client = build_client(transport, sleeper: sleeper, retry: { total_timeout: nil })

    client.ask(state: {}, questions: questions)

    assert_equal [60.0], sleeper.delays
  end

  def test_retry_after_ms_is_honored_and_preferred
    sleeper = RecordingSleeper.new
    transport = FakeTransport.new(
      [[429, "{}", { "retry-after-ms" => "250", "Retry-After" => "9" }], [200, success_body]]
    )
    client = build_client(transport, sleeper: sleeper)

    client.ask(state: {}, questions: questions)

    assert_equal [0.25], sleeper.delays
  end

  def test_retry_after_http_date_is_honored
    sleeper = RecordingSleeper.new
    date = (Time.now + 4).httpdate
    transport = FakeTransport.new([[503, "{}", { "Retry-After" => date }], [200, success_body]])
    client = build_client(transport, sleeper: sleeper)

    client.ask(state: {}, questions: questions)

    assert_equal 1, sleeper.delays.length
    assert_in_delta 4.0, sleeper.delays.first, 1.5
  end

  def test_retry_after_is_ignored_when_not_respected
    sleeper = RecordingSleeper.new
    transport = FakeTransport.new([[429, "{}", { "Retry-After" => "3" }], [200, success_body]])
    client = build_client(transport, sleeper: sleeper, retry: { respect_retry_after: false })

    client.ask(state: {}, questions: questions)

    assert_equal [0.5], sleeper.delays
  end

  def test_unparseable_retry_after_falls_back_to_backoff
    sleeper = RecordingSleeper.new
    transport = FakeTransport.new([[429, "{}", { "Retry-After" => "soon" }], [200, success_body]])
    client = build_client(transport, sleeper: sleeper)

    client.ask(state: {}, questions: questions)

    assert_equal [0.5], sleeper.delays
  end

  # --- transport contract ---

  def test_old_two_element_transport_return_still_works
    transport = FakeTransport.new([[503, "{}"], [200, success_body]])
    client = build_client(transport)

    response = client.ask(state: {}, questions: questions)

    assert_equal "resp_1", response.id
    assert_nil response.request_id
  end

  def test_api_error_carries_response_headers
    transport = FakeTransport.new([[401, "{}", { "x-typesafe-request-id" => "req_9" }]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::Unauthorized) { client.ask(state: {}, questions: questions) }

    assert_equal "req_9", error.headers["x-typesafe-request-id"]
  end

  # --- exception classes ---

  def test_timeouts_are_not_retried_when_disabled
    transport = FakeTransport.new([Net::OpenTimeout.new, [200, success_body]])
    client = build_client(transport, retry: { retry_timeouts: false })

    assert_raises(RubyDecisionModel::TimeoutError) { client.ask(state: {}, questions: questions) }
    assert_equal 1, transport.calls.length
  end

  def test_connection_errors_are_not_retried_when_disabled
    transport = FakeTransport.new([Errno::ECONNREFUSED.new, [200, success_body]])
    client = build_client(transport, retry: { retry_connection_errors: false })

    assert_raises(RubyDecisionModel::TransportError) { client.ask(state: {}, questions: questions) }
    assert_equal 1, transport.calls.length
  end

  def test_unknown_exception_is_never_retried
    transport = FakeTransport.new([RuntimeError.new("boom"), [200, success_body]])
    client = build_client(transport)

    error = assert_raises(RubyDecisionModel::TransportError) { client.ask(state: {}, questions: questions) }
    assert_equal 1, transport.calls.length
    assert_instance_of RuntimeError, error.cause_error
  end

  def test_library_error_is_reraised_immediately_without_retry
    transport = FakeTransport.new([RubyDecisionModel::ConfigurationError.new("boom"), [200, success_body]])
    client = build_client(transport)

    assert_raises(RubyDecisionModel::ConfigurationError) { client.ask(state: {}, questions: questions) }
    assert_equal 1, transport.calls.length
  end

  # --- total_timeout ---

  def test_total_timeout_stops_before_a_retry_that_would_exceed_the_budget
    now = 0.0
    clock = -> { now }
    sleeper = lambda { |seconds| now += seconds }
    transport = FakeTransport.new([[503, "{}"]])
    client = build_client(transport, sleeper: sleeper, clock: clock, retry: { max_retries: 10, total_timeout: 2.0 })

    error = assert_raises(RubyDecisionModel::ApiError) { client.ask(state: {}, questions: questions) }

    # delays 0.5 and 1.0 fit (1.5 elapsed); the next 2.0 would exceed 2.0
    assert_equal 503, error.status
    assert_equal 3, transport.calls.length
  end

  def test_total_timeout_applies_to_retry_after
    now = 0.0
    clock = -> { now }
    sleeper = lambda { |seconds| now += seconds }
    transport = FakeTransport.new([[429, "{}", { "Retry-After" => "45" }], [200, success_body]])
    client = build_client(transport, sleeper: sleeper, clock: clock)

    error = assert_raises(RubyDecisionModel::RateLimited) { client.ask(state: {}, questions: questions) }

    assert_equal 429, error.status
    assert_equal 1, transport.calls.length
  end

  def test_total_timeout_applies_to_exceptions_and_reraises_last_error
    now = 0.0
    clock = -> { now }
    sleeper = lambda { |seconds| now += seconds }
    transport = FakeTransport.new([Net::ReadTimeout.new])
    client = build_client(transport, sleeper: sleeper, clock: clock, retry: { max_retries: 10, total_timeout: 1.0 })

    assert_raises(RubyDecisionModel::TimeoutError) { client.ask(state: {}, questions: questions) }

    assert_equal 2, transport.calls.length
  end

  def test_total_timeout_rechecked_after_sleep_overshoot
    now = 0.0
    clock = -> { now }
    sleeper = lambda { |seconds| now += seconds + 10.0 }
    transport = FakeTransport.new([[503, "{}"]])
    client = build_client(transport, sleeper: sleeper, clock: clock, retry: { max_retries: 5, total_timeout: 5.0 })

    assert_raises(RubyDecisionModel::ApiError) { client.ask(state: {}, questions: questions) }

    assert_equal 1, transport.calls.length
  end

  def test_total_timeout_nil_disables_budget
    now = 0.0
    clock = -> { now }
    sleeper = lambda { |seconds| now += seconds }
    transport = FakeTransport.new([[503, "{}"]])
    client = build_client(transport, sleeper: sleeper, clock: clock, retry: { max_retries: 6, total_timeout: nil })

    assert_raises(RubyDecisionModel::ApiError) { client.ask(state: {}, questions: questions) }

    assert_equal 7, transport.calls.length
  end
end
