# frozen_string_literal: true

require "test_helper"

class OpenAIProviderTest < Minitest::Test
  Q = RubyDecisionModel::Questions

  def questions
    {
      "urgent" => Q.noul("Is this urgent?"),
      "department" => Q.choice("Which department?", criteria: { "billing" => "Charges and refunds", "other" => nil }),
      "severity" => Q.score("How severe?", criteria: ["Cosmetic", "Workaround", "Blocked"])
    }
  end

  # Shapes follow the OpenAI Decisions guide and API reference.
  def success_body
    JSON.generate(
      "model" => "gpt-6-luna",
      "answers" => [
        { "type" => "predicate", "name" => "urgent", "probability" => 0.92 },
        { "type" => "choice", "name" => "department", "choice" => "billing", "confidence" => 0.93,
          "probabilities" => [{ "value" => "billing", "probability" => 0.95 },
                              { "value" => "other", "probability" => 0.05 }] },
        { "type" => "score", "name" => "severity", "score" => 1.1, "confidence" => 0.55,
          "probabilities" => [{ "value" => 0, "label" => "Cosmetic", "probability" => 0.1 },
                              { "value" => 1, "label" => "Workaround", "probability" => 0.7 },
                              { "value" => 2, "label" => "Blocked", "probability" => 0.2 }] }
      ],
      "usage" => { "input_tokens" => 40, "input_tokens_details" => { "cached_tokens" => 0 },
                   "output_tokens" => 0, "total_tokens" => 40 }
    )
  end

  def client(transport, **options)
    RubyDecisionModel::Client.new(provider: :openai, api_key: "sk-test", transport: transport, sleeper: no_sleep,
                                  **options)
  end

  def test_defaults
    provider = RubyDecisionModel::Providers::OpenAI.new(api_key: "k")
    assert_equal "https://api.openai.com/v1/decisions", provider.url
    assert_equal "gpt-6-luna", provider.resolve_model(nil)
    assert_equal "OPENAI_API_KEY", provider.env_var
  end

  def test_aliases
    provider = RubyDecisionModel::Providers::OpenAI.new(api_key: "k")
    assert_equal "gpt-6-luna", provider.resolve_model("luna")
    assert_equal "gpt-6-luna", provider.resolve_model("openai/gpt-6-luna-decisions")
    assert_equal "gpt-6-luna-2026-10-06", provider.resolve_model("gpt-6-luna-2026-10-06")
  end

  def test_request_translates_questions_and_state
    transport = FakeTransport.new([[200, success_body, {}]])
    client(transport).ask(state: { title: "Charged twice" }, questions: questions)

    call = transport.calls.first
    assert_equal "https://api.openai.com/v1/decisions", call[:url]
    assert_equal "Bearer sk-test", call[:headers]["Authorization"]

    body = JSON.parse(call[:body])
    assert_equal %w[model input questions], body.keys
    assert_equal "gpt-6-luna", body["model"]
    assert_equal '{"title":"Charged twice"}', body["input"]
    assert_equal(
      [
        { "name" => "urgent", "type" => "predicate", "instructions" => "Is this urgent?" },
        { "name" => "department", "type" => "choice", "instructions" => "Which department?",
          "choices" => [{ "value" => "billing", "description" => "Charges and refunds" }, { "value" => "other" }] },
        { "name" => "severity", "type" => "score", "instructions" => "How severe?",
          "levels" => [{ "label" => "Cosmetic" }, { "label" => "Workaround" }, { "label" => "Blocked" }] }
      ],
      body["questions"]
    )
  end

  def test_string_state_passes_through_as_input
    transport = FakeTransport.new([[200, success_body, {}]])
    client(transport).ask(state: "I was charged twice.", questions: questions)

    assert_equal "I was charged twice.", JSON.parse(transport.calls.first[:body])["input"]
  end

  def test_noul_with_criteria_becomes_a_boolean_choice_and_reads_back_as_a_noul
    body = JSON.generate(
      "model" => "gpt-6-luna",
      "answers" => [{ "type" => "choice", "name" => "urgent", "choice" => true, "confidence" => 0.8,
                      "probabilities" => [{ "value" => true, "probability" => 0.85 },
                                          { "value" => false, "probability" => 0.15 }] }],
      "usage" => { "input_tokens" => 1, "output_tokens" => 0 }
    )
    transport = FakeTransport.new([[200, body, {}]])
    question = Q.noul("Is this urgent?", criteria: { true => "Explicitly time-sensitive", "false" => "No urgency" })

    response = client(transport).ask(state: "x", questions: { "urgent" => question })

    sent = JSON.parse(transport.calls.first[:body])["questions"].first
    assert_equal "choice", sent["type"]
    assert_equal [{ "value" => true, "description" => "Explicitly time-sensitive" },
                  { "value" => false, "description" => "No urgency" }], sent["choices"]

    assert_instance_of RubyDecisionModel::Answers::Noul, response["urgent"]
    assert_in_delta 0.85, response["urgent"].noul
  end

  def test_response_is_rebuilt_keyed_by_question_id
    transport = FakeTransport.new([[200, success_body, { "x-request-id" => "req_abc" }]])
    response = client(transport).ask(state: "x", questions: questions)

    assert_in_delta 0.92, response["urgent"].noul
    assert_equal({ "true" => 0.92, "false" => 0.08 }, response["urgent"].probabilities.transform_values { _1.round(2) })

    department = response["department"]
    assert_equal "billing", department.choice
    assert_in_delta 0.93, department.confidence
    assert_equal({ "billing" => 0.95, "other" => 0.05 }, department.probabilities)

    severity = response["severity"]
    assert_in_delta 1.1, severity.score
    assert_equal({ "0" => 0.1, "1" => 0.7, "2" => 0.2 }, severity.probabilities)
    assert_equal({ "0" => "Cosmetic", "1" => "Workaround", "2" => "Blocked" }, severity.legend)

    assert_equal "gpt-6-luna", response.model
    assert_nil response.id
    assert_equal "req_abc", response.request_id
    assert_equal 40, response.usage.input_tokens
    assert_equal 0, response.usage.output_tokens
    assert_nil response.usage.cost
    assert_kind_of Array, response.raw["answers"]
  end

  def test_symbol_question_ids
    transport = FakeTransport.new([[200, success_body, {}]])
    response = client(transport).ask(state: "x", questions: questions.transform_keys(&:to_sym))

    assert_equal "billing", response["department"].choice
    assert_equal "urgent", JSON.parse(transport.calls.first[:body])["questions"].first["name"]
  end

  def test_refusal_raises_missing_answers_naming_the_refused_question
    body = JSON.generate(
      "model" => "gpt-6-luna",
      "answers" => [{ "type" => "predicate", "name" => "urgent", "probability" => 0.4 },
                    { "type" => "refusal", "name" => "department" }],
      "usage" => { "input_tokens" => 1, "output_tokens" => 0 }
    )
    transport = FakeTransport.new([[200, body, {}]])
    asked = questions.slice("urgent", "department")

    error = assert_raises(RubyDecisionModel::MissingAnswers) { client(transport).ask(state: "x", questions: asked) }
    assert_equal ["department"], error.missing
    assert_equal ["department"], error.refused
    assert_includes error.message, "refused: department"
    assert_in_delta 0.4, error.answers["urgent"].noul
  end

  def test_unnamed_answers_match_questions_by_position
    body = JSON.generate(
      "model" => "gpt-6-luna",
      "answers" => [{ "type" => "predicate", "name" => nil, "probability" => 0.3 }],
      "usage" => {}
    )
    transport = FakeTransport.new([[200, body, {}]])

    response = client(transport).ask(state: "x", questions: questions.slice("urgent"))
    assert_in_delta 0.3, response["urgent"].noul
  end

  def test_answers_without_name_keys_map_back_by_position_and_strays_are_ignored
    body = JSON.generate(
      "model" => "gpt-6-luna",
      "answers" => [
        { "type" => "predicate", "probability" => 0.6 },
        { "type" => "choice", "choice" => "billing", "confidence" => 0.9,
          "probabilities" => [{ "value" => "billing", "probability" => 0.9 }, { "value" => "other", "probability" => 0.1 }] },
        { "type" => "score", "score" => 1.0, "confidence" => 0.5,
          "probabilities" => [{ "value" => 1, "label" => "Workaround", "probability" => 1.0 }] },
        "not an answer",
        { "type" => "mystery", "name" => "unasked", "value" => 1 }
      ],
      "usage" => {}
    )

    response = client(FakeTransport.new([[200, body, {}]])).ask(state: "x", questions: questions)

    assert_in_delta 0.6, response["urgent"].noul
    assert_equal "billing", response["department"].choice
    assert_equal({ "1" => "Workaround" }, response["severity"].legend)
    assert_equal %w[department severity urgent], response.answers.keys.sort
  end

  def test_an_unnamed_answer_never_lands_on_an_id_another_answer_names
    body = JSON.generate(
      "model" => "gpt-6-luna",
      "answers" => [{ "type" => "predicate", "name" => "department", "probability" => 0.9 },
                    { "type" => "predicate", "probability" => 0.1 },
                    { "type" => "predicate", "name" => "urgent", "probability" => 0.5 }],
      "usage" => {}
    )
    asked = { "urgent" => Q.noul("Urgent?"), "department" => Q.noul("Billing?") }

    response = client(FakeTransport.new([[200, body, {}]])).ask(state: "x", questions: asked)

    assert_in_delta 0.5, response["urgent"].noul
    assert_in_delta 0.9, response["department"].noul
  end

  def test_an_id_answered_twice_is_malformed_not_overwritten
    body = JSON.generate(
      "model" => "gpt-6-luna",
      "answers" => [{ "type" => "refusal", "name" => "urgent" },
                    { "type" => "predicate", "name" => "urgent", "probability" => 0.99 }],
      "usage" => {}
    )

    error = assert_raises(RubyDecisionModel::InvalidResponse) do
      client(FakeTransport.new([[200, body, {}]])).ask(state: "x", questions: questions.slice("urgent"))
    end
    refute_kind_of RubyDecisionModel::MissingAnswers, error
    assert_includes error.message, "urgent"
  end

  def test_duplicate_probability_values_are_malformed
    duplicate_true = { "type" => "choice", "name" => "urgent", "choice" => true, "confidence" => 0.5,
                       "probabilities" => [{ "value" => true, "probability" => 0.1 },
                                           { "value" => true, "probability" => 0.9 },
                                           { "value" => false, "probability" => 0.0 }] }
    duplicate_choice = { "type" => "choice", "name" => "department", "choice" => "billing", "confidence" => 0.5,
                         "probabilities" => [{ "value" => "billing", "probability" => 0.2 },
                                             { "value" => "billing", "probability" => 0.8 }] }
    mixed_types = { "type" => "score", "name" => "severity", "score" => 1.0, "confidence" => 0.5,
                    "probabilities" => [{ "value" => 1, "label" => "Workaround", "probability" => 0.9 },
                                        { "value" => "1", "label" => "Workaround", "probability" => 0.1 }] }
    {
      "urgent" => [duplicate_true, Q.noul("Urgent?", criteria: { "true" => "yes", "false" => "no" })],
      "department" => [duplicate_choice, questions["department"]],
      "severity" => [mixed_types, questions["severity"]]
    }.each do |id, (answer, question)|
      body = JSON.generate("model" => "gpt-6-luna", "answers" => [answer], "usage" => {})
      error = assert_raises(RubyDecisionModel::InvalidResponse, id) do
        client(FakeTransport.new([[200, body, {}]])).ask(state: "x", questions: { id => question })
      end
      refute_kind_of RubyDecisionModel::MissingAnswers, error, id
    end
  end

  def test_state_that_cannot_be_encoded_raises_request_error
    transport = FakeTransport.new([[200, success_body, {}]])

    error = assert_raises(RubyDecisionModel::RequestError) do
      client(transport).ask(state: { score: Float::NAN }, questions: questions)
    end
    assert_kind_of JSON::GeneratorError, error.cause
    assert_empty transport.calls
  end

  def test_images_become_input_image_parts
    transport = FakeTransport.new([[200, success_body, {}]])
    image = RubyDecisionModel::Images.data_url("\x89PNG".b, content_type: "image/png")

    client(transport).ask(state: "Inspect the photo.", questions: questions, images: [image])

    input = JSON.parse(transport.calls.first[:body])["input"]
    assert_equal(
      [{ "role" => "user", "content" => [{ "type" => "input_text", "text" => "Inspect the photo." },
                                         { "type" => "input_image", "image_url" => image }] }],
      input
    )
  end

  def test_images_without_state_send_only_image_parts
    transport = FakeTransport.new([[200, success_body, {}]])
    image = RubyDecisionModel::Images.data_url("GIF89a".b, content_type: "image/gif")

    client(transport).ask(state: nil, questions: questions, images: [image])

    content = JSON.parse(transport.calls.first[:body])["input"].first["content"]
    assert_equal ["input_image"], content.map { _1["type"] }
  end

  def test_question_without_instructions_raises_before_sending
    transport = FakeTransport.new([[200, success_body, {}]])

    error = assert_raises(RubyDecisionModel::RequestError) do
      client(transport).ask(state: "x", questions: { "urgent" => { "type" => "noul" } })
    end
    assert_includes error.message, "urgent"
    assert_empty transport.calls
  end

  # Value: protects=boolean choice values and out-of-range score indexes decode to usable strings/labels
  # Value: fails_when=decode_choice stops stringifying true/false or decode_score indexes criteria out of range
  # Value: why_new=existing tests only cover string choices and in-range score indexes
  # Value: seam=none
  def test_boolean_choice_values_are_stringified_and_out_of_range_score_index_uses_the_echoed_label
    body = JSON.generate(
      "model" => "gpt-6-luna",
      "answers" => [
        { "type" => "choice", "name" => "flag", "choice" => true, "confidence" => 0.7,
          "probabilities" => [{ "value" => true, "probability" => 0.7 }, { "value" => false, "probability" => 0.3 }] },
        { "type" => "score", "name" => "severity", "score" => 4.0, "confidence" => 0.5,
          "probabilities" => [{ "value" => 4, "label" => "Catastrophic", "probability" => 1.0 }] }
      ]
    )
    qs = { "flag" => Q.choice("Flag?", criteria: { "true" => nil, "false" => nil }),
           "severity" => Q.score("How severe?", criteria: %w[Low High]) }
    response = client(FakeTransport.new([[200, body, {}]])).ask(state: "x", questions: qs)

    assert_equal "true", response["flag"].choice
    assert_equal({ "true" => 0.7, "false" => 0.3 }, response["flag"].probabilities)
    assert_equal({ "4" => "Catastrophic" }, response["severity"].legend)
  end

  # Value: protects=non-string instructions are sent as JSON text so the API accepts them
  # Value: fails_when=encode_question forwards a Hash instructions value unchanged
  # Value: why_new=every existing test uses string instructions
  # Value: seam=none
  def test_non_string_instructions_are_sent_as_json_text
    transport = FakeTransport.new([[200, success_body, {}]])
    qs = { "urgent" => { type: "noul", instructions: { "ask" => "Is this urgent?" } } }
    response = client(transport).ask(state: "x", questions: qs)

    assert_in_delta 0.92, response["urgent"].noul
    sent = JSON.parse(transport.calls.first[:body])["questions"].first
    assert_equal "predicate", sent["type"]
    assert_equal '{"ask":"Is this urgent?"}', sent["instructions"]
  end

  def test_malformed_predicate_or_boolean_choice_raises_invalid_response
    {
      "predicate without probability" => { "type" => "predicate", "name" => "urgent" },
      "boolean choice without a true entry" => { "type" => "choice", "name" => "urgent", "choice" => false,
                                                 "confidence" => 1.0,
                                                 "probabilities" => [{ "value" => false, "probability" => 1.0 }] }
    }.each do |label, answer|
      body = JSON.generate("model" => "gpt-6-luna", "answers" => [answer], "usage" => {})
      question = label.start_with?("boolean") ? Q.noul("Urgent?", criteria: { "true" => "yes", "false" => "no" }) : Q.noul("Urgent?")

      error = assert_raises(RubyDecisionModel::InvalidResponse, label) do
        client(FakeTransport.new([[200, body, {}]])).ask(state: "x", questions: { "urgent" => question })
      end
      refute_kind_of RubyDecisionModel::MissingAnswers, error, label
      assert_includes error.message, "urgent", label
    end
  end

  def test_score_levels_with_label_and_description
    transport = FakeTransport.new([[200, success_body, {}]])
    levels = [{ label: "Cosmetic", description: "Appearance only" }, { "label" => "Blocked" }]

    client(transport).ask(state: "x", questions: { "severity" => Q.score("How severe?", criteria: levels) })

    sent = JSON.parse(transport.calls.first[:body])["questions"].first["levels"]
    assert_equal [{ "label" => "Cosmetic", "description" => "Appearance only" }, { "label" => "Blocked" }], sent
  end
end
