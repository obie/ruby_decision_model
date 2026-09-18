# frozen_string_literal: true

module RubyDecisionModel
  module Answers
    Noul = Data.define(:noul, :probabilities) do
      def type
        "noul"
      end

      def probability
        noul
      end
    end

    Choice = Data.define(:choice, :confidence, :probabilities) do
      def type
        "choice"
      end
    end

    Score = Data.define(:score, :confidence, :probabilities, :legend) do
      def type
        "score"
      end
    end
  end
end
