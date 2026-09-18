# frozen_string_literal: true

require "json"

module RubyDecisionModel
  class Error < StandardError; end

  class ConfigurationError < Error; end

  class RequestError < Error; end

  class TransportError < Error
    attr_reader :cause_error

    def initialize(message, cause_error: nil)
      super(message)
      @cause_error = cause_error
    end
  end

  class TimeoutError < TransportError; end

  class ApiError < Error
    attr_reader :status, :body, :headers

    def initialize(message, status:, body:, headers: {})
      @status = status
      @body = body
      @headers = headers || {}
      super(detail.nil? ? message : "#{message}: #{detail}")
    end

    # What the server said went wrong, when it said anything parseable.
    # Typesafe's 422 names the offending field; OpenRouter answers with
    # {"error": {"code": ..., "message": ...}}. Both are plain strings on
    # #body, which means every caller that wants the reason writes this.
    def detail
      return @detail if defined?(@detail)

      @detail = extract("message") || extract("error_description")
    end

    def error_code
      return @error_code if defined?(@error_code)

      @error_code = extract("code") || extract("type")
    end

    # The decoded error body, or nil when it was not a JSON object.
    def parsed_body
      return @parsed_body if defined?(@parsed_body)

      @parsed_body = begin
        decoded = JSON.parse(body.to_s)
        decoded.is_a?(Hash) ? decoded : nil
      rescue JSON::ParserError, TypeError
        nil
      end
    end

    private

    # Reads a field from the error object, whether the payload nests it under
    # "error" or puts it at the top level.
    def extract(field)
      return nil if parsed_body.nil?

      nested = parsed_body["error"]
      value = nested.is_a?(Hash) ? nested[field] : parsed_body[field]
      value = parsed_body[field] if value.nil?
      return nil unless value.is_a?(String) || value.is_a?(Integer)

      stringified = value.to_s
      stringified.empty? ? nil : stringified
    end
  end

  class Unauthorized < ApiError; end

  class PayloadTooLarge < ApiError; end

  class UnprocessableEntity < ApiError; end

  class RateLimited < ApiError; end

  class Overloaded < ApiError; end

  class InvalidResponse < Error
    attr_reader :answers

    def initialize(message, answers: {})
      super(message)
      @answers = answers
    end
  end

  class MissingAnswers < InvalidResponse
    attr_reader :missing

    def initialize(message, answers: {}, missing: [])
      super(message, answers: answers)
      @missing = missing
    end
  end
end
