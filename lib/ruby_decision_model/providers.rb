# frozen_string_literal: true

require_relative "providers/base"
require_relative "providers/open_router"
require_relative "providers/typesafe"

module RubyDecisionModel
  module Providers
    # Providers shipped with this gem. A gem can add its own with ::register,
    # which is how a provider lives outside this repository.
    REGISTRY = {
      open_router: OpenRouter,
      typesafe: Typesafe
    }

    module_function

    def names
      REGISTRY.keys
    end

    # Teach this gem about a provider defined elsewhere.
    #
    #   module RubyDecisionModel
    #     module Providers
    #       class Acme < Base
    #         def name = :acme
    #         def env_var = "ACME_API_KEY"
    #         def default_base_url = "https://api.acme.example"
    #         def endpoint_path = "/v1/decisions"
    #         def default_model = "acme-1"
    #       end
    #     end
    #   end
    #
    #   RubyDecisionModel::Providers.register(:acme, RubyDecisionModel::Providers::Acme)
    #
    # Call it when your gem is required. After that `Client.new(provider: :acme)`
    # works like any provider in this repository. Registering a name twice
    # replaces it, so an application can override one deliberately.
    def register(name, klass)
      key = name.to_s.to_sym
      raise ConfigurationError, "provider name must not be empty" if key.to_s.empty?

      unless klass.is_a?(Class) && klass <= Base
        raise ConfigurationError, "provider must be a Class inheriting from #{Base}, got #{klass.inspect}"
      end

      REGISTRY[key] = klass
      key
    end

    def registered?(name)
      REGISTRY.key?(name.to_s.to_sym)
    end

    def build(name, api_key: nil, base_url: nil, **options)
      klass = REGISTRY[name.to_s.to_sym]
      raise ConfigurationError, "unknown provider #{name.inspect}; known providers: #{names.join(', ')}" if klass.nil?

      klass.new(api_key: api_key, base_url: base_url, **options)
    end

    # Order in which environment variables are consulted when no provider or
    # api_key is given. Typesafe wins when both keys are set. Registered
    # providers are not consulted: choosing one is explicit.
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
