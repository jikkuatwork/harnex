module Harnex
  # Bounded in-memory aggregate for active context-window samples.
  #
  # It retains only the final valid occupancy sample, independent high-water
  # marks, and counters that make unavailable samples visible without storing
  # raw protocol payloads.
  class ContextTelemetry
    MEASUREMENT_STATUSES = %w[observed estimated].freeze

    def initialize(status:, source:)
      measurement_status = status.to_s
      unless MEASUREMENT_STATUSES.include?(measurement_status)
        raise ArgumentError, "context telemetry status must be observed or estimated"
      end

      @measurement_status = measurement_status
      @source = source.to_s.empty? ? nil : source.to_s
      @terminal_tokens = nil
      @window_tokens = nil
      @terminal_percent = nil
      @peak_tokens = nil
      @peak_percent = nil
      @samples = 0
      @missing_samples = 0
      @latest_sample_status = nil
      @valid_sample_seen = false
    end

    def record(tokens:, window_tokens:, percent: nil)
      @samples += 1
      token_count = nonnegative_integer(tokens)
      window_size = positive_integer(window_tokens)
      pressure_percent = nonnegative_float(percent)
      pressure_percent ||= derived_percent(token_count, window_size)

      if token_count.nil?
        @missing_samples += 1
        @latest_sample_status = "missing"
        return snapshot
      end

      @valid_sample_seen = true
      @terminal_tokens = token_count
      @window_tokens = window_size
      @terminal_percent = pressure_percent
      @peak_tokens = [@peak_tokens, token_count].compact.max
      @peak_percent = [@peak_percent, pressure_percent].compact.max
      @latest_sample_status = @measurement_status
      snapshot
    end

    def snapshot
      {
        status: @valid_sample_seen ? @measurement_status : "missing",
        source: @source,
        terminal_tokens: @terminal_tokens,
        window_tokens: @window_tokens,
        terminal_percent: @terminal_percent,
        peak_tokens: @peak_tokens,
        peak_percent: @peak_percent,
        samples: @samples,
        missing_samples: @missing_samples,
        latest_sample_status: @latest_sample_status
      }
    end

    private

    def nonnegative_integer(value)
      return nil if value.nil?

      parsed = Integer(value)
      return nil if value.is_a?(Numeric) && value.to_f != parsed.to_f
      return nil if parsed.negative?

      parsed
    rescue ArgumentError, TypeError, FloatDomainError
      nil
    end

    def positive_integer(value)
      parsed = nonnegative_integer(value)
      parsed&.positive? ? parsed : nil
    end

    def nonnegative_float(value)
      return nil if value.nil?

      parsed = Float(value)
      return nil unless parsed.finite?
      return nil if parsed.negative?

      parsed
    rescue ArgumentError, TypeError
      nil
    end

    def derived_percent(token_count, window_size)
      return nil if token_count.nil? || window_size.nil?

      ((token_count.to_f / window_size) * 100).round(2)
    end
  end
end
