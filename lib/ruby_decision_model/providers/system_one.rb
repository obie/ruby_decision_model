# frozen_string_literal: true

require "uri"
require_relative "base"

module RubyDecisionModel
  module Providers
    # Any server that speaks Typesafe's System One API at /v1/systemone:
    # Ollama, the autojev server that ships with pplx-decider's weights,
    # strands-decider's local server, and hosted lookalikes. The base URL is
    # required and has no /v1 suffix. The API key and model are optional,
    # since local servers often run without auth and some pick their own
    # model. SYSTEM_ONE_BASE_URL and SYSTEM_ONE_API_KEY follow Pydantic AI.
    class SystemOne < Base
      BASE_URL_ENV_VAR = "SYSTEM_ONE_BASE_URL"

      def initialize(api_key: nil, base_url: nil)
        super
        @base_url ||= ENV.fetch(BASE_URL_ENV_VAR, nil)
      end

      def name
        :system_one
      end

      def env_var
        "SYSTEM_ONE_API_KEY"
      end

      def default_base_url
        nil
      end

      def endpoint_path
        "/v1/systemone"
      end

      def default_model
        nil
      end

      def requires_api_key?
        false
      end

      # A local server may load the model on the first request.
      def default_timeout
        30
      end

      # Sent as the System One images extension; servers without image
      # support reject the request.
      def supports_images?
        true
      end

      def validate!
        super
        return unless base_url.empty?

        raise ConfigurationError, "base_url is required for system_one: pass base_url: or set #{BASE_URL_ENV_VAR}"
      end

      # Checked when a request is built rather than in validate!, so a
      # client's own base_url: can still replace an unusable
      # SYSTEM_ONE_BASE_URL. Ollama hosts are often written as
      # localhost:11434, and whether the server speaks http or https is not
      # ours to guess; an empty host would quietly mean this machine.
      def url(model = nil)
        uri = URI.parse(base_url)
        unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
          raise ConfigurationError, "system_one base_url needs http:// or https:// and a host, got #{base_url.inspect}"
        end

        super
      rescue URI::InvalidURIError
        raise ConfigurationError, "system_one base_url is not a URL: #{base_url.inspect}"
      end

      def request_body(model:, state:, questions:, images: nil)
        body = {}
        body["model"] = model unless model.nil?
        body["state"] = state
        body["questions"] = questions
        body["images"] = images if images
        JSON.generate(body)
      end
    end
  end
end
