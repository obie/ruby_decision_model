# frozen_string_literal: true

require_relative "providers/base"
require_relative "providers/open_router"
require_relative "providers/typesafe"
require_relative "providers/openai"
require_relative "providers/cloudflare"
require_relative "providers/perplexity"
require_relative "providers/databricks"
require_relative "providers/system_one"

module RubyDecisionModel
  module Providers
    REGISTRY = {
      open_router: OpenRouter,
      typesafe: Typesafe,
      openai: OpenAI,
      cloudflare: Cloudflare,
      perplexity: Perplexity,
      databricks: Databricks,
      system_one: SystemOne
    }.freeze

    # Names a provider from the environment, ahead of any key sniffing.
    PROVIDER_ENV_VAR = "RUBY_DECISION_MODEL_PROVIDER"

    module_function

    def names
      REGISTRY.keys
    end

    # Names are matched without regard to case, and `-` reads as `_`, so
    # "OpenAI" and "open-router" from an env file both resolve.
    def build(name, api_key: nil, base_url: nil)
      klass = REGISTRY[name.to_s.strip.downcase.tr("-", "_").to_sym]
      raise ConfigurationError, "unknown provider #{name.inspect}; known providers: #{names.join(', ')}" if klass.nil?

      klass.new(api_key: api_key, base_url: base_url)
    end

    # Order in which environment variables are consulted when no provider or
    # api_key is given. Typesafe wins when several are set. Only settings
    # that exist for decision models take part; general-purpose credentials
    # such as OPENAI_API_KEY or CLOUDFLARE_API_TOKEN never pick a provider
    # on their own. Name those with RUBY_DECISION_MODEL_PROVIDER.
    ENV_PRIORITY = [Typesafe, OpenRouter, SystemOne].freeze

    # The provider name RUBY_DECISION_MODEL_PROVIDER holds, or nil.
    def named_in_env
      named = ENV.fetch(PROVIDER_ENV_VAR, nil).to_s.strip
      named.empty? ? nil : named
    end

    # Picks a provider from the environment, or nil when nothing is set.
    # RUBY_DECISION_MODEL_PROVIDER wins when present, even if that provider
    # turns out to be missing its key, so the error names the right thing.
    def from_env
      named = named_in_env
      return build(named) if named

      ENV_PRIORITY.each do |klass|
        provider = klass.new
        return provider if provider.configured?
      end
      nil
    end

    def env_vars
      [PROVIDER_ENV_VAR] + ENV_PRIORITY.map { |klass| env_var_for(klass) }
    end

    def env_var_for(klass)
      klass == SystemOne ? SystemOne::BASE_URL_ENV_VAR : klass.new.env_var
    end
    private_class_method :env_var_for
  end
end
