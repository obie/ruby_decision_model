# frozen_string_literal: true

require_relative "base"

module RubyDecisionModel
  module Providers
    # Perplexity's Decisions API serving pplx-decider. The body is System One.
    # Images ride inside state as OpenAI-style image_url parts, so state
    # becomes an array when images are present.
    class Perplexity < Base
      ALIASES = {
        "pplx-decider" => "pplx-decider-v1.1-27b",
        "perplexity/pplx-decider-v1-27b" => "pplx-decider-v1-27b"
      }.freeze

      def name
        :perplexity
      end

      def env_var
        "PERPLEXITY_API_KEY"
      end

      def default_base_url
        "https://api.perplexity.ai"
      end

      def endpoint_path
        "/v1/decisions"
      end

      def default_model
        "pplx-decider-v1.1-27b"
      end

      def aliases
        ALIASES
      end

      # Perplexity documents 5 to 23 seconds for large inputs and uses 30 in
      # its own examples.
      def default_timeout
        30
      end

      def supports_images?
        true
      end

      def request_id_header
        "x-request-id"
      end

      def request_body(model:, state:, questions:, images: nil)
        return super(model: model, state: state, questions: questions) if images.nil? || images.empty?

        parts = images.map { |url| { "type" => "image_url", "image_url" => { "url" => url } } }
        super(model: model, state: state_parts(state) + parts, questions: questions)
      end

      private

      def state_parts(state)
        case state
        when nil then []
        when String then state.empty? ? [] : [state]
        when Array then state
        else [JSON.generate(state)]
        end
      end
    end
  end
end
