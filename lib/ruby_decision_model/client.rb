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
      validate_answer_contract(@provider)
      unless @provider.api_key?
        raise ConfigurationError,
              "api_key is required for #{@provider.name}: pass api_key: or set #{@provider.env_var}"
      end

      @model = @provider.resolve_model(model)
      @timeout = timeout
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

    # A provider that requires a field the client does not model would be
    # declaring a contract nothing enforces. Say so when the client is built
    # rather than letting the guarantee quietly do nothing.
    def validate_answer_contract(provider)
      provider.required_answer_fields.each do |type, names|
        known = ANSWER_FIELDS[type]
        raise ConfigurationError, "#{provider.name} requires fields for unknown answer type #{type.inspect}" if known.nil?

        unknown = names.map(&:to_s) - known.keys
        next if unknown.empty?

        raise ConfigurationError,
              "#{provider.name} requires answer fields the client does not model: " \
              "#{unknown.join(', ')} on #{type} answers"
      end
    end

    def default_transport
      lambda do |url:, headers:, body:|
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @timeout
        http.read_timeout = @timeout

        request = Net::HTTP::Post.new(uri.request_uri)
        headers.each { |k, v| request[k] = v }
        request.body = body

        response = http.request(request)
        [response.code.to_i, response.body, response.each_header.to_h]
      end
    end

    def perform_with_retry(url:, headers:, body:)
      policy = @retry_policy
      started_at = @clock.call
      retries = 0

      loop do
        begin
          status, response_body, response_headers = normalize_transport_result(
            @transport.call(url: url, headers: headers, body: body)
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

      (@clock.call - started_at) + delay > policy.total_timeout
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
            normalized[id] = normalize_answer(expected_type, answer_hash, question)
          rescue MalformedAnswer => e
            malformed << "#{id} (#{e.message})"
          end
        else
          missing << id
        end
      end

      if malformed.any?
        raise InvalidResponse.new(
          "malformed answer fields for: #{malformed.join('; ')}",
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

    # Every field an answer can carry, and the shape each one has to have.
    # A field absent from this map is ignored; Response#raw still has it.
    ANSWER_FIELDS = {
      # Neither provider's schema has probabilities on a noul answer -- the
      # value is the probability -- but it is read when one turns up rather
      # than dropped, and Answers::Noul has carried the field since 0.0.1.
      "noul" => { "noul" => :probability, "probabilities" => :distribution },
      "choice" => { "choice" => :label, "confidence" => :probability, "probabilities" => :distribution },
      "score" => { "score" => :number, "confidence" => :probability,
                   "probabilities" => :distribution, "legend" => :map }
    }.freeze

    # Probabilities are floats off a model, so a distribution can land a hair
    # over 1.0 without being wrong.
    PROBABILITY_TOLERANCE = 1e-6

    def normalize_answer(type, hash, question)
      fields = ANSWER_FIELDS[type]
      raise MalformedAnswer, "unsupported answer type #{type.inspect}" if fields.nil?

      required = @provider.required_answer_fields.fetch(type, fields.keys)
      values = fields.to_h { |name, shape| [name, read_answer_field(hash, name, shape, required)] }
      check_choice_is_offered(values["choice"], question) if type == "choice"

      build_answer(type, values)
    end

    def read_answer_field(hash, name, shape, required)
      raw = hash[name]

      if raw.nil?
        raise MalformedAnswer, "#{name} is missing" if required.include?(name)

        return %i[distribution map].include?(shape) ? {} : nil
      end

      case shape
      when :probability then unit_interval(name, raw)
      when :number then finite_number(name, raw)
      when :label then label(name, raw)
      when :distribution then distribution(name, raw)
      when :map then raw.is_a?(Hash) ? raw : raise(MalformedAnswer, "#{name} is not an object")
      end
    end

    def finite_number(name, raw)
      raise MalformedAnswer, "#{name} is not a number" unless raw.is_a?(Numeric)
      # JSON turns 1e999 into Infinity and some encoders emit NaN. Neither is
      # an answer, and both survive every is_a?(Numeric) check downstream.
      raise MalformedAnswer, "#{name} is not finite (#{raw})" unless raw.finite?

      raw.to_f
    end

    def unit_interval(name, raw)
      value = finite_number(name, raw)
      unless value >= -PROBABILITY_TOLERANCE && value <= 1.0 + PROBABILITY_TOLERANCE
        raise MalformedAnswer, "#{name} is outside 0..1 (#{value})"
      end

      value.clamp(0.0, 1.0)
    end

    def label(name, raw)
      raise MalformedAnswer, "#{name} is not a string" unless raw.is_a?(String)
      raise MalformedAnswer, "#{name} is empty" if raw.empty?

      raw
    end

    def distribution(name, raw)
      raise MalformedAnswer, "#{name} is not an object" unless raw.is_a?(Hash)

      raw.to_h { |key, value| [key, unit_interval("#{name}[#{key.inspect}]", value)] }
    end

    # A choice the question never offered cannot be routed on, and reading it
    # as a label the application knows is exactly the mistake this guards.
    def check_choice_is_offered(choice, question)
      return if choice.nil?

      criteria = question.is_a?(Hash) ? (question["criteria"] || question[:criteria]) : nil
      return unless criteria.is_a?(Hash)

      offered = criteria.keys.map(&:to_s)
      return if offered.include?(choice)

      raise MalformedAnswer, "choice #{choice.inspect} is not one of the question's criteria (#{offered.join(', ')})"
    end

    def build_answer(type, values)
      case type
      when "noul"
        Answers::Noul.new(noul: values["noul"], probabilities: values["probabilities"])
      when "choice"
        Answers::Choice.new(choice: values["choice"], confidence: values["confidence"],
                            probabilities: values["probabilities"])
      when "score"
        Answers::Score.new(score: values["score"], confidence: values["confidence"],
                           probabilities: values["probabilities"], legend: values["legend"])
      end
    end

    def question_type(question)
      return nil unless question.is_a?(Hash)

      question["type"] || question[:type]
    end

  end
end
