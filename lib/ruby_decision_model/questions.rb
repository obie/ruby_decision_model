# frozen_string_literal: true

module RubyDecisionModel
  # Pure builders for question hashes. No I/O.
  module Questions
    module_function

    def noul(instructions, criteria: nil)
      validate_instructions!(instructions)

      question = { "type" => "noul", "instructions" => instructions }
      question["criteria"] = criteria unless criteria.nil?
      question
    end

    def choice(instructions, criteria:)
      validate_instructions!(instructions)
      unless criteria.is_a?(Hash) && criteria.size.between?(1, 255)
        raise ArgumentError, "criteria must be a Hash with 1..255 entries"
      end

      stringified = {}
      criteria.each { |k, v| stringified[k.to_s] = v }

      { "type" => "choice", "instructions" => instructions, "criteria" => stringified }
    end

    def score(instructions, criteria:)
      validate_instructions!(instructions)
      unless criteria.is_a?(Array) && criteria.size.between?(2, 10)
        raise ArgumentError, "criteria must be an Array with 2..10 entries"
      end

      { "type" => "score", "instructions" => instructions, "criteria" => criteria }
    end

    def validate_instructions!(instructions)
      case instructions
      when String
        raise ArgumentError, "instructions must not be empty" if instructions.empty?
      when Hash, Array
        raise ArgumentError, "instructions must not be empty" if instructions.empty?
      else
        raise ArgumentError, "instructions must be a String, Hash, or Array"
      end
    end
    private_class_method :validate_instructions!
  end
end
