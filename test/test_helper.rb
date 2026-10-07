# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "ruby_decision_model"

# A fake transport for injecting into Client. Queue up [status, body] or
# [status, body, headers] entries (or exceptions to raise) and it
# returns/raises them in order, repeating the last entry once exhausted.
class FakeTransport
  attr_reader :calls

  def initialize(responses)
    @responses = responses
    @calls = []
  end

  def call(url:, headers:, body:)
    @calls << { url: url, headers: headers, body: body }
    response = @responses.length > 1 ? @responses.shift : @responses.first
    raise response if response.is_a?(Exception)

    response
  end
end

# Stands in for Net::HTTP when a test needs the default transport. Records
# the settings Client applies and the requests it sends, and answers every
# request with the given body.
class RecordingHTTP
  Response = Struct.new(:code, :body) do
    def each_header
      {}.each
    end
  end

  attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout
  attr_reader :requests

  def initialize(body)
    @body = body
    @requests = []
  end

  def request(request)
    @requests << request
    Response.new("200", @body)
  end
end

# Makes Net::HTTP.new return `http` for the block. Done by hand because
# minitest 6 moved Object#stub out into a separate gem.
def with_net_http(http)
  original = Net::HTTP.method(:new)
  Net::HTTP.singleton_class.remove_method(:new)
  Net::HTTP.define_singleton_method(:new) { |*| http }
  yield
ensure
  Net::HTTP.singleton_class.remove_method(:new)
  Net::HTTP.define_singleton_method(:new, original)
end

# A sleeper that records what it was asked to wait instead of sleeping.
class RecordingSleeper
  attr_reader :delays

  def initialize
    @delays = []
  end

  def call(seconds)
    @delays << seconds
  end

  def to_proc
    method(:call).to_proc
  end
end

def no_sleep
  ->(_seconds) {}
end

# Every test starts without the developer's provider settings, so an
# exported RUBY_DECISION_MODEL_PROVIDER or SYSTEM_ONE_BASE_URL cannot reroute
# a test client. Whatever was set is restored afterwards.
module IsolateProviderEnv
  def before_setup
    super
    @saved_provider_env = PROVIDER_ENV_VARS.to_h { |key| [key, ENV.fetch(key, nil)] }
    PROVIDER_ENV_VARS.each { |key| ENV.delete(key) }
  end

  def after_teardown
    @saved_provider_env&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    super
  end
end
Minitest::Test.include(IsolateProviderEnv)

PROVIDER_ENV_VARS = %w[
  RUBY_DECISION_MODEL_PROVIDER TYPESAFE_API_KEY OPENROUTER_API_KEY SYSTEM_ONE_BASE_URL SYSTEM_ONE_API_KEY
  OPENAI_API_KEY CLOUDFLARE_API_TOKEN CLOUDFLARE_AUTH_TOKEN CLOUDFLARE_ACCOUNT_ID PERPLEXITY_API_KEY
  DATABRICKS_HOST DATABRICKS_TOKEN
].freeze

# Temporarily sets environment variables (nil removes) for the block, then
# restores whatever was there before, even if the block raises.
def with_env(overrides)
  previous = overrides.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
  overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  yield
ensure
  previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
end

# Clears every provider env var for the block.
def without_provider_env(&block)
  with_env(PROVIDER_ENV_VARS.to_h { |key| [key, nil] }, &block)
end
