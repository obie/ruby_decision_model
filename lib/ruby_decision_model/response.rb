# frozen_string_literal: true

module RubyDecisionModel
  class Response
    Usage = Data.define(:input_tokens, :output_tokens, :cost)

    attr_reader :answers, :usage, :model, :id, :raw, :request_id

    def initialize(answers:, usage:, model:, id:, raw:, request_id: nil)
      @answers = answers
      @usage = usage
      @model = model
      @id = id
      @raw = raw
      @request_id = request_id
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
