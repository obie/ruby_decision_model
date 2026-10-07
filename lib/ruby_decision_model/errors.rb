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

  class InvalidResponse < Error
    attr_reader :answers

    def initialize(message, answers: {})
      super(message)
      @answers = answers
    end
  end

  # Raised when any question went unanswered. `missing` lists every such id.
  # `refused` lists the ones the provider explicitly declined, a subset of
  # `missing`. Answers that did arrive are on `answers`.
  class MissingAnswers < InvalidResponse
    attr_reader :missing, :refused

    def initialize(message, answers: {}, missing: [], refused: [])
      super(message, answers: answers)
      @missing = missing
      @refused = refused
    end
  end
end
