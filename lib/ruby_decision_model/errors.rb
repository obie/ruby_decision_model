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

  # One class per status the API documents, so a caller can rescue the case
  # it knows how to handle. The names follow the official Typesafe SDKs.
  class BadRequest < ApiError; end

  class Unauthorized < ApiError; end

  class PermissionDenied < ApiError; end

  class NotFound < ApiError; end

  class PayloadTooLarge < ApiError; end

  class UnprocessableEntity < ApiError; end

  class RateLimited < ApiError; end

  # Any 5xx. Overloaded is one, so `rescue ServerError` covers both and
  # `rescue Overloaded` still picks out the one the API defines.
  class ServerError < ApiError; end

  class Overloaded < ServerError; end

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
