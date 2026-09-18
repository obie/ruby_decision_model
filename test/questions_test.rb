# frozen_string_literal: true

require "test_helper"

class QuestionsTest < Minitest::Test
  def test_noul_builds_minimal_question
    question = RubyDecisionModel::Questions.noul("Is this urgent?")
    assert_equal({ "type" => "noul", "instructions" => "Is this urgent?" }, question)
  end

  def test_noul_includes_criteria_when_given
    question = RubyDecisionModel::Questions.noul("Is this urgent?", criteria: { "true" => "yes", "false" => "no" })
    assert_equal({ "true" => "yes", "false" => "no" }, question["criteria"])
  end

  def test_noul_rejects_empty_instructions
    assert_raises(ArgumentError) { RubyDecisionModel::Questions.noul("") }
  end

  def test_noul_rejects_invalid_instructions_type
    assert_raises(ArgumentError) { RubyDecisionModel::Questions.noul(42) }
  end

  def test_choice_builds_question_and_stringifies_keys
    question = RubyDecisionModel::Questions.choice("Pick one", criteria: { low: "low option", high: nil })
    assert_equal "choice", question["type"]
    assert_equal({ "low" => "low option", "high" => nil }, question["criteria"])
  end

  def test_choice_rejects_empty_criteria
    assert_raises(ArgumentError) { RubyDecisionModel::Questions.choice("Pick one", criteria: {}) }
  end

  def test_choice_rejects_too_many_criteria
    criteria = (1..256).each_with_object({}) { |i, h| h[i.to_s] = "opt" }
    assert_raises(ArgumentError) { RubyDecisionModel::Questions.choice("Pick one", criteria: criteria) }
  end

  def test_score_builds_question
    question = RubyDecisionModel::Questions.score("Rate severity", criteria: %w[low high])
    assert_equal "score", question["type"]
    assert_equal %w[low high], question["criteria"]
  end

  def test_score_rejects_too_few_levels
    assert_raises(ArgumentError) { RubyDecisionModel::Questions.score("Rate severity", criteria: ["only one"]) }
  end

  def test_score_accepts_ten_levels
    question = RubyDecisionModel::Questions.score("Rate severity", criteria: (1..10).map(&:to_s))
    assert_equal 10, question["criteria"].length
  end

  def test_choice_accepts_255_options
    criteria = (1..255).each_with_object({}) { |i, h| h[i.to_s] = nil }
    question = RubyDecisionModel::Questions.choice("Pick one", criteria: criteria)
    assert_equal 255, question["criteria"].length
  end

  # --- criteria contents, not just their container ---

  def test_noul_accepts_true_and_false_descriptions
    question = RubyDecisionModel::Questions.noul(
      "Has the customer contacted support before?",
      criteria: { true => "Mentions a prior ticket", false => "No sign of previous contact" }
    )

    assert_equal({ "true" => "Mentions a prior ticket", "false" => "No sign of previous contact" },
                 question["criteria"])
  end

  def test_noul_accepts_string_keys_too
    question = RubyDecisionModel::Questions.noul("Urgent?", criteria: { "true" => "yes means", "false" => nil })
    assert_equal({ "true" => "yes means", "false" => nil }, question["criteria"])
  end

  def test_noul_accepts_one_sided_criteria
    question = RubyDecisionModel::Questions.noul("Urgent?", criteria: { true => "time-sensitive" })
    assert_equal({ "true" => "time-sensitive" }, question["criteria"])
  end

  def test_noul_rejects_criteria_that_are_not_a_hash
    error = assert_raises(ArgumentError) { RubyDecisionModel::Questions.noul("Urgent?", criteria: %w[yes no]) }
    assert_match(/must be a Hash/, error.message)
  end

  def test_noul_rejects_keys_that_are_not_true_or_false
    error = assert_raises(ArgumentError) do
      RubyDecisionModel::Questions.noul("Urgent?", criteria: { "yes" => "means urgent" })
    end
    assert_match(/must be true and false/, error.message)
  end

  def test_noul_rejects_a_duplicate_outcome
    assert_raises(ArgumentError) do
      RubyDecisionModel::Questions.noul("Urgent?", criteria: { true => "a", "true" => "b" })
    end
  end

  def test_noul_rejects_a_description_that_is_not_text_or_structure
    assert_raises(ArgumentError) { RubyDecisionModel::Questions.noul("Urgent?", criteria: { true => 1 }) }
  end

  def test_noul_without_criteria_is_unchanged
    refute RubyDecisionModel::Questions.noul("Urgent?").key?("criteria")
  end

  def test_choice_rejects_labels_that_collide_once_stringified
    # Both become "billing" as a JSON key, so one option would silently
    # replace the other and the model would see a rubric nobody wrote.
    error = assert_raises(ArgumentError) do
      RubyDecisionModel::Questions.choice("Which team?", criteria: { :billing => "a", "billing" => "b" })
    end
    assert_match(/collide/, error.message)
  end

  def test_choice_rejects_a_blank_label
    assert_raises(ArgumentError) { RubyDecisionModel::Questions.choice("Which?", criteria: { "  " => "a" }) }
  end

  def test_choice_rejects_a_description_that_is_not_text_or_structure
    assert_raises(ArgumentError) { RubyDecisionModel::Questions.choice("Which?", criteria: { "a" => 3 }) }
  end

  def test_choice_accepts_structured_descriptions
    criteria = { "billing" => { "covers" => %w[refunds invoices] }, "auth" => nil }
    question = RubyDecisionModel::Questions.choice("Which team?", criteria: criteria)

    assert_equal criteria, question["criteria"]
  end

  def test_score_rejects_a_level_that_is_not_text_or_structure
    error = assert_raises(ArgumentError) { RubyDecisionModel::Questions.score("How bad?", criteria: ["low", 2]) }
    assert_match(/criteria\[1\]/, error.message)
  end

  def test_score_accepts_structured_levels
    criteria = [{ "label" => "calm" }, nil, "very angry"]
    assert_equal criteria, RubyDecisionModel::Questions.score("How frustrated?", criteria: criteria)["criteria"]
  end

  def test_score_rejects_too_many_levels
    assert_raises(ArgumentError) { RubyDecisionModel::Questions.score("Rate severity", criteria: (1..11).map(&:to_s)) }
  end
end
