module Harnex
  class Guide
    GUIDE_PATH = File.expand_path("../../../../GUIDE.md", __FILE__)

    def self.usage
      <<~TEXT
        Usage: harnex guide

        Print the getting started guide.

        Common patterns:
          harnex guide
          harnex agents-guide
          harnex recipes

        Gotchas:
          guide is short human onboarding.
          agents-guide is the deeper operational reference for dispatching agents.
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
