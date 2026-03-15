require_relative "lib/harnex/version"

Gem::Specification.new do |s|
  s.name        = "harnex"
  s.version     = Harnex::VERSION
  s.summary     = "PTY harness for terminal AI agents"
  s.description = "A local PTY harness that wraps terminal AI agents (Claude, Codex) " \
                  "and adds a control plane for discovery, messaging, and coordination."
  s.authors     = ["Jikku Jose"]
  s.email       = ["jikkujose@gmail.com"]
  s.homepage    = "https://github.com/jikkujose/harnex"
  s.license     = "MIT"

  s.required_ruby_version = ">= 3.0"

  s.files         = Dir["lib/**/*.rb", "bin/*", "LICENSE", "README.md"]
  s.bindir        = "bin"
  s.executables   = ["harnex"]

  s.metadata = {
    "homepage_uri"    => s.homepage,
    "source_code_uri" => s.homepage,
    "bug_tracker_uri" => "#{s.homepage}/issues"
  }
end
