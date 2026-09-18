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
    end
  end
end
