# frozen_string_literal: true

require "minitest/autorun"
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

PROVIDER_ENV_VARS = %w[TYPESAFE_API_KEY OPENROUTER_API_KEY].freeze

# Temporarily sets environment variables (nil removes) for the block, then
# restores whatever was there before, even if the block raises.
def with_env(overrides)
  previous = overrides.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
  overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  yield
ensure
  previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
end

# Clears both provider env vars for the block.
def without_provider_env(&block)
  with_env(PROVIDER_ENV_VARS.to_h { |key| [key, nil] }, &block)
end
