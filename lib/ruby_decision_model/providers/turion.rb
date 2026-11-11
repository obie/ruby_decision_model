# frozen_string_literal: true

require_relative "base"

module RubyDecisionModel
  module Providers
    # Turion's hosted copy of Turion Jev 31B, an open-weights decision model.
    # The endpoint and the body are System One.
    class Turion < Base
      ALIASES = {
        "turion/turion-jev-31b" => "turion-jev-31b",
        "turion-ai/turion-jev-31b" => "turion-jev-31b"
      }.freeze

      def name
        :turion
      end

      def env_var
        "TURION_API_KEY"
      end

      def default_base_url
        "https://api.turion.ai"
      end

      def endpoint_path
        "/v1/systemone"
      end

      def default_model
        "turion-jev-31b"
      end

      def aliases
        ALIASES
      end

      def request_id_header
        "x-request-id"
      end
    end
  end
end
