require_relative "lib/harnex/version"

Gem::Specification.new do |s|
  s.name        = "harnex"
  s.version     = Harnex::VERSION
  s.summary     = "Pi workers (GPT models) as tools for you and your coding agents"
  s.description = "Hand questions and tasks to Pi workers in visible tmux windows and get the " \
                  "result back in one call: lanes in git worktrees, follow-ups that keep context, " \
                  "an MCP server for Claude Code and Pi, and a local harness for any terminal agent."
  s.authors     = ["Jikku Jose"]
  s.email       = ["jikkujose@gmail.com"]
  s.homepage    = "https://github.com/jikkuatwork/harnex"
  s.license     = "MIT"

  s.required_ruby_version = ">= 3.0"

  s.files         = Dir["lib/**/*.rb", "bin/*", "LICENSE", "README.md", "CHANGELOG.md", "GUIDE.md", "TECHNICAL.md", "docs/*.md", "recipes/*.md", "guides/*.md", "agents/*.md"]
  s.bindir        = "bin"
  s.executables   = ["harnex"]

  s.metadata = {
    "homepage_uri"    => s.homepage,
    "source_code_uri" => s.homepage,
    "bug_tracker_uri" => "#{s.homepage}/issues",
    "documentation_uri" => "https://harnex.zyt.app",
    "changelog_uri" => "#{s.homepage}/blob/main/CHANGELOG.md"
  }
end
