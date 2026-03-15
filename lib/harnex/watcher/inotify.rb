require "fiddle/import"

module Harnex
  module Inotify
    extend Fiddle::Importer

    IN_ATTRIB = 0x00000004
    IN_CLOSE_WRITE = 0x00000008
    IN_CREATE = 0x00000100
    IN_MOVED_TO = 0x00000080

    @available = false
    begin
      dlload Fiddle.dlopen(nil)
      extern "int inotify_init(void)"
      extern "int inotify_add_watch(int, const char*, unsigned int)"
      @available = true
    rescue Fiddle::DLError
      @available = false
    end

    class << self
      def available?
        @available
      end

      def directory_io(path, mask)
        raise "inotify is not available on this system" unless available?

        fd = inotify_init
        raise "could not initialize file watch" if fd.negative?

        watch_id = inotify_add_watch(fd, path, mask)
        if watch_id.negative?
          IO.for_fd(fd, autoclose: true)&.close
          raise "could not watch #{path}"
        end

        IO.for_fd(fd, "rb", autoclose: true)
      end
    end
  end
end
