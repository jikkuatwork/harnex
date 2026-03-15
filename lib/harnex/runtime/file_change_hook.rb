module Harnex
  class FileChangeHook
    EVENT_HEADER_SIZE = 16
    WATCH_MASK = Inotify::IN_ATTRIB | Inotify::IN_CLOSE_WRITE | Inotify::IN_CREATE | Inotify::IN_MOVED_TO
    RETRY_SECONDS = 1.0
    IDLE_SLEEP_SECONDS = 0.1

    def initialize(session, config)
      @session = session
      @config = config
      @target_dir = File.dirname(config.absolute_path)
      @target_name = File.basename(config.absolute_path)
      @buffer = +""
      @buffer.force_encoding(Encoding::BINARY)
      @mutex = Mutex.new
      @change_generation = 0
      @delivered_generation = 0
      @last_change_at = nil
    end

    def start
      Thread.new { run }
    end

    private

    def run
      reader_thread = Thread.new { watch_loop }
      delivery_loop
    ensure
      reader_thread&.kill
      reader_thread&.join(0.1)
    end

    def watch_loop
      io = Watcher.directory_io(@target_dir, WATCH_MASK)
      loop do
        chunk = io.readpartial(4096)
        note_change if relevant_change?(chunk)
      rescue EOFError, IOError, Errno::EIO
        break
      end
    ensure
      io&.close unless io&.closed?
    end

    def delivery_loop
      loop do
        generation, delivered_generation, last_change_at = snapshot
        if generation == delivered_generation || last_change_at.nil?
          sleep IDLE_SLEEP_SECONDS
          next
        end

        remaining = @config.debounce_seconds - (Time.now - last_change_at)
        if remaining.positive?
          sleep [remaining, IDLE_SLEEP_SECONDS].max
          next
        end

        begin
          @session.inbox.enqueue(
            text: @config.hook_message,
            submit: true,
            enter_only: false,
            force: false
          )
          mark_delivered
        rescue StandardError => e
          break if e.message == "session is not running"

          sleep RETRY_SECONDS
        end
      end
    end

    def relevant_change?(chunk)
      @buffer << chunk
      changed = false

      while @buffer.bytesize >= EVENT_HEADER_SIZE
        _, mask, _, name_length = @buffer.byteslice(0, EVENT_HEADER_SIZE).unpack("iIII")
        event_size = EVENT_HEADER_SIZE + name_length
        break if @buffer.bytesize < event_size

        name = @buffer.byteslice(EVENT_HEADER_SIZE, name_length).to_s.delete("\0")
        changed ||= name == @target_name && (mask & WATCH_MASK).positive?
        @buffer = @buffer.byteslice(event_size, @buffer.bytesize - event_size).to_s
      end

      changed
    end

    def note_change
      @mutex.synchronize do
        @change_generation += 1
        @last_change_at = Time.now
      end
    end

    def snapshot
      @mutex.synchronize { [@change_generation, @delivered_generation, @last_change_at] }
    end

    def mark_delivered
      @mutex.synchronize do
        @delivered_generation = @change_generation
      end
    end
  end
end
