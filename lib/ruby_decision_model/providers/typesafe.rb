# frozen_string_literal: true

require_relative "base"

module RubyDecisionModel
  module Providers
    class Typesafe < Base
      ALIASES = {
        "typesafe/jev-1.13" => "jev-latest",
        "jev" => "jev-latest"
      }.freeze

      def name
        :typesafe
      end

      def env_var
        "TYPESAFE_API_KEY"
      end

      def default_base_url
        "https://api.typesafe.ai"
      end

      def endpoint_path
        "/v1/systemone"
      end

      def default_model
        "jev-latest"
      end

      def aliases
        ALIASES
      end

      # https://docs.typesafe.ai/api documents probabilities, confidence, and
      # legend as required on the answers that carry them, so a response
      # missing one is a broken response rather than a sparse one.
      REQUIRED_ANSWER_FIELDS = {
        "noul" => %w[noul],
        "choice" => %w[choice probabilities confidence],
        "score" => %w[score probabilities confidence legend]
      }.freeze

      def required_answer_fields
        REQUIRED_ANSWER_FIELDS
      end
    end
  end
end
