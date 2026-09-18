# frozen_string_literal: true

require "test_helper"

# What the client will and will not accept as an answer, per provider.
class AnswersTest < Minitest::Test
  def noul_question
    { "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?") }
  end

  def choice_question
    { "dept" => RubyDecisionModel::Questions.choice("Which team?", criteria: { "billing" => nil, "auth" => nil }) }
  end

  def score_question
    { "sev" => RubyDecisionModel::Questions.score("How bad?", criteria: %w[low medium high]) }
  end

  def body(answers)
    JSON.generate("model" => "jev-latest", "answers" => answers, "usage" => {})
  end

  def client_for(provider, answers)
    RubyDecisionModel::Client.new(
      provider: provider, api_key: "k", sleeper: no_sleep,
      transport: FakeTransport.new([[200, body(answers)]])
    )
  end

  def ask(provider, questions, answers)
    client_for(provider, answers).ask(state: {}, questions: questions)
  end

  def refute_accepted(provider, questions, answers, matching)
    error = assert_raises(RubyDecisionModel::InvalidResponse) { ask(provider, questions, answers) }
    assert_match matching, error.message
    error
  end

  # --- fields Typesafe documents as required are required ---

  def test_typesafe_choice_without_probabilities_is_rejected
    refute_accepted(:typesafe, choice_question,
                    { "dept" => { "type" => "choice", "choice" => "billing", "confidence" => 0.9 } },
                    /probabilities is missing/)
  end

  def test_typesafe_choice_without_confidence_is_rejected
    refute_accepted(:typesafe, choice_question,
                    { "dept" => { "type" => "choice", "choice" => "billing", "probabilities" => { "billing" => 1.0 } } },
                    /confidence is missing/)
  end

  def test_typesafe_score_without_legend_is_rejected
    refute_accepted(:typesafe, score_question,
                    { "sev" => { "type" => "score", "score" => 1.0, "confidence" => 0.5,
                                 "probabilities" => { "0" => 1.0 } } },
                    /legend is missing/)
  end

  def test_the_error_names_the_question_and_the_field
    error = refute_accepted(:typesafe, choice_question,
                            { "dept" => { "type" => "choice", "choice" => "billing" } },
                            /dept/)
    assert_match(/confidence is missing/, error.message)
  end

  def test_a_typesafe_answer_with_every_documented_field_is_accepted
    response = ask(:typesafe, score_question,
                   { "sev" => { "type" => "score", "score" => 1.6, "confidence" => 0.78,
                                "probabilities" => { "0" => 0.05, "1" => 0.3, "2" => 0.65 },
                                "legend" => { "0" => "low", "1" => "medium", "2" => "high" } } })

    answer = response["sev"]
    assert_in_delta 1.6, answer.score
    assert_in_delta 0.78, answer.confidence
    assert_equal 3, answer.legend.size
  end

  # --- OpenRouter's schema makes the same fields optional ---

  def test_open_router_choice_without_probabilities_or_confidence_is_accepted
    answer = ask(:open_router, choice_question,
                 { "dept" => { "type" => "choice", "choice" => "billing" } })["dept"]

    assert_equal "billing", answer.choice
    assert_nil answer.confidence
    assert_empty answer.probabilities
  end

  def test_open_router_still_requires_the_answer_itself
    refute_accepted(:open_router, choice_question, { "dept" => { "type" => "choice" } }, /choice is missing/)
    refute_accepted(:open_router, noul_question, { "urgent" => { "type" => "noul" } }, /noul is missing/)
  end

  # --- numbers have to be numbers that exist ---

  def test_an_infinite_noul_is_rejected
    # JSON.parse turns 1e999 into Float::INFINITY, which passes is_a?(Numeric).
    infinite = '{"model":"m","answers":{"urgent":{"type":"noul","noul":1e999}},"usage":{}}'
    client = RubyDecisionModel::Client.new(provider: :typesafe, api_key: "k", sleeper: no_sleep,
                                           transport: FakeTransport.new([[200, infinite]]))

    error = nil
    capture_io do # JSON warns "Float 1e999 out of range" on the way past
      error = assert_raises(RubyDecisionModel::InvalidResponse) { client.ask(state: {}, questions: noul_question) }
    end
    assert_match(/noul is not finite/, error.message)
  end

  def test_a_noul_outside_zero_to_one_is_rejected
    refute_accepted(:typesafe, noul_question, { "urgent" => { "type" => "noul", "noul" => 2 } },
                    /noul is outside 0\.\.1/)
    refute_accepted(:typesafe, noul_question, { "urgent" => { "type" => "noul", "noul" => -0.5 } },
                    /noul is outside 0\.\.1/)
  end

  def test_a_confidence_outside_zero_to_one_is_rejected
    refute_accepted(:open_router, choice_question,
                    { "dept" => { "type" => "choice", "choice" => "billing", "confidence" => 1.4 } },
                    /confidence is outside 0\.\.1/)
  end

  def test_float_slop_just_past_one_is_tolerated_and_clamped
    answer = ask(:open_router, noul_question,
                 { "urgent" => { "type" => "noul", "noul" => 1.0000000001 } })["urgent"]

    assert_in_delta 1.0, answer.noul
    assert_operator answer.noul, :<=, 1.0
  end

  def test_a_probability_that_is_not_a_number_is_rejected
    refute_accepted(:open_router, choice_question,
                    { "dept" => { "type" => "choice", "choice" => "billing",
                                  "probabilities" => { "billing" => "high" } } },
                    /probabilities\["billing"\] is not a number/)
  end

  def test_probabilities_that_are_not_an_object_are_rejected_rather_than_erased
    refute_accepted(:open_router, choice_question,
                    { "dept" => { "type" => "choice", "choice" => "billing", "probabilities" => [0.9, 0.1] } },
                    /probabilities is not an object/)
  end

  def test_a_legend_that_is_not_an_object_is_rejected_rather_than_erased
    refute_accepted(:open_router, score_question,
                    { "sev" => { "type" => "score", "score" => 1.0, "legend" => "low, medium, high" } },
                    /legend is not an object/)
  end

  # --- a choice has to be one the question offered ---

  def test_a_choice_outside_the_questions_criteria_is_rejected
    error = refute_accepted(:open_router, choice_question,
                            { "dept" => { "type" => "choice", "choice" => "marketing" } },
                            /not one of the question's criteria/)
    assert_match(/billing, auth/, error.message)
  end

  def test_an_empty_choice_is_rejected
    refute_accepted(:open_router, choice_question, { "dept" => { "type" => "choice", "choice" => "" } },
                    /choice is empty/)
  end

  def test_a_choice_is_not_checked_when_the_question_carries_no_criteria_map
    # A hand-rolled question that bypassed Questions.choice has nothing to
    # check against, so the label is taken as given.
    answer = ask(:open_router, { "dept" => { "type" => "choice", "instructions" => "Which team?" } },
                 { "dept" => { "type" => "choice", "choice" => "anything" } })["dept"]

    assert_equal "anything", answer.choice
  end

  def test_symbol_keyed_criteria_still_match
    questions = { "dept" => { type: "choice", instructions: "Which?", criteria: { billing: nil } } }
    answer = ask(:open_router, questions, { "dept" => { "type" => "choice", "choice" => "billing" } })["dept"]

    assert_equal "billing", answer.choice
  end

  def test_a_noul_probabilities_map_is_read_when_a_provider_sends_one
    answer = ask(:open_router, noul_question,
                 { "urgent" => { "type" => "noul", "noul" => 0.8,
                                 "probabilities" => { "true" => 0.8, "false" => 0.2 } } })["urgent"]

    assert_in_delta 0.8, answer.probabilities["true"]
  end

  # --- a provider can declare its own contract ---

  def custom_provider(required)
    Class.new(RubyDecisionModel::Providers::Base) do
      define_method(:required_answer_fields) { required }
      def name = :strict
      def env_var = "STRICT_API_KEY"
      def default_base_url = "https://strict.example"
      def endpoint_path = "/v1/decide"
      def default_model = "strict-1"
    end
  end

  def test_a_custom_provider_declares_which_fields_it_guarantees
    provider = custom_provider("choice" => %w[choice probabilities]).new(api_key: "k")
    client = RubyDecisionModel::Client.new(
      provider: provider, sleeper: no_sleep,
      transport: FakeTransport.new([[200, body("dept" => { "type" => "choice", "choice" => "billing" })]])
    )

    error = assert_raises(RubyDecisionModel::InvalidResponse) { client.ask(state: {}, questions: choice_question) }
    assert_match(/probabilities is missing/, error.message)
  end

  def test_a_provider_requiring_a_field_the_client_does_not_model_is_rejected
    error = assert_raises(RubyDecisionModel::ConfigurationError) do
      RubyDecisionModel::Client.new(provider: custom_provider("noul" => %w[noul legend]).new(api_key: "k"),
                                    transport: FakeTransport.new([]))
    end
    assert_match(/does not model: legend on noul/, error.message)
  end

  def test_a_provider_requiring_an_unknown_answer_type_is_rejected
    error = assert_raises(RubyDecisionModel::ConfigurationError) do
      RubyDecisionModel::Client.new(provider: custom_provider("ranking" => %w[order]).new(api_key: "k"),
                                    transport: FakeTransport.new([]))
    end
    assert_match(/unknown answer type/, error.message)
  end
end
