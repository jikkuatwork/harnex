require "optparse"

module Harnex
  class Recipes
    RECIPES_DIR = File.expand_path("../../../../recipes", __FILE__)

    def self.usage
      <<~TEXT
        Usage: harnex recipes [list|show <name>]

        Subcommands:
          list          List available recipes (default)
          show <name>   Print a recipe by name or number

        Examples:
          harnex recipes
          harnex recipes list
          harnex recipes show 01
          harnex recipes show fire_and_watch

        Common patterns:
          harnex recipes show 01   # Fire and Watch
          harnex recipes show 02   # Chain Implement
          harnex recipes show 03   # Buddy

        Gotchas:
          Recipes are compact command walkthroughs.
          Use `harnex agents-guide` for the deeper agent-facing guide.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      subcommand = @argv.shift
      case subcommand
      when nil, "list"
        list_recipes
      when "show"
        show_recipe(@argv.first)
      when "-h", "--help"
        puts self.class.usage
        0
      else
        # Treat bare arg as show
        show_recipe(subcommand)
      end
    end

    private

    def list_recipes
      files = recipe_files
      if files.empty?
        puts "No recipes found."
        return 0
      end

      puts "Recipes:\n\n"
      files.each do |file|
        name = File.basename(file, ".md")
        title = extract_title(file)
        puts "  #{name}  #{title}"
      end
      puts "\nRun `harnex recipes show <name>` to read one."
      0
    end

    def show_recipe(query)
      unless query
        warn("harnex recipes show: recipe name required")
        return 1
      end

      file = find_recipe(query)
      unless file
        warn("harnex recipes: no recipe matching #{query.inspect}")
        warn("Run `harnex recipes list` to see available recipes.")
        return 1
      end

      puts File.read(file)
      0
    end

    def find_recipe(query)
      files = recipe_files
      # Exact basename match (with or without .md)
      exact = files.find { |f| File.basename(f, ".md") == query }
      return exact if exact

      # Prefix match (e.g. "01" matches "01_fire_and_watch")
      prefix = files.find { |f| File.basename(f, ".md").start_with?(query) }
      return prefix if prefix

      # Substring match (e.g. "fire" matches "01_fire_and_watch")
      files.find { |f| File.basename(f, ".md").include?(query) }
    end

    def recipe_files
      return [] unless Dir.exist?(RECIPES_DIR)

      Dir.glob(File.join(RECIPES_DIR, "*.md")).sort
    end

    def extract_title(file)
      first_line = File.foreach(file).first.to_s.strip
      first_line.start_with?("#") ? first_line.sub(/^#+\s*/, "") : ""
    end
  end
end
