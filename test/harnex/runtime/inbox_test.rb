require_relative "../../test_helper"

class InboxTest < Minitest::Test
  # Minimal stubs to test Inbox without a real PTY session.

  class FakeStateMachine
    attr_accessor :state

    def initialize(state = :prompt)
      @state = state
      @mutex = Mutex.new
      @condvar = ConditionVariable.new
    end

    def wait_for_prompt(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @mutex.synchronize do
        loop do
          return true if @state == :prompt
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false if remaining <= 0
          @condvar.wait(@mutex, remaining)
        end
      end
    end

    def force_busy!
      @mutex.synchronize { @state = :busy }
    end

    def signal_prompt!
      @mutex.synchronize do
        @state = :prompt
        @condvar.broadcast
      end
    end
  end

  class FakeSession
    attr_reader :injections

    def initialize
      @injections = []
    end

    def inject_via_adapter(text:, submit:, enter_only:, force: false)
      @injections << { text: text, submit: submit, enter_only: enter_only, force: force }
      { ok: true, bytes_written: text.to_s.bytesize }
    end
  end

  def setup
    @session = FakeSession.new
    @state = FakeStateMachine.new(:prompt)
    @inbox = Harnex::Inbox.new(@session, @state)
  end

  def teardown
    @inbox.stop
  end

  # --- delivery via thread when prompt is ready ---

  def test_delivery_via_thread_when_prompt_ready
    @inbox.start
    # State is :prompt, but we go through the delivery thread
    # by starting from busy then signaling prompt
    @state.state = :busy
    result = @inbox.enqueue(text: "hello", submit: true, enter_only: false)
    assert_equal "queued", result[:status]
    assert_equal 202, result[:http_status]

    @state.signal_prompt!
    sleep 0.5  # give delivery thread time

    msg = @inbox.message_status(result[:message_id])
    assert_equal "delivered", msg[:status]
    assert_equal 1, @session.injections.length
    assert_equal "hello", @session.injections.first[:text]
  end

  # --- queued delivery ---

  def test_queued_when_busy_then_delivered_on_prompt
    @state.state = :busy
    @inbox.start
    result = @inbox.enqueue(text: "deferred", submit: true, enter_only: false)
    assert_equal "queued", result[:status]
    assert_equal 202, result[:http_status]
    assert result[:message_id]

    # Signal prompt so delivery thread picks it up
    @state.signal_prompt!
    sleep 0.5

    msg = @inbox.message_status(result[:message_id])
    assert_equal "delivered", msg[:status]
    assert_equal 1, @session.injections.length
  end

  # --- force delivery bypasses queue ---

  def test_force_bypasses_queue
    @state.state = :busy
    result = @inbox.enqueue(text: "urgent", submit: true, enter_only: false, force: true)
    assert_equal "delivered", result[:status]
    assert_equal 200, result[:http_status]
    assert_equal true, @session.injections.first[:force]
  end

  # --- message_status ---

  def test_message_status_returns_nil_for_unknown_id
    assert_nil @inbox.message_status("nonexistent")
  end

  def test_message_status_shape_for_queued
    @state.state = :busy
    @inbox.start
    result = @inbox.enqueue(text: "test", submit: true, enter_only: false)
    msg = @inbox.message_status(result[:message_id])
    assert msg[:id]
    assert_equal "queued", msg[:status].to_s
    assert msg[:queued_at]
    assert_equal "test", msg[:text_preview]
  end

  # --- stats ---

  def test_stats_initial
    stats = @inbox.stats
    assert_equal 0, stats[:pending]
    assert_equal 0, stats[:delivered_total]
    assert_equal 0, stats[:expired_total]
  end

  def test_stats_after_delivery_via_thread
    @inbox.start
    @state.state = :busy

    @inbox.enqueue(text: "a", submit: true, enter_only: false)
    @inbox.enqueue(text: "b", submit: true, enter_only: false)

    @state.signal_prompt!
    sleep 0.5

    stats = @inbox.stats
    assert_equal 0, stats[:pending]
    assert_equal 2, stats[:delivered_total]
    assert_equal 0, stats[:expired_total]
  end

  # --- fast-path immediate delivery ---

  def test_fast_path_delivers_immediately_when_prompt_ready
    result = @inbox.enqueue(text: "fast", submit: true, enter_only: false)
    assert_equal "delivered", result[:status]
    assert_equal 200, result[:http_status]
    assert_equal 1, @session.injections.length
    assert_equal "fast", @session.injections.first[:text]
  end

  # --- expiry and queue management ---

  def test_expire_stale_messages_removes_oldest_pending_message
    @inbox.stop
    @state.state = :busy
    @inbox = Harnex::Inbox.new(@session, @state, ttl: 0.1)
    @inbox.start

    result = @inbox.enqueue(text: "stale", submit: true, enter_only: false)
    sleep 0.25

    msg = @inbox.message_status(result[:message_id])
    stats = @inbox.stats

    assert_equal "expired", msg[:status]
    assert_equal 0, stats[:pending]
    assert_equal 1, stats[:expired_total]
    assert_empty @session.injections
  end

  def test_drop_removes_pending_message_from_queue
    @state.state = :busy
    result = @inbox.enqueue(text: "drop-me", submit: true, enter_only: false)

    dropped = @inbox.drop(result[:message_id])

    assert_equal "dropped", dropped[:status]
    assert_empty @inbox.pending_messages
    assert_equal "dropped", @inbox.message_status(result[:message_id])[:status]
  end

  def test_clear_removes_all_pending_messages
    @state.state = :busy
    3.times { |index| @inbox.enqueue(text: "msg-#{index}", submit: true, enter_only: false) }

    cleared = @inbox.clear

    assert_equal 3, cleared
    assert_empty @inbox.pending_messages
    assert_equal 0, @inbox.stats[:pending]
  end
end
