# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module RubyDecisionModel
  class Client
    DEFAULT_BASE_URL = "https://openrouter.ai/api/alpha"
    DEFAULT_MODEL = "typesafe/jev-1.13"
    RETRYABLE_STATUSES = [429, 500, 502, 503, 504, 524, 529].freeze
    RETRYABLE_EXCEPTIONS = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::EPIPE,
      SocketError,
      IOError
    ].freeze

    def initialize(api_key:, model: DEFAULT_MODEL, base_url: DEFAULT_BASE_URL, timeout: 5,
                    transport: nil, sleeper: ->(seconds) { sleep(seconds) })
      raise ConfigurationError, "api_key is required" if api_key.nil? || api_key.to_s.strip.empty?
      raise ConfigurationError, "model is required" if model.nil? || model.to_s.strip.empty?
      raise ConfigurationError, "base_url is required" if base_url.nil? || base_url.to_s.strip.empty?

      @api_key = api_key
      @model = model
      @base_url = base_url.to_s.chomp("/")
      @timeout = timeout
      @transport = transport || default_transport
      @sleeper = sleeper
    end

    def ask(state:, questions:)
      raise RequestError, "questions must not be empty" if questions.nil? || questions.empty?

      body = JSON.generate({ "model" => @model, "state" => state, "questions" => questions })
      headers = {
        "Authorization" => "Bearer #{@api_key}",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }

      status, response_body = perform_with_retry(url: "#{@base_url}/decisions", headers: headers, body: body)
      handle_response(status, response_body, questions)
    end

    private

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
        [response.code.to_i, response.body]
      end
    end

    def perform_with_retry(url:, headers:, body:)
      attempt = 0

      begin
        status, response_body = @transport.call(url: url, headers: headers, body: body)

        if RETRYABLE_STATUSES.include?(status) && attempt.zero?
          attempt += 1
          @sleeper.call(backoff_seconds)
          status, response_body = @transport.call(url: url, headers: headers, body: body)
        end

        [status, response_body]
      rescue *RETRYABLE_EXCEPTIONS => e
        if attempt.zero?
          attempt += 1
          @sleeper.call(backoff_seconds)
          retry
        end
        raise_transport_error(e)
      rescue StandardError => e
        raise_transport_error(e) unless e.is_a?(Error)
        raise
      end
    end

    def backoff_seconds
      0.5 + (rand * 0.25)
    end

    def raise_transport_error(exception)
      if exception.is_a?(Net::OpenTimeout) || exception.is_a?(Net::ReadTimeout)
        raise TimeoutError.new("request timed out: #{exception.message}", cause_error: exception)
      end

      raise TransportError.new("transport error: #{exception.message}", cause_error: exception)
    end

    def handle_response(status, response_body, questions)
      case status
      when 200..299
        parse_success(response_body, questions)
      when 401
        raise Unauthorized.new("unauthorized", status: status, body: response_body)
      when 413
        raise PayloadTooLarge.new("payload too large", status: status, body: response_body)
      when 429
        raise RateLimited.new("rate limited", status: status, body: response_body)
      else
        raise ApiError.new("api error (status #{status})", status: status, body: response_body)
      end
    end

    def parse_success(response_body, questions)
      parsed = begin
        JSON.parse(response_body)
      rescue JSON::ParserError => e
        raise InvalidResponse, "response body was not valid JSON: #{e.message}"
      end

      raise InvalidResponse, "response body was not a JSON object" unless parsed.is_a?(Hash)

      raw_answers = parsed["answers"]
      raw_answers = {} unless raw_answers.is_a?(Hash)

      normalized = {}
      malformed = []
      missing = []

      questions.each do |id, question|
        answer_hash = raw_answers[id]
        expected_type = question["type"]

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
        usage: normalize_usage(parsed["usage"]),
        model: parsed["model"],
        id: parsed["id"],
        raw: parsed
      )
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

    def hash_or_empty(value)
      value.is_a?(Hash) ? value : {}
    end

    def normalize_usage(usage)
      usage = {} unless usage.is_a?(Hash)

      Response::Usage.new(
        input_tokens: Integer(usage["input_tokens"], exception: false),
        output_tokens: Integer(usage["output_tokens"], exception: false),
        cost: Float(usage["cost"], exception: false)
      )
    end
  end
end
