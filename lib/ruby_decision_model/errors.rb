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
    attr_reader :status, :body, :headers

    def initialize(message, status:, body:, headers: {})
      super(message)
      @status = status
      @body = body
      @headers = headers || {}
    end
  end

  class Unauthorized < ApiError; end

  class PayloadTooLarge < ApiError; end

  class UnprocessableEntity < ApiError; end

  class RateLimited < ApiError; end

  class Overloaded < ApiError; end

  # The response was larger than max_response_bytes. Carries how far the
  # client got before it gave up, and the limit it was measured against.
  class ResponseTooLarge < Error
    attr_reader :bytes, :limit

    def initialize(message, bytes: nil, limit: nil)
      super(message)
      @bytes = bytes
      @limit = limit
    end
  end

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
