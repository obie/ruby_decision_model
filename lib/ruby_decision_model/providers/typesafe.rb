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

      # The names the official Typesafe SDKs read; see
      # https://docs.typesafe.ai/sdk/python/api/constants.
      def base_url_env
        "TYPESAFE_BASE_URL"
      end

      def default_model_env
        "TYPESAFE_DEFAULT_MODEL"
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
    end
  end
end
