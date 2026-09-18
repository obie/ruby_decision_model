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
    attr_reader :status, :body

    def initialize(message, status:, body:)
      super(message)
      @status = status
      @body = body
    end
  end

  class Unauthorized < ApiError; end

  class PayloadTooLarge < ApiError; end

  class RateLimited < ApiError; end

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
