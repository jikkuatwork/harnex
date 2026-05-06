module Harnex
  class AgentsGuide
    GUIDES_DIR = File.expand_path("../../../../guides", __FILE__)

    def self.usage
      <<~TEXT
        Usage: harnex agents-guide [list|show <topic>|<topic>]

        Subcommands:
          list           List available agent guide topics (default)
          show <topic>   Print a guide by name or number

        Examples:
          harnex agents-guide
          harnex agents-guide list
          harnex agents-guide show 01
          harnex agents-guide show dispatch
          harnex agents-guide monitoring
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      subcommand = @argv.shift
      case subcommand
      when nil, "list"
        list_guides
      when "show"
        show_guide(@argv.first)
      when "-h", "--help"
        puts self.class.usage
        0
      else
        show_guide(subcommand)
      end
    end

    private

    def list_guides
      files = guide_files
      if files.empty?
        puts "No agent guides found."
        return 0
      end

      puts "Agent guides:\n\n"
      files.each do |file|
        name = File.basename(file, ".md")
        title = extract_title(file)
        puts "  #{name}  #{title}"
      end
      puts "\nRun `harnex agents-guide show <topic>` to read one."
      0
    end

    def show_guide(query)
      unless query
        warn("harnex agents-guide show: topic required")
        return 1
      end

      file = find_guide(query)
      unless file
        warn("harnex agents-guide: no topic matching #{query.inspect}")
        warn("Run `harnex agents-guide list` to see available topics.")
        return 1
      end

      puts File.read(file)
      0
    end

    def find_guide(query)
      files = guide_files

      exact = files.find { |file| File.basename(file, ".md") == query }
      return exact if exact

      prefix = files.find { |file| File.basename(file, ".md").start_with?(query) }
      return prefix if prefix

      files.find { |file| File.basename(file, ".md").include?(query) }
    end

    def guide_files
      return [] unless Dir.exist?(GUIDES_DIR)

      Dir.glob(File.join(GUIDES_DIR, "*.md")).sort
    end

    def extract_title(file)
      first_line = File.foreach(file).first.to_s.strip
      first_line.start_with?("#") ? first_line.sub(/^#+\s*/, "") : ""
    end
  end
end
