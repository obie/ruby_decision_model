# frozen_string_literal: true

require_relative "providers/base"
require_relative "providers/open_router"
require_relative "providers/typesafe"

module RubyDecisionModel
  module Providers
    REGISTRY = {
      open_router: OpenRouter,
      typesafe: Typesafe
    }.freeze

    module_function

    def names
      REGISTRY.keys
    end

    def build(name, api_key: nil, base_url: nil)
      klass = REGISTRY[name.to_s.to_sym]
      raise ConfigurationError, "unknown provider #{name.inspect}; known providers: #{names.join(', ')}" if klass.nil?

      klass.new(api_key: api_key, base_url: base_url)
    end

    # Order in which environment variables are consulted when no provider or
    # api_key is given. Typesafe wins when both keys are set.
    ENV_PRIORITY = [Typesafe, OpenRouter].freeze

    # Picks a provider from the environment, or nil when no key is set.
    def from_env
      ENV_PRIORITY.each do |klass|
        provider = klass.new
        return provider if provider.api_key?
      end
      nil
    end

    def env_vars
      ENV_PRIORITY.map { |klass| klass.new.env_var }
    end
  end
end
