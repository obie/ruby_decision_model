# frozen_string_literal: true

require "minitest/autorun"
require "ruby_decision_model"

# A fake transport for injecting into Client. Queue up [status, body] pairs
# (or exceptions to raise) and it returns/raises them in order, repeating the
# last entry once exhausted.
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

def no_sleep
  ->(_seconds) {}
end
