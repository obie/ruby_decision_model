# frozen_string_literal: true

require_relative "base"

module RubyDecisionModel
  module Providers
    class OpenRouter < Base
      ALIASES = {
        "jev" => "typesafe/jev-1.13",
        "jev-latest" => "typesafe/jev-1.13"
      }.freeze

      def name
        :open_router
      end

      def env_var
        "OPENROUTER_API_KEY"
      end

      def base_url_env
        "OPENROUTER_BASE_URL"
      end

      def default_model_env
        "OPENROUTER_DEFAULT_MODEL"
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
