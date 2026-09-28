require "time"

module Harnex
  # Caller-declared provenance is deliberately an enum, never a free-text log.
  # Session owns first-request-wins synchronization and work acceptance.
  class StopRequest
    REASONS = %w[manual completion runtime_budget].map(&:freeze).freeze
    ORIGINS = %w[api cli auto_stop watch runtime].map(&:freeze).freeze
    WORK_STATES = %w[running completed failed unknown].freeze

    def self.validate!(reason:, origin:)
      raise ArgumentError, "stop reason must be one of #{REASONS.join(', ')}" unless REASONS.include?(reason)
      raise ArgumentError, "stop origin must be one of #{ORIGINS.join(', ')}" unless ORIGINS.include?(origin)
    end

    def initialize(reason:, origin:, work_state:, requested_at: Time.now, runtime_limit_s: nil)
      self.class.validate!(reason: reason, origin: origin)
      raise ArgumentError, "invalid stop work state" unless WORK_STATES.include?(work_state)

      @payload = {
        reason: reason.dup.freeze,
        origin: origin.dup.freeze,
        requested_at: requested_at.getutc.iso8601(3).freeze,
        work_state: work_state.dup.freeze
      }
      unless runtime_limit_s.nil?
        limit = Float(runtime_limit_s)
        raise ArgumentError, "invalid stop runtime limit" unless limit.finite? && limit.positive?

        @payload[:runtime_limit_s] = limit
      end
      @payload.freeze
    end

    def to_h
      @payload.dup
    end
  end
end
