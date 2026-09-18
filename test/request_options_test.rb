# frozen_string_literal: true

require "test_helper"

# Headers and model, set once on the client or per call.
class RequestOptionsTest < Minitest::Test
  def questions
    { "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?") }
  end

  def success_body
    JSON.generate("answers" => { "urgent" => { "type" => "noul", "noul" => 0.5 } }, "usage" => {})
  end

  def transport
    @transport ||= FakeTransport.new([[200, success_body]])
  end

  def build_client(**options)
    RubyDecisionModel::Client.new(
      **{ api_key: "test-key", transport: transport, sleeper: no_sleep }.merge(options)
    )
  end

  def sent
    transport.calls.first
  end

  def sent_headers
    sent[:headers]
  end

  def sent_model
    JSON.parse(sent[:body])["model"]
  end

  # --- headers ---

  def test_the_provider_headers_are_sent_by_default
    build_client.ask(state: {}, questions: questions)

    assert_equal "Bearer test-key", sent_headers["Authorization"]
    assert_equal "application/json", sent_headers["Content-Type"]
    assert_match(%r{\Aruby_decision_model/}, sent_headers["User-Agent"])
  end

  def test_client_headers_are_added
    # OpenRouter reads these for app attribution.
    build_client(headers: { "HTTP-Referer" => "https://example.com", "X-Title" => "My App" })
      .ask(state: {}, questions: questions)

    assert_equal "https://example.com", sent_headers["HTTP-Referer"]
    assert_equal "My App", sent_headers["X-Title"]
    assert_equal "Bearer test-key", sent_headers["Authorization"]
  end

  def test_per_call_headers_are_added
    build_client.ask(state: {}, questions: questions, headers: { "X-Trace-Id" => "abc" })

    assert_equal "abc", sent_headers["X-Trace-Id"]
  end

  def test_per_call_headers_win_over_client_headers
    build_client(headers: { "X-Tenant" => "default" })
      .ask(state: {}, questions: questions, headers: { "X-Tenant" => "acme" })

    assert_equal "acme", sent_headers["X-Tenant"]
  end

  def test_an_override_replaces_rather_than_duplicates_a_provider_header
    build_client(headers: { "user-agent" => "my-app/1.0" }).ask(state: {}, questions: questions)

    agents = sent_headers.select { |name, _| name.to_s.casecmp?("user-agent") }
    assert_equal 1, agents.size
    assert_equal "my-app/1.0", agents.values.first
  end

  def test_the_client_headers_hash_is_readable
    assert_equal({ "X-Title" => "t" }, build_client(headers: { "X-Title" => "t" }).headers)
    assert_empty build_client.headers
  end

  def test_headers_do_not_leak_between_calls
    transport = FakeTransport.new([[200, success_body], [200, success_body]])
    client = RubyDecisionModel::Client.new(api_key: "k", transport: transport, sleeper: no_sleep)

    client.ask(state: {}, questions: questions, headers: { "X-Once" => "1" })
    client.ask(state: {}, questions: questions)

    assert_equal "1", transport.calls[0][:headers]["X-Once"]
    refute transport.calls[1][:headers].key?("X-Once")
  end

  # --- header values Net::HTTP would choke on ---

  def test_a_header_value_with_a_newline_is_refused
    error = assert_raises(RubyDecisionModel::ConfigurationError) do
      build_client(headers: { "X-Thing" => "a\r\nX-Injected: yes" })
    end
    assert_match(/contains a newline/, error.message)
  end

  def test_a_blank_or_malformed_header_name_is_refused
    assert_raises(RubyDecisionModel::ConfigurationError) { build_client(headers: { "" => "v" }) }
    assert_raises(RubyDecisionModel::ConfigurationError) { build_client(headers: { "X: Y" => "v" }) }
  end

  def test_headers_must_be_a_hash
    assert_raises(RubyDecisionModel::ConfigurationError) { build_client(headers: [%w[a b]]) }
  end

  def test_a_bad_per_call_header_is_refused_before_the_request
    client = build_client
    assert_raises(RubyDecisionModel::ConfigurationError) do
      client.ask(state: {}, questions: questions, headers: { "X" => "a\nb" })
    end
    assert_empty transport.calls
  end

  # --- model ---

  def test_the_client_model_is_sent_by_default
    build_client.ask(state: {}, questions: questions)

    assert_equal "typesafe/jev-1.13", sent_model
  end

  def test_a_per_call_model_overrides_it
    build_client.ask(state: {}, questions: questions, model: "some/other-model")

    assert_equal "some/other-model", sent_model
  end

  def test_a_per_call_model_goes_through_the_providers_aliases
    build_client(provider: :typesafe).ask(state: {}, questions: questions, model: "jev")

    assert_equal "jev-latest", sent_model
  end

  def test_a_per_call_model_does_not_change_the_client
    client = build_client
    client.ask(state: {}, questions: questions, model: "other")

    assert_equal "typesafe/jev-1.13", client.model
  end
end
