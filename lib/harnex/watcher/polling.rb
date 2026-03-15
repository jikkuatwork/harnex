module Harnex
  module Polling
    POLL_INTERVAL = 0.5

    class << self
      def available?
        true
      end

      def directory_io(path, _events)
        PollingIO.new(path)
      end
    end

    class PollingIO
      EVENT_HEADER_SIZE = 16

      def initialize(dir_path)
        @dir_path = dir_path
        @snapshots = take_snapshot
        @closed = false
      end

      def readpartial(_maxlen)
        raise IOError, "closed stream" if @closed

        loop do
          sleep POLL_INTERVAL
          raise IOError, "closed stream" if @closed

          current = take_snapshot
          changed = detect_changes(@snapshots, current)
          @snapshots = current
          next if changed.empty?

          return encode_events(changed)
        end
      end

      def close
        @closed = true
      end

      def closed?
        @closed
      end

      private

      def take_snapshot
        entries = {}
        Dir.foreach(@dir_path) do |name|
          next if name == "." || name == ".."

          path = File.join(@dir_path, name)
          stat = File.stat(path)
          entries[name] = { mtime: stat.mtime, size: stat.size }
        rescue Errno::ENOENT, Errno::EACCES
          nil
        end
        entries
      rescue Errno::ENOENT, Errno::EACCES
        {}
      end

      def detect_changes(old_snap, new_snap)
        changed = []
        new_snap.each do |name, info|
          prev = old_snap[name]
          if prev.nil? || prev[:mtime] != info[:mtime] || prev[:size] != info[:size]
            changed << name
          end
        end
        changed
      end

      def encode_events(names)
        buf = +""
        buf.force_encoding(Encoding::BINARY)
        names.each do |name|
          name_bytes = name.encode(Encoding::BINARY)
          padded_len = (name_bytes.bytesize + 4) & ~3
          # inotify event header: wd(int) + mask(uint) + cookie(uint) + len(uint)
          buf << [0, Harnex::Inotify::IN_CLOSE_WRITE, 0, padded_len].pack("iIII")
          buf << name_bytes
          buf << ("\0" * (padded_len - name_bytes.bytesize))
        end
        buf
      end
    end
  end
end
