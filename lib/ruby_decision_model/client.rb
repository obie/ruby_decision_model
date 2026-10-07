# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module RubyDecisionModel
  class Client
    # Kept from 0.0.1 for callers that referenced them. They describe the
    # Typesafe and OpenRouter providers and the default RetryPolicy; prefer
    # those directly. Each provider now names its own request id header.
    REQUEST_ID_HEADER = "x-typesafe-request-id"
    DEFAULT_BASE_URL = Providers::OpenRouter.new.default_base_url
    DEFAULT_MODEL = Providers::OpenRouter.new.default_model
    MAX_ATTEMPTS = RetryPolicy.new.max_retries + 1
    RETRYABLE_STATUSES = RetryPolicy::DEFAULT_STATUSES
    RETRYABLE_EXCEPTIONS = (RetryPolicy::TIMEOUT_EXCEPTIONS + RetryPolicy::CONNECTION_EXCEPTIONS).freeze

    # Connecting is quick wherever the answer is slow, so the open timeout
    # stays short unless the caller sets timeout: explicitly.
    DEFAULT_OPEN_TIMEOUT = 5

    attr_reader :provider, :model, :retry_policy, :timeout, :open_timeout

    # provider:  a name from Providers.names or a Providers::Base instance.
    #            When nil, RUBY_DECISION_MODEL_PROVIDER names one if set;
    #            otherwise api_key: alone selects OpenRouter, and with no
    #            api_key: the environment decides (see Providers.from_env).
    # api_key:   overrides the provider's env var.
    # model:     nil means the provider default; aliases resolve per provider.
    # base_url:  overrides the provider base URL.
    # timeout:   read timeout in seconds, and open timeout too when given;
    #            nil means the provider's read default (5 for Jev-speed APIs,
    #            30 where the vendor documents multi-second responses) with a
    #            5 second open timeout.
    # transport: callable(url:, headers:, body:) returning
    #            [status, body_string, headers_hash] (a 2-element return is
    #            still accepted and treated as having no headers).
    # retry:     a RetryPolicy or a Hash of overrides.
    # random:    callable returning a Float in 0...1, used for backoff jitter.
    # clock:     callable returning monotonic seconds, used for total_timeout.
    def initialize(provider: nil, api_key: nil, model: nil, base_url: nil, timeout: nil,
                   transport: nil, sleeper: ->(seconds) { sleep(seconds) }, retry: {},
                   random: -> { rand }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @provider = resolve_provider(provider, api_key: api_key, base_url: base_url)
      @provider.validate!

      @model = @provider.resolve_model(model)
      @timeout = timeout || @provider.default_timeout
      @open_timeout = timeout || DEFAULT_OPEN_TIMEOUT
      @transport = transport || default_transport
      @sleeper = sleeper
      @retry_policy = RetryPolicy.from(binding.local_variable_get(:retry))
      @random = random
      @clock = clock
    end

    def base_url
      @provider.base_url
    end

    # images: data URLs (see Images) for providers that read images. Each
    # provider places them where its API expects.
    def ask(state:, questions:, images: nil)
      raise RequestError, "questions must not be empty" if questions.nil? || questions.empty?

      body = build_body(state, questions, images)
      status, response_body, response_headers = perform_with_retry(
        url: request_url, headers: @provider.headers, body: body
      )
      handle_response(status, response_body, response_headers, questions)
    end

    private

    # Providers written against 0.1.0 may override url without the model
    # argument added in 0.2.0.
    def request_url
      takes_model = @provider.method(:url).parameters.any? { |type, _| %i[req opt rest].include?(type) }
      takes_model ? @provider.url(@model) : @provider.url
    end

    def build_body(state, questions, images)
      images = Array(images)
      return @provider.request_body(model: @model, state: state, questions: questions) if images.empty?

      raise RequestError, "#{@provider.name} does not accept images" unless @provider.supports_images?

      images.each do |image|
        next if image.is_a?(String) && image.start_with?("data:image/")

        raise RequestError, "images must be data URLs (data:image/...); see RubyDecisionModel::Images"
      end

      @provider.request_body(model: @model, state: state, questions: questions, images: images)
    rescue JSON::GeneratorError, JSON::NestingError => e
      # The generator's message can quote the offending value, so it stays
      # on #cause rather than in a message that may be logged.
      raise RequestError, "state or questions could not be encoded as JSON (#{e.class})"
    end

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
          Providers.build(Providers.named_in_env || :open_router, api_key: api_key, base_url: base_url)
        end
      else
        raise ConfigurationError, "provider must be a Symbol or a Providers::Base, got #{provider.class}"
      end
    end

    def default_transport
      lambda do |url:, headers:, body:|
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @timeout
        http.write_timeout = @timeout

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

    ERROR_CLASSES = {
      401 => [Unauthorized, "unauthorized"],
      413 => [PayloadTooLarge, "payload too large"],
      422 => [UnprocessableEntity, "unprocessable entity"],
      429 => [RateLimited, "rate limited"],
      529 => [Overloaded, "overloaded"]
    }.freeze
    private_constant :ERROR_CLASSES

    def handle_response(status, response_body, response_headers, questions)
      return parse_success(response_body, response_headers, questions) if (200..299).cover?(status)

      klass, message = ERROR_CLASSES.fetch(status) { [ApiError, "api error (status #{status})"] }
      detail = @provider.error_message(response_body)
      message = "#{message}: #{detail}" if detail

      raise klass.new(message, status: status, body: response_body, headers: response_headers)
    end

    def parse_success(response_body, response_headers, questions)
      raise InvalidResponse, "response body was empty" if response_body.nil? || response_body.to_s.strip.empty?

      parsed = begin
        JSON.parse(response_body.to_s)
      rescue JSON::ParserError => e
        raise InvalidResponse, "response body was not valid JSON: #{e.message}"
      end

      raise InvalidResponse, "response body was not a JSON object" unless parsed.is_a?(Hash)

      canonical = @provider.normalize_response(parsed, questions: questions)
      raise InvalidResponse, "response body was not a JSON object" unless canonical.is_a?(Hash)

      raw_answers = canonical["answers"]
      raw_answers = {} unless raw_answers.is_a?(Hash)

      normalized = {}
      malformed = []
      missing = []
      refused = []

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
          refused << id if answer_hash.is_a?(Hash) && answer_hash["type"] == "refusal"
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
        message = "missing or wrong-type answers for: #{missing.join(', ')}"
        message += " (refused: #{refused.join(', ')})" if refused.any?
        raise MissingAnswers.new(message, answers: normalized, missing: missing, refused: refused)
      end

      Response.new(
        answers: normalized,
        usage: @provider.usage(canonical),
        model: canonical["model"],
        id: canonical["id"],
        raw: parsed,
        request_id: request_id_from(response_headers)
      )
    end

    def request_id_from(headers)
      header = @provider.request_id_header
      return nil unless header && headers.is_a?(Hash)

      headers.each do |key, value|
        next unless key.to_s.casecmp?(header)

        return value.is_a?(Array) ? value.first : value
      end
      nil
    end

    class MalformedAnswer < StandardError; end

    def normalize_answer(type, hash)
      case type
      when "noul"
        noul = hash["noul"]
        raise MalformedAnswer unless noul.is_a?(Numeric) && noul.between?(0, 1)

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
