# frozen_string_literal: true

module RubyDecisionModel
  class Response
    Usage = Data.define(:input_tokens, :output_tokens, :cost)

    REQUEST_ID_HEADER = "x-typesafe-request-id"

    attr_reader :answers, :usage, :model, :id, :raw, :headers

    def initialize(answers:, usage:, model:, id:, raw:, headers: {})
      @answers = answers
      @usage = usage
      @model = model
      @id = id
      @raw = raw
      @headers = headers || {}
    end

    # The provider's id for this request, when it sends one.
    def request_id
      Headers.fetch(headers, REQUEST_ID_HEADER)
    end

    # A header by name, matched without regard to case.
    def header(name)
      Headers.fetch(headers, name)
    end

    def [](id)
      answers[id]
    end

    # Answers filtered by type, keyed the same way as #answers.
    def nouls
      answers_of_type("noul")
    end

    def choices
      answers_of_type("choice")
    end

    def scores
      answers_of_type("score")
    end

    private

    def answers_of_type(type)
      answers.select { |_id, answer| answer.type == type }
    end
  end
end
