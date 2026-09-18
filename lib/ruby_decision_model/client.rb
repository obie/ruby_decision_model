# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module RubyDecisionModel
  class Client
    REQUEST_ID_HEADER = "x-typesafe-request-id"

    # Kept from 0.0.1 for callers that referenced them. They describe the
    # OpenRouter provider and the default RetryPolicy; prefer those directly.
    DEFAULT_BASE_URL = Providers::OpenRouter.new.default_base_url
    DEFAULT_MODEL = Providers::OpenRouter.new.default_model
    MAX_ATTEMPTS = RetryPolicy.new.max_retries + 1
    RETRYABLE_STATUSES = RetryPolicy::DEFAULT_STATUSES
    RETRYABLE_EXCEPTIONS = (RetryPolicy::TIMEOUT_EXCEPTIONS + RetryPolicy::CONNECTION_EXCEPTIONS).freeze

    attr_reader :provider, :model, :retry_policy, :timeout

    # provider:  :open_router, :typesafe, or a Providers::Base instance. When
    #            nil, api_key: alone selects OpenRouter; otherwise the
    #            environment decides (TYPESAFE_API_KEY, then OPENROUTER_API_KEY).
    # api_key:   overrides the provider's env var.
    # model:     nil means the provider default; aliases resolve per provider.
    # base_url:  overrides the provider base URL.
    # transport: callable(url:, headers:, body:) returning
    #            [status, body_string, headers_hash] (a 2-element return is
    #            still accepted and treated as having no headers).
    # retry:     a RetryPolicy or a Hash of overrides.
    # random:    callable returning a Float in 0...1, used for backoff jitter.
    # clock:     callable returning monotonic seconds, used for total_timeout.
    def initialize(provider: nil, api_key: nil, model: nil, base_url: nil, timeout: 5,
                   transport: nil, sleeper: ->(seconds) { sleep(seconds) }, retry: {},
                   random: -> { rand }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @provider = resolve_provider(provider, api_key: api_key, base_url: base_url)
      unless @provider.api_key?
        raise ConfigurationError,
              "api_key is required for #{@provider.name}: pass api_key: or set #{@provider.env_var}"
      end

      @model = @provider.resolve_model(model)
      @timeout = validate_timeout(timeout)
      @transport = transport || default_transport
      @sleeper = sleeper
      @retry_policy = RetryPolicy.from(binding.local_variable_get(:retry))
      @random = random
      @clock = clock
    end

    def base_url
      @provider.base_url
    end

    def ask(state:, questions:)
      raise RequestError, "questions must not be empty" if questions.nil? || questions.empty?

      body = @provider.request_body(model: @model, state: state, questions: questions)
      status, response_body, response_headers = perform_with_retry(
        url: @provider.url, headers: @provider.headers, body: body
      )
      handle_response(status, response_body, response_headers, questions)
    end

    private

    def resolve_provider(provider, api_key:, base_url:)
      case provider
      when Providers::Base
        return provider if api_key.nil? && base_url.nil?

        # Never mutate a provider the caller may share between clients.
        provider.dup.configure(api_key: api_key, base_url: base_url)
      when Symbol, String
        Providers.build(provider, api_key: api_key, base_url: base_url)
      when nil
        if api_key.nil?
          Providers.from_env&.configure(base_url: base_url) || raise(
            ConfigurationError,
            "no provider configured: pass provider: or api_key:, or set one of #{Providers.env_vars.join(', ')}"
          )
        else
          Providers.build(:open_router, api_key: api_key, base_url: base_url)
        end
      else
        raise ConfigurationError, "provider must be a Symbol or a Providers::Base, got #{provider.class}"
      end
    end

    def default_transport
      lambda do |url:, headers:, body:, timeout: @timeout|
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        # All four, not just open and read: a stalled TLS handshake or a
        # stalled upload otherwise falls back to Net::HTTP's own defaults
        # (60s for the write), which blows through both `timeout` and the
        # retry policy's total budget.
        http.open_timeout = timeout
        http.ssl_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout

        request = Net::HTTP::Post.new(uri.request_uri)
        headers.each { |k, v| request[k] = v }
        request.body = body

        response = http.request(request)
        [response.code.to_i, response.body, response.each_header.to_h]
      end
    end

    def validate_timeout(timeout)
      return timeout if timeout.nil?
      return timeout if timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?

      raise ConfigurationError, "timeout must be nil or a finite positive number, got #{timeout.inspect}"
    end

    # The transport contract grew a `timeout:` keyword so the client can hand
    # each attempt what is left of the retry budget. Transports written
    # against the old three-keyword contract still work: they are called the
    # way they always were.
    def transport_accepts_timeout?
      return @transport_accepts_timeout unless @transport_accepts_timeout.nil?

      parameters = @transport.respond_to?(:parameters) ? @transport.parameters : @transport.method(:call).parameters
      @transport_accepts_timeout = parameters.any? do |kind, name|
        kind == :keyrest || (%i[key keyreq].include?(kind) && name == :timeout)
      end
    end

    def call_transport(url:, headers:, body:, timeout:)
      if transport_accepts_timeout?
        @transport.call(url: url, headers: headers, body: body, timeout: timeout)
      else
        @transport.call(url: url, headers: headers, body: body)
      end
    end

    def perform_with_retry(url:, headers:, body:)
      policy = @retry_policy
      started_at = @clock.call
      retries = 0

      loop do
        begin
          status, response_body, response_headers = normalize_transport_result(
            call_transport(url: url, headers: headers, body: body,
                           timeout: attempt_timeout(policy, started_at))
          )
        rescue Error
          raise
        rescue StandardError => e
          raise_transport_error(e) unless policy.retryable_exception?(e) && retries < policy.max_retries

          delay = policy.backoff(retries, random: @random)
          raise_transport_error(e) if budget_exceeded?(policy, started_at, delay)

          @sleeper.call(delay)
          raise_transport_error(e) if budget_exceeded?(policy, started_at, 0.0)

          retries += 1
          next
        end

        result = [status, response_body, response_headers]
        return result unless policy.retryable_status?(status) && retries < policy.max_retries

        delay = policy.delay(retries, headers: response_headers, random: @random)
        return result if budget_exceeded?(policy, started_at, delay)

        @sleeper.call(delay)
        return result if budget_exceeded?(policy, started_at, 0.0)

        retries += 1
      end
    end

    def budget_exceeded?(policy, started_at, delay)
      return false if policy.total_timeout.nil?

      # >=, not >: a delay that lands exactly on the deadline has used the
      # whole budget, and the attempt after it would start with nothing left.
      (@clock.call - started_at) + delay >= policy.total_timeout
    end

    # What is left of the budget, or nil when there is no budget. Handed to
    # the transport so a single attempt cannot outlive the whole call: with
    # `timeout: 5` and 2s of budget left, the attempt gets 2s.
    def remaining_budget(policy, started_at)
      return nil if policy.total_timeout.nil?

      policy.total_timeout - (@clock.call - started_at)
    end

    def attempt_timeout(policy, started_at)
      remaining = remaining_budget(policy, started_at)
      return @timeout if remaining.nil?

      if remaining <= 0
        raise TimeoutError.new(
          "request budget of #{policy.total_timeout}s was exhausted before the attempt started",
          cause_error: nil
        )
      end

      @timeout.nil? ? remaining : [@timeout, remaining].min
    end

    def normalize_transport_result(result)
      status, response_body, response_headers = Array(result)
      [status, response_body, response_headers.is_a?(Hash) ? response_headers : {}]
    end

    def raise_transport_error(exception)
      if @retry_policy.timeout_exception?(exception)
        raise TimeoutError.new("request timed out: #{exception.message}", cause_error: exception)
      end

      raise TransportError.new("transport error: #{exception.message}", cause_error: exception)
    end

    def handle_response(status, response_body, response_headers, questions)
      case status
      when 200..299
        parse_success(response_body, response_headers, questions)
      when 401
        raise Unauthorized.new("unauthorized", status: status, body: response_body, headers: response_headers)
      when 413
        raise PayloadTooLarge.new("payload too large", status: status, body: response_body, headers: response_headers)
      when 422
        raise UnprocessableEntity.new("unprocessable entity", status: status, body: response_body,
                                                              headers: response_headers)
      when 429
        raise RateLimited.new("rate limited", status: status, body: response_body, headers: response_headers)
      when 529
        raise Overloaded.new("overloaded", status: status, body: response_body, headers: response_headers)
      else
        raise ApiError.new("api error (status #{status})", status: status, body: response_body,
                                                            headers: response_headers)
      end
    end

    def parse_success(response_body, response_headers, questions)
      raise InvalidResponse, "response body was empty" if response_body.nil? || response_body.to_s.strip.empty?

      parsed = begin
        JSON.parse(response_body.to_s)
      rescue JSON::ParserError => e
        raise InvalidResponse, "response body was not valid JSON: #{e.message}"
      end

      raise InvalidResponse, "response body was not a JSON object" unless parsed.is_a?(Hash)

      raw_answers = parsed["answers"]
      raw_answers = {} unless raw_answers.is_a?(Hash)

      normalized = {}
      malformed = []
      missing = []

      questions.each do |raw_id, question|
        id = raw_id.to_s
        answer_hash = raw_answers[id]
        expected_type = question_type(question)

        if answer_hash.is_a?(Hash) && answer_hash["type"] == expected_type
          begin
            normalized[id] = normalize_answer(expected_type, answer_hash)
          rescue MalformedAnswer
            malformed << id
          end
        else
          missing << id
        end
      end

      if malformed.any?
        raise InvalidResponse.new(
          "malformed answer fields for: #{malformed.join(', ')}",
          answers: normalized
        )
      end

      if missing.any?
        raise MissingAnswers.new(
          "missing or wrong-type answers for: #{missing.join(', ')}",
          answers: normalized,
          missing: missing
        )
      end

      Response.new(
        answers: normalized,
        usage: @provider.usage(parsed),
        model: parsed["model"],
        id: parsed["id"],
        raw: parsed,
        request_id: request_id_from(response_headers)
      )
    end

    def request_id_from(headers)
      return nil unless headers.is_a?(Hash)

      headers.each do |key, value|
        next unless key.to_s.casecmp?(REQUEST_ID_HEADER)

        return value.is_a?(Array) ? value.first : value
      end
      nil
    end

    class MalformedAnswer < StandardError; end

    def normalize_answer(type, hash)
      case type
      when "noul"
        noul = hash["noul"]
        raise MalformedAnswer unless noul.is_a?(Numeric)

        Answers::Noul.new(noul: noul.to_f, probabilities: hash_or_empty(hash["probabilities"]))
      when "choice"
        choice = hash["choice"]
        confidence = hash["confidence"]
        raise MalformedAnswer unless choice.is_a?(String) && confidence.is_a?(Numeric)

        Answers::Choice.new(
          choice: choice,
          confidence: confidence.to_f,
          probabilities: hash_or_empty(hash["probabilities"])
        )
      when "score"
        score = hash["score"]
        confidence = hash["confidence"]
        raise MalformedAnswer unless score.is_a?(Numeric) && confidence.is_a?(Numeric)

        Answers::Score.new(
          score: score.to_f,
          confidence: confidence.to_f,
          probabilities: hash_or_empty(hash["probabilities"]),
          legend: hash_or_empty(hash["legend"])
        )
      else
        raise MalformedAnswer
      end
    end

    def question_type(question)
      return nil unless question.is_a?(Hash)

      question["type"] || question[:type]
    end

    def hash_or_empty(value)
      value.is_a?(Hash) ? value : {}
    end
  end
end
