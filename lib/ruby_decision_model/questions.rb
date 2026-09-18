# frozen_string_literal: true

module RubyDecisionModel
  # Pure builders for question hashes. No I/O.
  module Questions
    module_function

    # The keys a noul's criteria may carry. The wire wants "true" and
    # "false"; Ruby's booleans are accepted and stringified, since that is
    # how the hash reads best at a call site.
    NOUL_CRITERIA_KEYS = %w[true false].freeze

    def noul(instructions, criteria: nil)
      validate_instructions!(instructions)

      question = { "type" => "noul", "instructions" => instructions }
      question["criteria"] = validate_noul_criteria!(criteria) unless criteria.nil?
      question
    end

    def choice(instructions, criteria:)
      validate_instructions!(instructions)
      unless criteria.is_a?(Hash) && criteria.size.between?(1, 255)
        raise ArgumentError, "criteria must be a Hash with 1..255 entries"
      end

      { "type" => "choice", "instructions" => instructions,
        "criteria" => stringify_labels(criteria) }
    end

    def score(instructions, criteria:)
      validate_instructions!(instructions)
      unless criteria.is_a?(Array) && criteria.size.between?(2, 10)
        raise ArgumentError, "criteria must be an Array with 2..10 entries"
      end

      criteria.each_with_index { |level, i| validate_description!(level, "criteria[#{i}]") }

      { "type" => "score", "instructions" => instructions, "criteria" => criteria }
    end

    # Option labels go over the wire as JSON object keys, so they are
    # stringified. Two labels that stringify the same would silently become
    # one option, and the model would be offered a rubric the caller did not
    # write, so say so instead.
    def stringify_labels(criteria)
      criteria.each_with_object({}) do |(label, description), stringified|
        key = label.to_s
        if stringified.key?(key)
          raise ArgumentError, "criteria labels collide once stringified: two entries are both #{key.inspect}"
        end
        raise ArgumentError, "criteria labels must not be blank" if key.strip.empty?

        validate_description!(description, "criteria[#{key.inspect}]")
        stringified[key] = description
      end
    end

    # noul criteria describe what a yes and a no mean. Anything else is a
    # 422 from the API, and choice and score have always said so at the call
    # site rather than over the wire.
    def validate_noul_criteria!(criteria)
      unless criteria.is_a?(Hash)
        raise ArgumentError, "criteria must be a Hash with true and false descriptions, got #{criteria.class}"
      end

      criteria.each_with_object({}) do |(outcome, description), stringified|
        key = outcome.to_s
        unless NOUL_CRITERIA_KEYS.include?(key)
          raise ArgumentError,
                "criteria keys must be #{NOUL_CRITERIA_KEYS.join(' and ')}, got #{outcome.inspect}"
        end
        raise ArgumentError, "criteria has #{key.inspect} twice" if stringified.key?(key)

        validate_description!(description, "criteria[#{key.inspect}]")
        stringified[key] = description
      end
    end

    # A description is an EntryType: text, structure, or nil for undescribed.
    def validate_description!(description, where)
      return if description.nil?
      return if description.is_a?(String) || description.is_a?(Hash) || description.is_a?(Array)

      raise ArgumentError, "#{where} must be a String, Hash, Array, or nil, got #{description.class}"
    end
    private_class_method :stringify_labels, :validate_noul_criteria!, :validate_description!

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
