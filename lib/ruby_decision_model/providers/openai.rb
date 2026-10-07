# frozen_string_literal: true

require_relative "base"

module RubyDecisionModel
  module Providers
    # OpenAI's Decisions API (public beta, gpt-6-luna). Its wire format
    # differs from System One in every direction, so this provider
    # translates both ways:
    #
    # - state becomes `input`. Strings pass through; anything else is sent
    #   as JSON text, since the API has no structured input. Images become
    #   input_image parts on a single user message.
    # - questions become a named array. noul is `predicate`; a noul with
    #   true/false criteria becomes a boolean `choice` so the descriptions
    #   reach the model, and its answer is read back as a noul. choice
    #   criteria become `choices`, score criteria become `levels`.
    # - answers come back as an array of predicate/choice/score/refusal
    #   objects with probability arrays, and are rebuilt keyed by id with
    #   probability Hashes and a score legend.
    class OpenAI < Base
      ALIASES = {
        "luna" => "gpt-6-luna",
        "openai/gpt-6-luna" => "gpt-6-luna",
        "openai/gpt-6-luna-decisions" => "gpt-6-luna",
        "gpt-6-luna-decisions" => "gpt-6-luna"
      }.freeze

      def name
        :openai
      end

      def env_var
        "OPENAI_API_KEY"
      end

      def default_base_url
        "https://api.openai.com/v1"
      end

      def endpoint_path
        "/decisions"
      end

      def default_model
        "gpt-6-luna"
      end

      def aliases
        ALIASES
      end

      # Inputs run to a million tokens, and OpenAI publishes no latency
      # figures for this endpoint yet.
      def default_timeout
        30
      end

      def supports_images?
        true
      end

      def request_id_header
        "x-request-id"
      end

      def request_body(model:, state:, questions:, images: nil)
        JSON.generate(
          "model" => model,
          "input" => input(state, images),
          "questions" => questions.map { |id, question| encode_question(id.to_s, question) }
        )
      end

      # Answers are matched by name. An unnamed answer falls back to its
      # position, since the API answers in question order, but never onto an
      # id some other answer names. An id answered twice is ambiguous, so it
      # reads as malformed rather than letting one answer (or a refusal)
      # silently replace another.
      def normalize_response(parsed, questions:)
        by_id = questions.to_h { |id, question| [id.to_s, question] }
        ids = by_id.keys
        entries = Array(parsed["answers"])
        named = entries.filter_map { |answer| answer["name"] if answer.is_a?(Hash) && answer["name"].is_a?(String) }
        answers = {}

        entries.each_with_index do |answer, index|
          next unless answer.is_a?(Hash)

          id = answer["name"].is_a?(String) ? answer["name"] : ids[index]
          next if id.nil? || (!answer["name"].is_a?(String) && named.include?(id))

          answers[id] = answers.key?(id) ? ambiguous(by_id[id]) : decode_answer(answer, by_id[id])
        end

        { "id" => parsed["id"], "model" => parsed["model"], "answers" => answers, "usage" => parsed["usage"] }
      end

      private

      def input(state, images)
        text = state_text(state)
        return text if images.nil? || images.empty?

        content = []
        content << { "type" => "input_text", "text" => text } unless text.empty?
        images.each { |url| content << { "type" => "input_image", "image_url" => url } }
        [{ "role" => "user", "content" => content }]
      end

      def state_text(state)
        case state
        when String then state
        when nil then ""
        else JSON.generate(state)
        end
      end

      def encode_question(id, question)
        question = stringify(question)
        instructions = question["instructions"]
        raise RequestError, "question #{id} needs instructions for openai" if instructions.nil?

        instructions = JSON.generate(instructions) unless instructions.is_a?(String)
        criteria = question["criteria"]

        case question["type"]
        when "noul"
          return { "name" => id, "type" => "predicate", "instructions" => instructions } unless criteria.is_a?(Hash)

          descriptions = stringify(criteria)
          { "name" => id, "type" => "choice", "instructions" => instructions,
            "choices" => [true, false].map { |value| described({ "value" => value }, descriptions[value.to_s]) } }
        when "choice"
          { "name" => id, "type" => "choice", "instructions" => instructions,
            "choices" => stringify(criteria).map { |value, text| described({ "value" => value }, text) } }
        when "score"
          { "name" => id, "type" => "score", "instructions" => instructions,
            "levels" => Array(criteria).map { |level| encode_level(level) } }
        else
          question.merge("name" => id)
        end
      end

      # Jev score criteria are descriptions: usually strings, sometimes
      # objects. A Hash with a label keeps its label and description;
      # anything else becomes the label as text.
      def encode_level(level)
        level = stringify(level) if level.is_a?(Hash)
        return described({ "label" => level["label"].to_s }, level["description"]) if level.is_a?(Hash) && level.key?("label")
        return { "label" => level } if level.is_a?(String)

        { "label" => JSON.generate(level) }
      end

      def described(hash, description)
        return hash if description.nil?

        hash.merge("description" => description.is_a?(String) ? description : JSON.generate(description))
      end

      def decode_answer(answer, question)
        question = stringify(question)

        case answer["type"]
        when "predicate"
          { "type" => "noul", "noul" => answer["probability"] }
        when "choice"
          question["type"] == "noul" ? decode_boolean_choice(answer) : decode_choice(answer)
        when "score"
          decode_score(answer, Array(question["criteria"]))
        when "refusal"
          { "type" => "refusal" }
        else
          answer
        end.then { |decoded| noul_probabilities(decoded) }
      end

      # Carries the expected type with none of its fields, so Client reports
      # the id as malformed.
      def ambiguous(question)
        { "type" => stringify(question)["type"] }
      end

      def decode_boolean_choice(answer)
        return { "type" => "noul" } if duplicate_values?(answer)

        entry = probability_entries(answer).find { |item| item["value"] == true }
        { "type" => "noul", "noul" => entry && entry["probability"] }
      end

      def decode_choice(answer)
        return { "type" => "choice" } if duplicate_values?(answer)

        probabilities = probability_entries(answer).to_h { |item| [item["value"].to_s, item["probability"]] }
        choice = answer["choice"]
        choice = choice.to_s if [true, false].include?(choice)

        { "type" => "choice", "choice" => choice, "confidence" => answer["confidence"], "probabilities" => probabilities }
      end

      # The legend maps each level index to the criteria entry the caller
      # wrote, as Jev does, falling back to the label OpenAI echoes.
      def decode_score(answer, criteria)
        return { "type" => "score" } if duplicate_values?(answer)

        entries = probability_entries(answer)
        legend = entries.to_h do |item|
          index = item["value"]
          [index.to_s, index.is_a?(Integer) && index.between?(0, criteria.size - 1) ? criteria[index] : item["label"]]
        end

        { "type" => "score", "score" => answer["score"], "confidence" => answer["confidence"],
          "probabilities" => entries.to_h { |item| [item["value"].to_s, item["probability"]] },
          "legend" => legend }
      end

      def probability_entries(answer)
        Array(answer["probabilities"]).select { |item| item.is_a?(Hash) && item.key?("value") }
      end

      # Two entries for one value make the split ambiguous. The answer then
      # carries no fields and Client reports it as malformed. Values compare
      # as the string keys the decoded probabilities use, so true and "true"
      # (or 1 and "1") count as the same value rather than one silently
      # replacing the other.
      def duplicate_values?(answer)
        values = probability_entries(answer).map { |item| item["value"].to_s }
        values.uniq.size != values.size
      end

      def stringify(hash)
        hash.is_a?(Hash) ? hash.transform_keys(&:to_s) : {}
      end
    end
  end
end
