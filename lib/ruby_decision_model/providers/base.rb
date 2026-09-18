# frozen_string_literal: true

require "json"

module RubyDecisionModel
  module Providers
    # A provider owns everything that differs between decision-model APIs:
    # where requests go, how they are authenticated, which model is the
    # default, which model names are aliases, and how usage is read back.
    # Client keeps the public API and delegates these questions here.
    class Base
      attr_reader :api_key

      def initialize(api_key: nil, base_url: nil)
        @api_key = api_key || ENV.fetch(env_var, nil)
        @base_url = base_url
      end

      # Identifier used in error messages and by Client#provider.
      def name
        raise NotImplementedError
      end

      def env_var
        raise NotImplementedError
      end

      def default_base_url
        raise NotImplementedError
      end

      def endpoint_path
        raise NotImplementedError
      end

      def default_model
        raise NotImplementedError
      end

      # Map of alias => canonical model name for this provider.
      def aliases
        {}
      end

      # Whether this provider reports a per-request cost in usage.
      def reports_cost?
        false
      end

      def base_url
        (@base_url || default_base_url).to_s.chomp("/")
      end

      def url
        "#{base_url}#{endpoint_path}"
      end

      # Where this provider lists the models its `model` field accepts, or
      # nil when it does not offer a list.
      def models_path
        nil
      end

      def lists_models?
        !models_path.nil?
      end

      def models_url
        "#{base_url}#{models_path}" if lists_models?
      end

      def api_key?
        !(api_key.nil? || api_key.to_s.strip.empty?)
      end

      # Nil or blank means the provider default. Known aliases resolve to the
      # provider's canonical name. Anything else passes through untouched.
      def resolve_model(model)
        return default_model if model.nil? || model.to_s.strip.empty?

        aliases.fetch(model.to_s, model.to_s)
      end

      def headers
        {
          "Authorization" => "Bearer #{api_key}",
          "Content-Type" => "application/json",
          "Accept" => "application/json",
          "User-Agent" => "ruby_decision_model/#{VERSION}"
        }
      end

      def request_body(model:, state:, questions:)
        JSON.generate({ "model" => model, "state" => state, "questions" => questions })
      end

      def usage(parsed)
        raw = parsed.is_a?(Hash) && parsed["usage"].is_a?(Hash) ? parsed["usage"] : {}

        Response::Usage.new(
          input_tokens: Integer(raw["input_tokens"], exception: false),
          output_tokens: Integer(raw["output_tokens"], exception: false),
          cost: reports_cost? ? Float(raw["cost"], exception: false) : nil
        )
      end

      # Keeps the API key out of logs and error output.
      def inspect
        "#<#{self.class.name} name=#{name.inspect} base_url=#{base_url.inspect} api_key=#{api_key? ? '[REDACTED]' : 'nil'}>"
      end

      # Applies non-nil overrides in place. Used when a caller hands Client a
      # provider instance together with api_key: or base_url:.
      def configure(api_key: nil, base_url: nil)
        @api_key = api_key unless api_key.nil?
        @base_url = base_url unless base_url.nil?
        self
      end
    end
  end
end
