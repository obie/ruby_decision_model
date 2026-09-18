# frozen_string_literal: true

require "test_helper"

# A transport that declares the `timeout:` keyword and records what it was
# handed, so the budget the client computed is observable.
class TimeoutRecordingTransport
  attr_reader :timeouts

  def initialize(responses, clock: nil, cost: 0.0)
    @responses = responses
    @clock = clock
    @cost = cost
    @timeouts = []
  end

  def call(url:, headers:, body:, timeout: nil)
    @timeouts << timeout
    @clock&.call(@cost)
    response = @responses.length > 1 ? @responses.shift : @responses.first
    raise response if response.is_a?(Exception)

    response
  end
end

# The old three-keyword contract, which must keep working untouched.
class LegacyTransport
  attr_reader :calls

  def initialize(response)
    @response = response
    @calls = 0
  end

  def call(url:, headers:, body:)
    @calls += 1
    @response
  end
end

class DeadlineTest < Minitest::Test
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
      **{ api_key: "test-key", transport: transport, sleeper: no_sleep, random: -> { 0.0 } }.merge(options)
    )
  end

  # --- timeout validation ---

  def test_timeout_must_be_a_finite_positive_number
    [0, -1, "5", Float::INFINITY, Float::NAN, []].each do |bad|
      assert_raises(RubyDecisionModel::ConfigurationError, "expected #{bad.inspect} to be rejected") do
        build_client(FakeTransport.new([]), timeout: bad)
      end
    end
  end

  def test_nil_timeout_is_allowed_and_means_no_per_attempt_limit
    client = build_client(FakeTransport.new([]), timeout: nil)
    assert_nil client.timeout
  end

  # --- the per-attempt timeout is bounded by what is left of the budget ---

  def test_attempt_timeout_is_the_smaller_of_timeout_and_remaining_budget
    now = 0.0
    transport = TimeoutRecordingTransport.new([[200, success_body]], clock: ->(cost) { now += cost })
    client = build_client(transport, timeout: 5, clock: -> { now }, retry: { total_timeout: 2.0 })

    client.ask(state: {}, questions: questions)

    assert_equal [2.0], transport.timeouts
  end

  def test_attempt_timeout_is_the_configured_timeout_when_the_budget_is_larger
    client_transport = TimeoutRecordingTransport.new([[200, success_body]])
    client = build_client(client_transport, timeout: 5, retry: { total_timeout: 30.0 })

    client.ask(state: {}, questions: questions)

    assert_equal [5], client_transport.timeouts
  end

  def test_a_later_attempt_gets_only_what_the_budget_has_left
    now = 0.0
    # Each attempt burns 3s of the 10s budget; the sleeper burns its delay.
    transport = TimeoutRecordingTransport.new([[503, "{}"], [200, success_body]],
                                              clock: ->(_c) { now += 3.0 }, cost: 3.0)
    client = build_client(transport, timeout: 30, clock: -> { now },
                                     sleeper: ->(seconds) { now += seconds },
                                     retry: { total_timeout: 10.0, backoff_initial: 1.0, backoff_jitter: 0.0 })

    client.ask(state: {}, questions: questions)

    # First attempt: 10s left. Second: 10 - 3 (attempt) - 1 (backoff) = 6s.
    assert_equal [10.0, 6.0], transport.timeouts
  end

  def test_no_budget_means_the_transport_gets_the_plain_timeout
    transport = TimeoutRecordingTransport.new([[200, success_body]])
    client = build_client(transport, timeout: 4, retry: { total_timeout: nil })

    client.ask(state: {}, questions: questions)

    assert_equal [4], transport.timeouts
  end

  def test_an_exhausted_budget_raises_instead_of_starting_an_attempt
    now = 0.0
    transport = TimeoutRecordingTransport.new([[200, success_body]])
    client = build_client(transport, clock: -> { now }, retry: { total_timeout: 0.0 })

    error = assert_raises(RubyDecisionModel::TimeoutError) { client.ask(state: {}, questions: questions) }

    assert_match(/budget/, error.message)
    assert_empty transport.timeouts, "no request should have gone out"
  end

  # --- backwards compatibility of the transport contract ---

  def test_a_transport_without_a_timeout_keyword_is_still_called_the_old_way
    transport = LegacyTransport.new([200, success_body])
    client = build_client(transport, timeout: 5)

    response = client.ask(state: {}, questions: questions)

    assert_equal 1, transport.calls
    assert_in_delta 0.5, response["urgent"].noul
  end

  def test_a_lambda_transport_with_a_splat_receives_the_timeout
    seen = nil
    transport = lambda do |url:, headers:, body:, **rest|
      seen = rest[:timeout]
      [200, success_body]
    end
    client = build_client(transport, timeout: 7, retry: { total_timeout: nil })

    client.ask(state: {}, questions: questions)

    assert_equal 7, seen
  end

  # --- the budget boundary ---

  def test_a_delay_landing_exactly_on_the_deadline_stops_the_retry
    now = 0.0
    sleeper = lambda { |seconds| now += seconds }
    transport = FakeTransport.new([[503, "{}"]])
    client = build_client(transport, clock: -> { now }, sleeper: sleeper,
                                     retry: { max_retries: 5, total_timeout: 1.0, backoff_initial: 1.0,
                                              backoff_jitter: 0.0 })

    # The first backoff is exactly 1.0s, which uses the entire budget, so the
    # 503 is returned rather than slept on.
    assert_raises(RubyDecisionModel::ApiError) { client.ask(state: {}, questions: questions) }
    assert_equal 1, transport.calls.length
    assert_in_delta 0.0, now
  end

  # --- write timeouts ---

  def test_a_write_timeout_is_treated_as_a_timeout_and_retried
    transport = FakeTransport.new([Net::WriteTimeout.new, [200, success_body]])
    client = build_client(transport)

    response = client.ask(state: {}, questions: questions)

    assert_in_delta 0.5, response["urgent"].noul
    assert_equal 2, transport.calls.length
  end

  def test_an_unretried_write_timeout_surfaces_as_a_timeout_error
    transport = FakeTransport.new([Net::WriteTimeout.new])
    client = build_client(transport, retry: { max_retries: 0 })

    error = assert_raises(RubyDecisionModel::TimeoutError) { client.ask(state: {}, questions: questions) }
    assert_instance_of Net::WriteTimeout, error.cause_error
  end

  def test_write_timeouts_can_be_switched_off_like_the_other_timeouts
    transport = FakeTransport.new([Net::WriteTimeout.new])
    client = build_client(transport, retry: { retry_timeouts: false })

    assert_raises(RubyDecisionModel::TimeoutError) { client.ask(state: {}, questions: questions) }
    assert_equal 1, transport.calls.length
  end

  # --- the default transport covers every phase, not just open and read ---

  def test_the_default_transport_sets_all_four_net_http_timeouts
    client = RubyDecisionModel::Client.new(api_key: "test-key", timeout: 3)
    http = nil
    fake_http = Class.new do
      attr_accessor :use_ssl, :open_timeout, :ssl_timeout, :read_timeout, :write_timeout

      def request(_request)
        Struct.new(:code, :body).new("200", "{}").tap { |r| def r.each_header = {}.each }
      end
    end

    Net::HTTP.stub(:new, ->(_host, _port) { http = fake_http.new }) do
      client.send(:default_transport).call(url: "https://example.com/x", headers: {}, body: "{}", timeout: 3)
    end

    assert_equal 3, http.open_timeout
    assert_equal 3, http.ssl_timeout
    assert_equal 3, http.read_timeout
    assert_equal 3, http.write_timeout
  end
end
