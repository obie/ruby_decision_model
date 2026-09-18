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

    TYPES = %w[noul choice score].freeze

    # Checks one question -- built here or hand-rolled -- against the shape
    # the API documents, and raises RequestError naming the offending id.
    # Client#ask runs this over the whole map before it sends anything, so a
    # question that cannot be answered costs nothing.
    def validate!(question, id:)
      raise RequestError, "question #{id.inspect} must be a Hash, got #{question.class}" unless question.is_a?(Hash)

      type = field(question, "type")
      unless TYPES.include?(type.to_s)
        raise RequestError, "question #{id.inspect} has type #{type.inspect}; expected one of #{TYPES.join(', ')}"
      end

      validate_question_instructions!(question, id)
      validate_question_criteria!(question, id, type.to_s)
    end

    def field(question, name)
      question.fetch(name) { question[name.to_sym] }
    end

    def validate_question_instructions!(question, id)
      has_key = question.key?("instructions") || question.key?(:instructions)
      raise RequestError, "question #{id.inspect} is missing instructions" unless has_key

      instructions = field(question, "instructions")
      # nil is what the official SDKs call an undescribed entry; anything the
      # builders would reject as empty is rejected here too.
      return if instructions.nil?

      case instructions
      when String, Hash, Array
        raise RequestError, "question #{id.inspect} has empty instructions" if instructions.empty?
      else
        raise RequestError, "question #{id.inspect} has instructions of type #{instructions.class}"
      end
    end

    def validate_question_criteria!(question, id, type)
      criteria = field(question, "criteria")

      case type
      when "choice"
        unless criteria.is_a?(Hash) && criteria.size.between?(1, 255)
          raise RequestError, "choice question #{id.inspect} needs criteria: a Hash with 1..255 entries"
        end
      when "score"
        unless criteria.is_a?(Array) && criteria.size.between?(2, 10)
          raise RequestError, "score question #{id.inspect} needs criteria: an Array with 2..10 entries"
        end
      end
    end
    private_class_method :field, :validate_question_instructions!, :validate_question_criteria!

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
