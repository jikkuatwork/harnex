require_relative "watcher/inotify"
require_relative "watcher/polling"

module Harnex
  module Watcher
    module_function

    def available?
      true
    end

    def directory_io(path, events)
      if Inotify.available?
        Inotify.directory_io(path, events)
      else
        Polling.directory_io(path, events)
      end
    end

    def backend
      Inotify.available? ? :inotify : :polling
    end
  end
end
