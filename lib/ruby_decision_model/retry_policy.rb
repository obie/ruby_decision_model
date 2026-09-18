# frozen_string_literal: true

require "time"

module RubyDecisionModel
  # Retry rules shared by every provider. Defaults follow the official
  # Typesafe SDKs: two retries after the initial attempt, exponential
  # backoff from 0.5s capped at 5s with up to 25% jitter subtracted,
  # Retry-After honored up to 60s, and a 30s total budget across attempts.
  class RetryPolicy < Data.define(
    :max_retries,
    :backoff_initial,
    :backoff_max,
    :backoff_jitter,
    :http_statuses,
    :respect_retry_after,
    :max_retry_after,
    :retry_connection_errors,
    :retry_timeouts,
    :total_timeout
  )
    DEFAULT_STATUSES = ([408, 429] + (500..599).to_a).freeze

    TIMEOUT_EXCEPTIONS = [Net::OpenTimeout, Net::ReadTimeout].freeze
    CONNECTION_EXCEPTIONS = [
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::ECONNABORTED,
      Errno::EHOSTUNREACH,
      Errno::ENETUNREACH,
      Errno::EPIPE,
      SocketError,
      IOError,
      OpenSSL::SSL::SSLError
    ].freeze

    def initialize(max_retries: 2, backoff_initial: 0.5, backoff_max: 5.0, backoff_jitter: 0.25,
                   http_statuses: DEFAULT_STATUSES, respect_retry_after: true, max_retry_after: 60.0,
                   retry_connection_errors: true, retry_timeouts: true, total_timeout: 30.0)
      super
      validate!
    end

    # Accepts a RetryPolicy, a Hash of overrides, or nil (defaults).
    def self.from(value)
      case value
      when RetryPolicy then value
      when nil then new
      when Hash then new(**value.transform_keys(&:to_sym))
      else
        raise ConfigurationError, "retry must be a RetryPolicy or a Hash of overrides, got #{value.class}"
      end
    end

    def retryable_status?(status)
      http_statuses.include?(status)
    end

    def timeout_exception?(exception)
      TIMEOUT_EXCEPTIONS.any? { |klass| exception.is_a?(klass) }
    end

    def connection_exception?(exception)
      CONNECTION_EXCEPTIONS.any? { |klass| exception.is_a?(klass) }
    end

    def retryable_exception?(exception)
      return retry_timeouts if timeout_exception?(exception)
      return retry_connection_errors if connection_exception?(exception)

      false
    end

    # Seconds to wait before the retry numbered `retry_number` (0 for the
    # first retry). `random` returns a Float in 0...1 and exists so tests can
    # pin the jitter.
    def backoff(retry_number, random: -> { rand })
      base = [backoff_initial * (2**retry_number), backoff_max].min
      [base * (1.0 - (backoff_jitter * random.call)), 0.0].max
    end

    # Delay before the next retry: the server's Retry-After when present and
    # honored (clamped to max_retry_after), otherwise the computed backoff.
    def delay(retry_number, headers: {}, random: -> { rand })
      hinted = respect_retry_after ? retry_after_seconds(headers) : nil
      return [hinted, max_retry_after].min if hinted

      backoff(retry_number, random: random)
    end

    # Reads retry-after-ms (preferred) or Retry-After (seconds or HTTP date).
    # Header names are matched case-insensitively. Returns nil when absent
    # or unparseable.
    def retry_after_seconds(headers)
      return nil unless headers.is_a?(Hash)

      ms = header_value(headers, "retry-after-ms")
      if ms
        parsed = Float(ms, exception: false)
        return parsed / 1000.0 if parsed && parsed >= 0
      end

      raw = header_value(headers, "retry-after")
      return nil if raw.nil?

      seconds = Float(raw, exception: false)
      return seconds if seconds && seconds >= 0

      begin
        [Time.httpdate(raw.to_s) - Time.now, 0.0].max
      rescue ArgumentError
        nil
      end
    end

    private

    def validate!
      unless max_retries.is_a?(Integer) && max_retries >= 0
        raise ConfigurationError, "max_retries must be a non-negative Integer, got #{max_retries.inspect}"
      end

      { backoff_initial: backoff_initial, backoff_max: backoff_max, max_retry_after: max_retry_after }.each do |name, value|
        next if finite_non_negative?(value)

        raise ConfigurationError, "#{name} must be a finite non-negative number, got #{value.inspect}"
      end

      unless finite_non_negative?(backoff_jitter) && backoff_jitter <= 1.0
        raise ConfigurationError, "backoff_jitter must be a number between 0 and 1, got #{backoff_jitter.inspect}"
      end

      unless total_timeout.nil? || finite_non_negative?(total_timeout)
        raise ConfigurationError, "total_timeout must be nil or a finite non-negative number, got #{total_timeout.inspect}"
      end

      return if http_statuses.respond_to?(:include?)

      raise ConfigurationError, "http_statuses must respond to include?, got #{http_statuses.inspect}"
    end

    def finite_non_negative?(value)
      value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def header_value(headers, name)
      headers.each do |key, value|
        next unless key.to_s.casecmp?(name)

        return value.is_a?(Array) ? value.first : value
      end
      nil
    end
  end
end
