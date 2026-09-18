# frozen_string_literal: true

require "test_helper"

# Requests are billed by input tokens, so a question the API is going to
# refuse should never leave the process.
class QuestionValidationTest < Minitest::Test
  def setup
    @transport = FakeTransport.new([[200, success_body]])
    @client = RubyDecisionModel::Client.new(api_key: "test-key", transport: @transport, sleeper: no_sleep)
  end

  def success_body
    JSON.generate(
      "answers" => { "q" => { "type" => "noul", "noul" => 0.5 } },
      "usage" => { "input_tokens" => 1, "output_tokens" => 1 }
    )
  end

  def refuse(questions)
    error = assert_raises(RubyDecisionModel::RequestError) { @client.ask(state: {}, questions: questions) }
    assert_empty @transport.calls, "the request should not have been sent"
    error
  end

  # --- the map itself ---

  def test_empty_and_nil_question_maps_are_refused
    refuse({})
    refuse(nil)
  end

  def test_a_questions_argument_that_is_not_a_hash_is_refused
    error = refuse([RubyDecisionModel::Questions.noul("Is this urgent?")])
    assert_match(/must be a Hash/, error.message)
  end

  def test_a_blank_question_id_is_refused
    error = refuse({ "  " => RubyDecisionModel::Questions.noul("Is this urgent?") })
    assert_match(/is blank/, error.message)
  end

  def test_ids_that_collide_once_stringified_are_refused
    # Both arrive as "a" on the wire, so one answer would come back for two
    # questions and the other would look like it went missing.
    error = refuse({ :a => RubyDecisionModel::Questions.noul("First?"),
                     "a" => RubyDecisionModel::Questions.noul("Second?") })
    assert_match(/both "a" on the wire/, error.message)
  end

  def test_symbol_ids_on_their_own_are_fine
    response = @client.ask(state: {}, questions: { q: RubyDecisionModel::Questions.noul("Is this urgent?") })
    assert_in_delta 0.5, response["q"].noul
  end

  # --- each question ---

  def test_a_question_that_is_not_a_hash_is_refused
    error = refuse({ "q" => "is this urgent?" })
    assert_match(/must be a Hash/, error.message)
    assert_match(/"q"/, error.message)
  end

  def test_an_unknown_type_is_refused
    error = refuse({ "q" => { "type" => "ranking", "instructions" => "Rank these" } })
    assert_match(/expected one of noul, choice, score/, error.message)
  end

  def test_a_missing_type_is_refused
    refuse({ "q" => { "instructions" => "Is this urgent?" } })
  end

  def test_missing_instructions_are_refused
    error = refuse({ "q" => { "type" => "noul" } })
    assert_match(/missing instructions/, error.message)
  end

  def test_empty_instructions_are_refused
    refuse({ "q" => { "type" => "noul", "instructions" => "" } })
    refuse({ "q" => { "type" => "noul", "instructions" => [] } })
  end

  def test_instructions_of_the_wrong_type_are_refused
    error = refuse({ "q" => { "type" => "noul", "instructions" => 42 } })
    assert_match(/instructions of type Integer/, error.message)
  end

  def test_nil_instructions_are_allowed
    # EntryType in the official SDKs covers null for state, instructions, and
    # criteria alike.
    response = @client.ask(state: {}, questions: { "q" => { "type" => "noul", "instructions" => nil } })
    assert_in_delta 0.5, response["q"].noul
  end

  # --- criteria each type requires ---

  def test_a_choice_question_without_criteria_is_refused
    error = refuse({ "q" => { "type" => "choice", "instructions" => "Which team?" } })
    assert_match(/needs criteria/, error.message)
  end

  def test_a_choice_question_with_too_many_options_is_refused
    criteria = (1..256).to_h { |i| [i.to_s, nil] }
    refuse({ "q" => { "type" => "choice", "instructions" => "Which?", "criteria" => criteria } })
  end

  def test_a_score_question_with_one_level_is_refused
    refuse({ "q" => { "type" => "score", "instructions" => "How bad?", "criteria" => ["only one"] } })
  end

  def test_a_score_question_with_eleven_levels_is_refused
    refuse({ "q" => { "type" => "score", "instructions" => "How bad?", "criteria" => (1..11).map(&:to_s) } })
  end

  def test_a_noul_question_needs_no_criteria
    response = @client.ask(state: {}, questions: { "q" => { "type" => "noul", "instructions" => "Urgent?" } })
    assert_in_delta 0.5, response["q"].noul
  end

  def test_symbol_keyed_question_hashes_are_accepted
    response = @client.ask(state: {}, questions: { "q" => { type: "noul", instructions: "Urgent?" } })
    assert_in_delta 0.5, response["q"].noul
  end

  def test_questions_from_the_builders_pass
    transport = FakeTransport.new([[200, JSON.generate(
      "answers" => {
        "a" => { "type" => "noul", "noul" => 0.5 },
        "b" => { "type" => "choice", "choice" => "x", "confidence" => 0.5, "probabilities" => {} },
        "c" => { "type" => "score", "score" => 1.0, "confidence" => 0.5, "probabilities" => {}, "legend" => {} }
      },
      "usage" => {}
    )]])
    client = RubyDecisionModel::Client.new(api_key: "k", transport: transport, sleeper: no_sleep)

    response = client.ask(state: {}, questions: {
                            "a" => RubyDecisionModel::Questions.noul("Urgent?"),
                            "b" => RubyDecisionModel::Questions.choice("Which?", criteria: { "x" => nil }),
                            "c" => RubyDecisionModel::Questions.score("How bad?", criteria: %w[low high])
                          })

    assert_equal 3, response.answers.size
  end

  # --- the validator on its own ---

  def test_validate_is_callable_directly
    assert_nil RubyDecisionModel::Questions.validate!(
      RubyDecisionModel::Questions.noul("Urgent?"), id: "q"
    )
    assert_raises(RubyDecisionModel::RequestError) do
      RubyDecisionModel::Questions.validate!({ "type" => "noul" }, id: "q")
    end
  end
end
