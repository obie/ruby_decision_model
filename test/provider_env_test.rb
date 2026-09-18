# frozen_string_literal: true

require "test_helper"

# The environment variables the official SDKs define, and the order an
# explicit argument, the environment, and the built-in default are consulted.
class ProviderEnvTest < Minitest::Test
  ALL = %w[TYPESAFE_API_KEY TYPESAFE_BASE_URL TYPESAFE_DEFAULT_MODEL
           OPENROUTER_API_KEY OPENROUTER_BASE_URL OPENROUTER_DEFAULT_MODEL].freeze

  def with_clean_env(overrides = {})
    with_env(ALL.to_h { |key| [key, nil] }.merge(overrides)) { yield }
  end

  def client(**options)
    RubyDecisionModel::Client.new(**{ transport: FakeTransport.new([]) }.merge(options))
  end

  # --- base url ---

  def test_base_url_comes_from_the_environment
    with_clean_env("TYPESAFE_API_KEY" => "k", "TYPESAFE_BASE_URL" => "https://staging.typesafe.example") do
      assert_equal "https://staging.typesafe.example", client(provider: :typesafe).base_url
    end
  end

  def test_an_explicit_base_url_wins_over_the_environment
    with_clean_env("TYPESAFE_API_KEY" => "k", "TYPESAFE_BASE_URL" => "https://from-env.example") do
      assert_equal "https://explicit.example",
                   client(provider: :typesafe, base_url: "https://explicit.example").base_url
    end
  end

  def test_the_built_in_default_is_used_when_the_variable_is_unset
    with_clean_env("TYPESAFE_API_KEY" => "k") do
      assert_equal "https://api.typesafe.ai", client(provider: :typesafe).base_url
    end
  end

  def test_a_blank_variable_is_ignored
    with_clean_env("TYPESAFE_API_KEY" => "k", "TYPESAFE_BASE_URL" => "  ") do
      assert_equal "https://api.typesafe.ai", client(provider: :typesafe).base_url
    end
  end

  def test_open_router_reads_its_own_variable
    with_clean_env("OPENROUTER_API_KEY" => "k", "OPENROUTER_BASE_URL" => "https://proxy.example") do
      assert_equal "https://proxy.example", client(provider: :open_router).base_url
    end
  end

  def test_one_providers_variable_does_not_reach_another
    with_clean_env("OPENROUTER_API_KEY" => "k", "TYPESAFE_BASE_URL" => "https://typesafe-only.example") do
      assert_equal "https://openrouter.ai/api/alpha", client(provider: :open_router).base_url
    end
  end

  # --- default model ---

  def test_default_model_comes_from_the_environment
    with_clean_env("TYPESAFE_API_KEY" => "k", "TYPESAFE_DEFAULT_MODEL" => "jev-1.13.0") do
      assert_equal "jev-1.13.0", client(provider: :typesafe).model
    end
  end

  def test_an_explicit_model_wins_over_the_environment
    with_clean_env("TYPESAFE_API_KEY" => "k", "TYPESAFE_DEFAULT_MODEL" => "jev-1.13.0") do
      assert_equal "jev-preview", client(provider: :typesafe, model: "jev-preview").model
    end
  end

  def test_a_model_from_the_environment_still_goes_through_aliases
    with_clean_env("TYPESAFE_API_KEY" => "k", "TYPESAFE_DEFAULT_MODEL" => "jev") do
      assert_equal "jev-latest", client(provider: :typesafe).model
    end
  end

  def test_the_built_in_default_model_is_used_when_unset
    with_clean_env("TYPESAFE_API_KEY" => "k") do
      assert_equal "jev-latest", client(provider: :typesafe).model
    end
  end

  def test_a_blank_default_model_variable_is_ignored
    with_clean_env("TYPESAFE_API_KEY" => "k", "TYPESAFE_DEFAULT_MODEL" => "") do
      assert_equal "jev-latest", client(provider: :typesafe).model
    end
  end

  # --- providers that declare nothing keep the old behaviour ---

  def test_a_provider_without_extra_variables_is_unaffected
    bare = Class.new(RubyDecisionModel::Providers::Base) do
      def name = :bare
      def env_var = "BARE_API_KEY"
      def default_base_url = "https://bare.example"
      def endpoint_path = "/decide"
      def default_model = "bare-1"
    end.new(api_key: "k")

    assert_nil bare.base_url_env
    assert_nil bare.default_model_env
    assert_equal "https://bare.example", bare.base_url
    assert_equal "bare-1", bare.resolve_model(nil)
  end
end
