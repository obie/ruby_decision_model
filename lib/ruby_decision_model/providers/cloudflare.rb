# frozen_string_literal: true

require_relative "base"

module RubyDecisionModel
  module Providers
    # Cloudflare's Clef and Clef-flash on Workers AI. The body is System One
    # with Cloudflare's images extension; the model also appears in the
    # path, and the account id is required. Responses arrive inside the
    # Workers AI envelope ({"result": ..., "success": true}), which is
    # unwrapped here.
    class Cloudflare < Base
      ALIASES = {
        "cloudflare/clef" => "clef",
        "cloudflare/clef-flash" => "clef-flash",
        "@cf/cloudflare/clef" => "clef",
        "@cf/cloudflare/clef-flash" => "clef-flash"
      }.freeze

      # Cloudflare's own tooling reads CLOUDFLARE_API_TOKEN; the Clef docs
      # use CLOUDFLARE_AUTH_TOKEN. Either works, in that order.
      FALLBACK_ENV_VAR = "CLOUDFLARE_AUTH_TOKEN"
      ACCOUNT_ENV_VAR = "CLOUDFLARE_ACCOUNT_ID"

      # Both end up in the request path, so they are held to characters that
      # cannot leave it.
      ACCOUNT_ID_PATTERN = /\A[A-Za-z0-9_-]+\z/
      MODEL_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

      attr_reader :account_id

      def initialize(api_key: nil, base_url: nil, account_id: nil)
        # A blank CLOUDFLARE_API_TOKEN must not hide CLOUDFLARE_AUTH_TOKEN.
        token = [env_var, FALLBACK_ENV_VAR].filter_map { |name| ENV.fetch(name, nil) }.find { |v| !v.strip.empty? }
        super(api_key: api_key || token, base_url: base_url)
        @account_id = (account_id || ENV.fetch(ACCOUNT_ENV_VAR, nil))&.to_s&.strip
      end

      def name
        :cloudflare
      end

      def env_var
        "CLOUDFLARE_API_TOKEN"
      end

      def default_base_url
        "https://api.cloudflare.com/client/v4"
      end

      def endpoint_path
        "/accounts/#{account_id}/ai/run/@cf/cloudflare"
      end

      # Checked here as well as at build time, since configure can change the
      # account id on a provider a client already holds.
      def url(model = nil)
        model ||= default_model
        unless account_id.to_s.match?(ACCOUNT_ID_PATTERN) && model.to_s.match?(MODEL_PATTERN)
          raise ConfigurationError,
                "cloudflare account_id and model must stay inside the URL path, got #{account_id.inspect} and #{model.inspect}"
        end

        "#{base_url}#{endpoint_path}/#{model}"
      end

      def default_model
        "clef"
      end

      def aliases
        ALIASES
      end

      def supports_images?
        true
      end

      def request_id_header
        "cf-ray"
      end

      def validate!
        super
        if account_id.nil? || account_id.to_s.strip.empty?
          raise ConfigurationError, "account_id is required for cloudflare: pass account_id: or set #{ACCOUNT_ENV_VAR}"
        end
        return if account_id.to_s.match?(ACCOUNT_ID_PATTERN)

        raise ConfigurationError, "cloudflare account_id must be letters, digits, - or _, got #{account_id.inspect}"
      end

      def resolve_model(model)
        resolved = super
        return resolved if resolved.match?(MODEL_PATTERN)

        raise ConfigurationError, "cloudflare model must be a bare Workers AI name such as clef, got #{model.inspect}"
      end

      # Unwraps the Workers AI envelope. A body that says success: false
      # carries no answers, so its errors become the exception message.
      def normalize_response(parsed, questions:)
        if parsed["success"] == false
          detail = vendor_text(error_text(parsed))
          raise InvalidResponse, ["cloudflare reported failure", detail].compact.join(": ")
        end

        body = parsed["result"].is_a?(Hash) ? parsed["result"] : parsed
        super(body, questions: questions)
      end

      def configure(api_key: nil, base_url: nil, account_id: nil)
        super(api_key: api_key, base_url: base_url)
        @account_id = account_id.to_s.strip unless account_id.nil?
        self
      end
    end
  end
end
