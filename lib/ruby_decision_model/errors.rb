# frozen_string_literal: true

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
    REQUEST_ID_HEADER = "x-typesafe-request-id"

    attr_reader :status, :body, :headers, :endpoint

    def initialize(message, status:, body:, headers: {}, endpoint: nil)
      super(message)
      @status = status
      @body = body
      @headers = headers || {}
      @endpoint = endpoint
    end

    # The provider's id for the request that failed. This is the one worth
    # quoting when reporting a problem, and a failure is when you report one.
    def request_id
      Headers.fetch(headers, REQUEST_ID_HEADER)
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
