module Harnex
  class Guide
    GUIDE_PATH = File.expand_path("../../../../GUIDE.md", __FILE__)

    def self.usage
      <<~TEXT
        Usage: harnex guide

        Print the getting started guide.
      TEXT
    end

    def run
      unless File.exist?(GUIDE_PATH)
        warn("harnex guide: GUIDE.md not found at #{GUIDE_PATH}")
        return 1
      end

      puts File.read(GUIDE_PATH)
      0
    end
  end
end
