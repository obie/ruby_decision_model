# frozen_string_literal: true

require_relative "base"

module RubyDecisionModel
  module Providers
    # Databricks ai_decide over REST (beta). Questions are System One, but
    # the workspace serves one managed model, so the body has no model and
    # Client#model is nil. Answers arrive under "response", and a noul
    # carries "probability" where System One says "noul". Usage and ids are
    # not reported.
    class Databricks < Base
      HOST_ENV_VAR = "DATABRICKS_HOST"

      def initialize(api_key: nil, base_url: nil)
        super
        @base_url ||= ENV.fetch(HOST_ENV_VAR, nil)
      end

      def name
        :databricks
      end

      def env_var
        "DATABRICKS_TOKEN"
      end

      def default_base_url
        nil
      end

      # DATABRICKS_HOST is often set without a scheme.
      def base_url
        host = super
        return host if host.empty? || host.match?(%r{\Ahttps?://})

        "https://#{host}"
      end

      # Beta serverless endpoint with no published latency figures.
      def default_timeout
        30
      end

      def endpoint_path
        "/api/2.0/ai-functions/ai-decide"
      end

      def default_model
        nil
      end

      def resolve_model(model)
        return nil if model.nil? || model.to_s.strip.empty?

        raise ConfigurationError, "databricks serves ai_decide's managed model and takes no model: (got #{model.inspect})"
      end

      def validate!
        super
        return unless base_url.empty?

        raise ConfigurationError, "base_url is required for databricks: pass base_url: or set #{HOST_ENV_VAR}"
      end

      def request_body(model:, state:, questions:)
        JSON.generate("state" => state, "questions" => questions)
      end

      def normalize_response(parsed, questions:)
        if parsed["response"].nil? && parsed["error_message"]
          raise InvalidResponse, "databricks ai_decide error: #{vendor_text(parsed['error_message'])}"
        end

        response = parsed["response"].is_a?(Hash) ? parsed["response"] : {}
        answers = response["answers"].is_a?(Hash) ? response["answers"] : {}
        answers = answers.transform_values do |answer|
          next answer unless answer.is_a?(Hash) && answer["type"] == "noul" && !answer.key?("noul")

          answer.merge("noul" => answer["probability"])
        end

        super({ "answers" => answers }, questions: questions)
      end
    end
  end
end
