# frozen_string_literal: true

require "test_helper"

# Requests are billed per input token, so a usage number is either a number
# or an error -- never a quietly coerced one.
class UsageTest < Minitest::Test
  def usage_for(raw, provider: :open_router)
    RubyDecisionModel::Providers.build(provider, api_key: "k").usage("usage" => raw)
  end

  def test_integers_pass_through
    usage = usage_for({ "input_tokens" => 120, "output_tokens" => 30, "cost" => 0.0012 })

    assert_equal 120, usage.input_tokens
    assert_equal 30, usage.output_tokens
    assert_in_delta 0.0012, usage.cost
  end

  def test_a_whole_float_is_accepted_as_a_count
    # JSON has one number type, so 120 may arrive as 120.0.
    assert_equal 120, usage_for({ "input_tokens" => 120.0 }).input_tokens
  end

  def test_a_fractional_token_count_is_rejected_rather_than_truncated
    error = assert_raises(RubyDecisionModel::InvalidResponse) { usage_for({ "output_tokens" => 30.9 }) }
    assert_match(/usage\.output_tokens is not a token count/, error.message)
  end

  def test_a_numeric_string_is_rejected
    # "120" used to become 120 and "120.5" used to become nil.
    assert_raises(RubyDecisionModel::InvalidResponse) { usage_for({ "input_tokens" => "120" }) }
    assert_raises(RubyDecisionModel::InvalidResponse) { usage_for({ "input_tokens" => "120.5" }) }
  end

  def test_structural_junk_is_rejected
    [[], {}, true, "junk"].each do |junk|
      assert_raises(RubyDecisionModel::InvalidResponse, "expected #{junk.inspect} to be rejected") do
        usage_for({ "input_tokens" => junk })
      end
    end
  end

  def test_an_infinite_count_is_rejected
    assert_raises(RubyDecisionModel::InvalidResponse) { usage_for({ "input_tokens" => Float::INFINITY }) }
  end

  def test_an_absent_field_is_nil
    usage = usage_for({ "input_tokens" => 10 })

    assert_equal 10, usage.input_tokens
    assert_nil usage.output_tokens
  end

  def test_an_explicitly_null_field_is_nil
    assert_nil usage_for({ "input_tokens" => nil }).input_tokens
  end

  def test_an_absent_usage_object_is_all_nil
    usage = RubyDecisionModel::Providers.build(:open_router, api_key: "k").usage({})

    assert_nil usage.input_tokens
    assert_nil usage.output_tokens
    assert_nil usage.cost
  end

  # --- cost ---

  def test_cost_is_nil_on_a_provider_that_does_not_report_it
    assert_nil usage_for({ "cost" => 0.5 }, provider: :typesafe).cost
  end

  def test_a_cost_that_is_not_a_number_is_rejected
    error = assert_raises(RubyDecisionModel::InvalidResponse) { usage_for({ "cost" => "junk" }) }
    assert_match(/usage\.cost is not a number/, error.message)
  end

  def test_an_integer_cost_becomes_a_float
    assert_in_delta 1.0, usage_for({ "cost" => 1 }).cost
  end

  def test_a_typesafe_provider_ignores_a_junk_cost_it_never_reports
    assert_nil usage_for({ "cost" => "junk" }, provider: :typesafe).cost
  end
end
