# frozen_string_literal: true

module RubyDecisionModel
  # Response headers arrive with whatever casing the server chose, and a
  # transport may hand back a value as an Array. One place that knows both.
  module Headers
    module_function

    def fetch(headers, name)
      return nil unless headers.is_a?(Hash)

      headers.each do |key, value|
        next unless key.to_s.casecmp?(name)

        return value.is_a?(Array) ? value.first : value
      end
      nil
    end
  end
end
