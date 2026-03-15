require "securerandom"

module Harnex
  class Inbox
    DEFAULT_TTL = 120
    MAX_PENDING = 64
    DELIVERY_TIMEOUT = 300

    def initialize(session, state_machine, ttl: DEFAULT_TTL)
      @session = session
      @state_machine = state_machine
      @ttl = ttl.to_f
      @queue = []
      @messages = {}
      @mutex = Mutex.new
      @condvar = ConditionVariable.new
      @thread = nil
      @running = false
      @delivered_total = 0
      @expired_total = 0
    end

    def start
      @running = true
      @thread = Thread.new { delivery_loop }
    end

    def stop
      @running = false
      @mutex.synchronize { @condvar.broadcast }
      @thread&.join(2)
      @thread&.kill
    end

    def enqueue(text:, submit:, enter_only:, force: false)
      msg = Message.new(
        id: SecureRandom.hex(8),
        text: text,
        submit: submit,
        enter_only: enter_only,
        force: force,
        queued_at: Time.now,
        status: :queued
      )

      # Force messages bypass the queue entirely
      if force
        return deliver_now(msg)
      end

      # Fast path: prompt ready and queue empty — deliver immediately.
      # Check under lock, then release before calling deliver_now to
      # avoid recursive locking (deliver_now also acquires @mutex).
      try_fast = @mutex.synchronize do
        @queue.empty? && @state_machine.state == :prompt
      end

      if try_fast
        begin
          result = deliver_now(msg)
          return result if msg.status == :delivered
        rescue StandardError
          # Fall through to queue if delivery failed
        end
        msg.status = :queued
        msg.error = nil
      end

      @mutex.synchronize do
        raise "inbox full (#{MAX_PENDING} pending messages)" if @queue.size >= MAX_PENDING

        @queue << msg
        @messages[msg.id] = msg
        @condvar.broadcast
      end

      { ok: true, status: "queued", message_id: msg.id, http_status: 202 }
    end

    def message_status(id)
      @mutex.synchronize do
        msg = @messages[id]
        return nil unless msg
        msg.to_h
      end
    end

    def stats
      @mutex.synchronize do
        { pending: @queue.size, delivered_total: @delivered_total, expired_total: @expired_total }
      end
    end

    def pending_messages
      @mutex.synchronize { @queue.map(&:to_h) }
    end

    def drop(message_id)
      @mutex.synchronize do
        msg = @messages[message_id]
        return nil unless msg && @queue.any? { |queued| queued.id == message_id }

        @queue.delete_if { |queued| queued.id == message_id }
        msg.status = :dropped
        msg.to_h
      end
    end

    def clear
      @mutex.synchronize do
        count = @queue.size
        @queue.each { |msg| msg.status = :dropped }
        @queue.clear
        count
      end
    end

    private

    def deliver_now(msg)
      result = @session.inject_via_adapter(
        text: msg.text,
        submit: msg.submit,
        enter_only: msg.enter_only,
        force: msg.force
      )
      msg.status = :delivered
      msg.delivered_at = Time.now
      @mutex.synchronize do
        @delivered_total += 1
        @messages[msg.id] = msg
      end
      result.merge(ok: true, status: "delivered", message_id: msg.id, http_status: 200)
    rescue ArgumentError => e
      msg.status = :failed
      msg.error = e.message
      @mutex.synchronize { @messages[msg.id] = msg }
      raise
    end

    def delivery_loop
      while @running
        msg = @mutex.synchronize do
          expire_stale_messages_locked
          while @queue.empty? && @running
            @condvar.wait(@mutex, 1.0)
            expire_stale_messages_locked
          end
          @queue.first
        end

        break unless @running
        next unless msg

        ready = @state_machine.wait_for_prompt(prompt_wait_timeout)
        unless ready
          next if @running # Keep waiting
        end

        msg = @mutex.synchronize do
          expire_stale_messages_locked
          @queue.first
        end
        next unless msg

        begin
          deliver_now(msg)
          @mutex.synchronize { @queue.shift if @queue.first&.id == msg.id }
        rescue ArgumentError
          # State race — will retry on next loop iteration
          sleep 0.1
        rescue StandardError => e
          msg.status = :failed
          msg.error = e.message
          @mutex.synchronize do
            @queue.shift
            @messages[msg.id] = msg
          end
        end
      end
    end

    def expire_stale_messages
      @mutex.synchronize { expire_stale_messages_locked }
    end

    def expire_stale_messages_locked(now = Time.now)
      while (msg = @queue.first) && stale_message?(msg, now)
        msg.status = :expired
        @queue.shift
        @expired_total += 1
      end
    end

    def stale_message?(msg, now)
      return false unless msg.queued_at

      (now - msg.queued_at) > @ttl
    end

    def prompt_wait_timeout
      return 0.1 if @ttl <= 0.0

      [DELIVERY_TIMEOUT.to_f, @ttl].min
    end
  end
end
