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

  def test_score_rejects_too_many_levels
    assert_raises(ArgumentError) { RubyDecisionModel::Questions.score("Rate severity", criteria: (1..11).map(&:to_s)) }
  end
end
