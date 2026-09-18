# frozen_string_literal: true

require "test_helper"
require "socket"

# A one-shot HTTP server that answers on loopback, so the default Net::HTTP
# transport is exercised for real rather than stubbed.
class TinyServer
  attr_reader :port, :bytes_written

  def initialize(&responder)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @responder = responder
    @bytes_written = 0
    @thread = Thread.new { serve }
  end

  def close
    @thread.kill
    @server.close
  rescue IOError
    nil
  end

  private

  def serve
    loop do
      socket = @server.accept
      read_request(socket)
      @responder.call(socket, self)
      socket.close
    rescue StandardError
      nil
    end
  end

  def read_request(socket)
    length = 0
    while (line = socket.gets)
      break if line == "\r\n"

      length = Regexp.last_match(1).to_i if line =~ /\AContent-Length:\s*(\d+)/i
    end
    socket.read(length) if length.positive?
  end

  public

  def write(socket, data)
    socket.write(data)
    @bytes_written += data.bytesize
  end
end

class ResponseSizeTest < Minitest::Test
  def questions
    { "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?") }
  end

  def success_body
    JSON.generate(
      "answers" => { "urgent" => { "type" => "noul", "noul" => 0.5 } },
      "usage" => { "input_tokens" => 1, "output_tokens" => 1 }
    )
  end

  def build_client(transport, **options)
    RubyDecisionModel::Client.new(
      **{ api_key: "test-key", transport: transport, sleeper: no_sleep }.merge(options)
    )
  end

  # --- configuration ---

  def test_default_limit_is_ten_mebibytes
    assert_equal 10 * 1024 * 1024, build_client(FakeTransport.new([])).max_response_bytes
  end

  def test_limit_must_be_nil_or_a_positive_integer
    [0, -1, 1.5, "10"].each do |bad|
      assert_raises(RubyDecisionModel::ConfigurationError, "expected #{bad.inspect} to be rejected") do
        build_client(FakeTransport.new([]), max_response_bytes: bad)
      end
    end
    assert_nil build_client(FakeTransport.new([]), max_response_bytes: nil).max_response_bytes
  end

  # --- custom transports are checked too ---

  def test_an_oversized_body_from_a_custom_transport_is_rejected_before_parsing
    transport = FakeTransport.new([[200, "x" * 100]])
    client = build_client(transport, max_response_bytes: 50)

    error = assert_raises(RubyDecisionModel::ResponseTooLarge) { client.ask(state: {}, questions: questions) }

    assert_equal 100, error.bytes
    assert_equal 50, error.limit
  end

  def test_an_oversized_error_body_is_rejected_too
    # A 500 body is retained on the exception, so it needs the same ceiling.
    transport = FakeTransport.new([[500, "x" * 100]])
    client = build_client(transport, max_response_bytes: 50, retry: { max_retries: 0 })

    assert_raises(RubyDecisionModel::ResponseTooLarge) { client.ask(state: {}, questions: questions) }
  end

  def test_an_oversized_response_is_not_retried
    transport = FakeTransport.new([[200, "x" * 100]])
    client = build_client(transport, max_response_bytes: 50)

    assert_raises(RubyDecisionModel::ResponseTooLarge) { client.ask(state: {}, questions: questions) }
    assert_equal 1, transport.calls.length
  end

  def test_a_body_at_the_limit_is_accepted
    body = success_body
    transport = FakeTransport.new([[200, body]])
    client = build_client(transport, max_response_bytes: body.bytesize)

    assert_in_delta 0.5, client.ask(state: {}, questions: questions)["urgent"].noul
  end

  def test_a_nil_limit_disables_the_check
    transport = FakeTransport.new([[200, success_body]])
    client = build_client(transport, max_response_bytes: nil)

    assert_in_delta 0.5, client.ask(state: {}, questions: questions)["urgent"].noul
  end

  # --- the default transport stops reading rather than buffering it all ---

  def test_the_default_transport_stops_reading_an_oversized_chunked_body
    # No Content-Length: the only way to know the size is to read it, which is
    # the case the cap has to handle by stopping mid-stream.
    server = TinyServer.new do |socket, srv|
      srv.write(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                        "Transfer-Encoding: chunked\r\n\r\n")
      600.times { srv.write(socket, "400\r\n#{'x' * 1024}\r\n") }
      srv.write(socket, "0\r\n\r\n")
    end

    client = RubyDecisionModel::Client.new(
      api_key: "k", base_url: "http://127.0.0.1:#{server.port}", max_response_bytes: 64 * 1024,
      sleeper: no_sleep, retry: { max_retries: 0 }
    )

    error = assert_raises(RubyDecisionModel::ResponseTooLarge) { client.ask(state: {}, questions: questions) }

    assert_operator error.bytes, :>, 64 * 1024
    # 600 KiB was on offer; the client gave up long before it had all of it.
    assert_operator server.bytes_written, :<, 600 * 1024
  ensure
    server&.close
  end

  def test_the_default_transport_rejects_an_oversized_content_length_before_reading
    server = TinyServer.new do |socket, srv|
      srv.write(socket, "HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n")
      srv.write(socket, "x" * 1024)
    end

    client = RubyDecisionModel::Client.new(
      api_key: "k", base_url: "http://127.0.0.1:#{server.port}", max_response_bytes: 1024,
      sleeper: no_sleep, retry: { max_retries: 0 }
    )

    error = assert_raises(RubyDecisionModel::ResponseTooLarge) { client.ask(state: {}, questions: questions) }

    assert_equal 1_048_576, error.bytes
  ensure
    server&.close
  end

  def test_the_default_transport_returns_a_body_within_the_limit
    body = success_body
    server = TinyServer.new do |socket, srv|
      srv.write(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                        "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
    end

    client = RubyDecisionModel::Client.new(
      api_key: "k", base_url: "http://127.0.0.1:#{server.port}", sleeper: no_sleep
    )

    response = client.ask(state: {}, questions: questions)

    assert_in_delta 0.5, response["urgent"].noul
  ensure
    server&.close
  end
end
