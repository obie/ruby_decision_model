# frozen_string_literal: true

require "test_helper"

# One rescuable class per status the API documents.
class ErrorClassesTest < Minitest::Test
  def questions
    { "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?") }
  end

  def raise_for(status)
    client = RubyDecisionModel::Client.new(
      api_key: "test-key", sleeper: no_sleep, retry: { max_retries: 0 },
      transport: FakeTransport.new([[status, %({"error":"nope"}), { "x-thing" => "v" }]])
    )
    client.ask(state: {}, questions: questions)
  end

  def assert_status_raises(status, klass)
    error = assert_raises(klass) { raise_for(status) }
    assert_equal status, error.status
    assert_equal %({"error":"nope"}), error.body
    error
  end

  def test_documented_statuses_get_their_own_class
    {
      400 => RubyDecisionModel::BadRequest,
      401 => RubyDecisionModel::Unauthorized,
      403 => RubyDecisionModel::PermissionDenied,
      404 => RubyDecisionModel::NotFound,
      413 => RubyDecisionModel::PayloadTooLarge,
      422 => RubyDecisionModel::UnprocessableEntity,
      429 => RubyDecisionModel::RateLimited,
      529 => RubyDecisionModel::Overloaded
    }.each { |status, klass| assert_status_raises(status, klass) }
  end

  def test_any_other_five_hundred_is_a_server_error
    [500, 502, 503, 504, 599].each { |status| assert_status_raises(status, RubyDecisionModel::ServerError) }
  end

  def test_overloaded_is_a_server_error_too
    assert_status_raises(529, RubyDecisionModel::ServerError)
    # and is still rescuable on its own
    assert_status_raises(529, RubyDecisionModel::Overloaded)
  end

  def test_a_server_error_is_not_an_overloaded
    error = assert_raises(RubyDecisionModel::ServerError) { raise_for(503) }
    refute_kind_of RubyDecisionModel::Overloaded, error
  end

  def test_an_undocumented_status_falls_back_to_api_error
    error = assert_status_raises(418, RubyDecisionModel::ApiError)
    assert_match(/status 418/, error.message)
  end

  def test_every_error_is_an_api_error_and_carries_its_headers
    [400, 401, 403, 404, 413, 422, 429, 500, 529, 418].each do |status|
      error = assert_raises(RubyDecisionModel::ApiError) { raise_for(status) }
      assert_equal({ "x-thing" => "v" }, error.headers, "status #{status}")
    end
  end

  def test_messages_name_what_went_wrong
    assert_match(/bad request/, assert_raises(RubyDecisionModel::BadRequest) { raise_for(400) }.message)
    assert_match(/permission denied/, assert_raises(RubyDecisionModel::PermissionDenied) { raise_for(403) }.message)
    assert_match(/not found/, assert_raises(RubyDecisionModel::NotFound) { raise_for(404) }.message)
    assert_match(/status 503/, assert_raises(RubyDecisionModel::ServerError) { raise_for(503) }.message)
  end

  def test_a_two_hundred_is_still_parsed
    body = JSON.generate("answers" => { "urgent" => { "type" => "noul", "noul" => 0.5 } }, "usage" => {})
    client = RubyDecisionModel::Client.new(
      api_key: "test-key", sleeper: no_sleep, transport: FakeTransport.new([[204, body]])
    )

    # 204 is in 200..299 but carries a body here; the success path still runs.
    assert_in_delta 0.5, client.ask(state: {}, questions: questions)["urgent"].noul
  end
end
