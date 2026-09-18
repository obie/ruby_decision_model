# frozen_string_literal: true

require "test_helper"
require "yaml"

# The API key must not survive a trip through anything that writes the object
# out. inspect is only one of those.
class RedactionTest < Minitest::Test
  SECRET = "sk-super-secret-value"

  def provider(**options)
    RubyDecisionModel::Providers::Typesafe.new(**{ api_key: SECRET }.merge(options))
  end

  def without_key(&block)
    with_env("TYPESAFE_API_KEY" => nil, &block)
  end

  def test_inspect_redacts
    refute_includes provider.inspect, SECRET
    assert_includes provider.inspect, "[REDACTED]"
  end

  def test_inspect_says_nil_when_there_is_no_key
    without_key { assert_includes RubyDecisionModel::Providers::Typesafe.new.inspect, "api_key=nil" }
  end

  def test_marshal_does_not_carry_the_key
    refute_includes Marshal.dump(provider), SECRET
  end

  def test_yaml_does_not_carry_the_key
    refute_includes YAML.dump(provider), SECRET
  end

  def test_a_client_dumped_to_yaml_does_not_carry_the_key
    client = RubyDecisionModel::Client.new(provider: provider, transport: FakeTransport.new([]))

    refute_includes YAML.dump(client), SECRET
  end

  def test_marshal_keeps_the_base_url
    restored = Marshal.load(Marshal.dump(provider(base_url: "https://staging.example")))

    assert_equal "https://staging.example", restored.base_url
  end

  def test_yaml_keeps_the_base_url
    restored = YAML.unsafe_load(YAML.dump(provider(base_url: "https://staging.example")))

    assert_equal "https://staging.example", restored.base_url
  end

  def test_a_restored_provider_reads_the_key_from_the_environment
    dumped = Marshal.dump(provider)

    with_env("TYPESAFE_API_KEY" => "sk-from-env") do
      assert_equal "sk-from-env", Marshal.load(dumped).api_key
    end
  end

  def test_a_restored_provider_without_the_environment_has_no_key
    dumped = Marshal.dump(provider)

    without_key do
      restored = Marshal.load(dumped)
      refute_predicate restored, :api_key?
      # and says so plainly rather than sending a Bearer with nothing after it
      assert_raises(RubyDecisionModel::ConfigurationError) do
        RubyDecisionModel::Client.new(provider: restored, transport: FakeTransport.new([]))
      end
    end
  end

  def test_a_restored_provider_still_works
    with_env("TYPESAFE_API_KEY" => "sk-from-env") do
      restored = Marshal.load(Marshal.dump(provider))
      transport = FakeTransport.new([[200, JSON.generate(
        "answers" => { "q" => { "type" => "noul", "noul" => 0.5 } }, "usage" => {}
      )]])
      client = RubyDecisionModel::Client.new(provider: restored, transport: transport, sleeper: no_sleep)

      client.ask(state: {}, questions: { "q" => RubyDecisionModel::Questions.noul("Urgent?") })

      assert_equal "Bearer sk-from-env", transport.calls.first[:headers]["Authorization"]
    end
  end

  def test_the_key_is_still_readable_in_process
    assert_equal SECRET, provider.api_key
  end

  def test_every_provider_redacts
    RubyDecisionModel::Providers.names.each do |name|
      built = RubyDecisionModel::Providers.build(name, api_key: SECRET)

      refute_includes built.inspect, SECRET, name.to_s
      refute_includes Marshal.dump(built), SECRET, name.to_s
      refute_includes YAML.dump(built), SECRET, name.to_s
    end
  end
end
