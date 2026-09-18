# frozen_string_literal: true

require "test_helper"

class ResponseTest < Minitest::Test
  def questions
    {
      "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?"),
      "category" => RubyDecisionModel::Questions.choice("Pick a category", criteria: { "bug" => nil, "feature" => nil }),
      "severity" => RubyDecisionModel::Questions.score("Rate severity", criteria: %w[low medium high])
    }
  end

  def body
    JSON.generate(
      "id" => "resp_1",
      "model" => "jev-1.13",
      "answers" => {
        "urgent" => { "type" => "noul", "noul" => 0.82, "probabilities" => { "true" => 0.82, "false" => 0.18 } },
        "category" => { "type" => "choice", "choice" => "bug", "confidence" => 0.9,
                        "probabilities" => { "bug" => 0.9, "feature" => 0.1 } },
        "severity" => { "type" => "score", "score" => 1.4, "confidence" => 0.7,
                        "probabilities" => { "0" => 0.1, "1" => 0.6, "2" => 0.3 },
                        "legend" => { "0" => "low", "1" => "medium", "2" => "high" } }
      },
      "usage" => { "input_tokens" => 120, "output_tokens" => 30 }
    )
  end

  def ask(headers = {})
    transport = FakeTransport.new([[200, body, headers]])
    client = RubyDecisionModel::Client.new(provider: :typesafe, api_key: "k", transport: transport, sleeper: no_sleep)
    client.ask(state: {}, questions: questions)
  end

  def test_request_id_is_read_from_typesafe_header_case_insensitively
    assert_equal "req_abc", ask("X-Typesafe-Request-Id" => "req_abc").request_id
    assert_equal "req_def", ask("x-typesafe-request-id" => "req_def").request_id
  end

  def test_request_id_uses_first_value_when_header_is_an_array
    assert_equal "req_arr", ask("X-Typesafe-Request-Id" => %w[req_arr req_ignored]).request_id
  end

  def test_request_id_is_nil_when_header_absent
    assert_nil ask.request_id
  end

  def test_answers_filtered_by_type_keep_their_keys
    response = ask

    assert_equal ["urgent"], response.nouls.keys
    assert_equal ["category"], response.choices.keys
    assert_equal ["severity"], response.scores.keys
    assert_instance_of RubyDecisionModel::Answers::Score, response.scores["severity"]
  end

  def test_score_probabilities_and_legend_keep_wire_string_level_keys
    severity = ask.scores["severity"]

    assert_equal %w[0 1 2], severity.probabilities.keys
    assert_equal({ "0" => "low", "1" => "medium", "2" => "high" }, severity.legend)
  end

  def test_choice_probabilities_are_preserved_without_renormalizing
    category = ask.choices["category"]

    assert_in_delta 0.9, category.probabilities["bug"]
    assert_in_delta 0.1, category.probabilities["feature"]
  end
end
