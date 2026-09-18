# frozen_string_literal: true

module RubyDecisionModel
  class Response
    Usage = Data.define(:input_tokens, :output_tokens, :cost)

    attr_reader :answers, :usage, :model, :id, :raw

    def initialize(answers:, usage:, model:, id:, raw:)
      @answers = answers
      @usage = usage
      @model = model
      @id = id
      @raw = raw
    end

    def [](id)
      answers[id]
    end
  end
end
