# frozen_string_literal: true

require "test_helper"

# The API key travels in an Authorization header on every request, so the base
# URL is the thing that decides whether it stays secret.
class BaseUrlTest < Minitest::Test
  def build(base_url)
    RubyDecisionModel::Client.new(
      provider: :typesafe, api_key: "ts-secret", base_url: base_url, transport: FakeTransport.new([])
    )
  end

  def test_https_base_url_is_accepted
    client = build("https://api.typesafe.ai")
    assert_equal "https://api.typesafe.ai/v1/systemone", client.provider.url
  end

  def test_plain_http_base_url_is_rejected
    error = assert_raises(RubyDecisionModel::ConfigurationError) { build("http://api.typesafe.ai") }
    assert_match(/https/, error.message)
    assert_match(/cleartext/, error.message)
  end

  def test_plain_http_is_allowed_for_loopback_hosts
    %w[http://localhost:4000 http://127.0.0.1:4000 http://[::1]:4000].each do |url|
      client = build(url)
      assert_equal "#{url}/v1/systemone", client.provider.url
    end
  end

  def test_loopback_host_matching_ignores_case
    client = build("http://LOCALHOST:4000")
    assert_equal "http://LOCALHOST:4000/v1/systemone", client.provider.url
  end

  def test_non_http_scheme_is_rejected
    error = assert_raises(RubyDecisionModel::ConfigurationError) { build("ftp://api.typesafe.ai") }
    assert_match(/absolute http\(s\) URL/, error.message)
  end

  def test_base_url_without_a_host_is_rejected
    error = assert_raises(RubyDecisionModel::ConfigurationError) { build("api.typesafe.ai") }
    assert_match(/absolute http\(s\) URL/, error.message)
  end

  def test_unparseable_base_url_is_rejected
    error = assert_raises(RubyDecisionModel::ConfigurationError) { build("https://exa mple.com") }
    assert_match(/not a valid URL/, error.message)
  end

  def test_userinfo_in_base_url_is_rejected_and_not_echoed
    error = assert_raises(RubyDecisionModel::ConfigurationError) { build("https://user:pw@api.typesafe.ai") }
    assert_match(/userinfo/, error.message)
    refute_includes error.message, "pw"
  end

  def test_query_or_fragment_in_base_url_is_rejected
    # "https://api.typesafe.ai/p?x=1" + "/v1/systemone" would POST to /p.
    ["https://api.typesafe.ai/p?x=1", "https://api.typesafe.ai/p#frag"].each do |url|
      error = assert_raises(RubyDecisionModel::ConfigurationError) { build(url) }
      assert_match(/query or fragment/, error.message)
    end
  end

  def test_userinfo_host_confusion_is_rejected
    # Reads as trusted.example, resolves to evil.example.
    error = assert_raises(RubyDecisionModel::ConfigurationError) do
      build("https://trusted.example@evil.example/p")
    end
    assert_match(/userinfo/, error.message)
  end

  def test_env_supplied_http_base_url_is_rejected_too
    error = assert_raises(RubyDecisionModel::ConfigurationError) do
      RubyDecisionModel::Client.new(
        provider: RubyDecisionModel::Providers::Typesafe.new(api_key: "k", base_url: "http://evil.example.com"),
        transport: FakeTransport.new([])
      )
    end
    assert_match(/cleartext/, error.message)
  end

  def test_the_default_base_urls_pass_validation
    with_env("TYPESAFE_API_KEY" => "ts-key", "OPENROUTER_API_KEY" => "or-key") do
      RubyDecisionModel::Providers.names.each do |name|
        client = RubyDecisionModel::Client.new(provider: name, transport: FakeTransport.new([]))
        assert_match(%r{\Ahttps://}, client.base_url)
      end
    end
  end
end
