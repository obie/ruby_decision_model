# frozen_string_literal: true

require "net/http"
require "openssl"

require_relative "ruby_decision_model/version"
require_relative "ruby_decision_model/headers"
require_relative "ruby_decision_model/errors"
require_relative "ruby_decision_model/questions"
require_relative "ruby_decision_model/answers"
require_relative "ruby_decision_model/response"
require_relative "ruby_decision_model/providers"
require_relative "ruby_decision_model/retry_policy"
require_relative "ruby_decision_model/client"

module RubyDecisionModel
  class << self
    # A memoized default client built from the environment. Reset with
    # `RubyDecisionModel.client = nil`.
    def client
      @client ||= Client.new
    end

    attr_writer :client
  end
end
