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
          input_tokens: token_count(raw, "input_tokens"),
          output_tokens: token_count(raw, "output_tokens"),
          cost: reports_cost? ? cost(raw) : nil
        )
      end

      # A token count is a whole number of tokens. Integer(..., exception:
      # false) accepted a good deal more than that: 30.9 became 30, "120"
      # became 120, and anything it could not read at all -- [], true, an
      # error object where usage should be -- became nil, indistinguishable
      # from a provider that simply does not report the field. Requests are
      # billed per input token, so a usage number that quietly became nil or
      # lost its fraction is worse than no number.
      #
      # An absent field is still nil. A present one has to be a count.
      def token_count(raw, name)
        return nil unless raw.key?(name)

        value = raw[name]
        return nil if value.nil?
        return value if value.is_a?(Integer)
        return Integer(value) if value.is_a?(Float) && value.finite? && (value % 1).zero?

        raise InvalidResponse, "usage.#{name} is not a token count: #{value.inspect}"
      end

      def cost(raw)
        return nil unless raw.key?("cost")

        value = raw["cost"]
        return nil if value.nil?
        return value.to_f if value.is_a?(Numeric) && value.finite?

        raise InvalidResponse, "usage.cost is not a number: #{value.inspect}"
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
