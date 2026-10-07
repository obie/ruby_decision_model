# frozen_string_literal: true

require_relative "base"

module RubyDecisionModel
  module Providers
    class OpenRouter < Base
      # Short names resolve to the decision models OpenRouter routes, so the
      # same model: works here and on each vendor's own provider.
      ALIASES = {
        "jev" => "typesafe/jev-1.13",
        "jev-latest" => "typesafe/jev-1.13",
        "luna" => "openai/gpt-6-luna-decisions",
        "gpt-6-luna" => "openai/gpt-6-luna-decisions",
        "clef" => "cloudflare/clef",
        "clef-flash" => "cloudflare/clef-flash",
        "pplx-decider" => "perplexity/pplx-decider-v1-27b",
        "pplx-decider-v1-27b" => "perplexity/pplx-decider-v1-27b"
      }.freeze

      def name
        :open_router
      end

      def env_var
        "OPENROUTER_API_KEY"
      end

      def default_base_url
        "https://openrouter.ai/api/alpha"
      end

      def endpoint_path
        "/decisions"
      end

      def default_model
        "typesafe/jev-1.13"
      end

      def aliases
        ALIASES
      end

      def reports_cost?
        true
      end
    end
  end
end
