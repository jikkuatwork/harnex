require_relative "adapters/base"
require_relative "adapters/generic"
require_relative "adapters/codex"
require_relative "adapters/codex_appserver"
require_relative "adapters/claude"

module Harnex
  module Adapters
    module_function

    def known
      registry.keys.sort
    end

    def supported?(key)
      !key.to_s.strip.empty?
    end

    # Phase 3 flipped the default — `codex` resolves to CodexAppServer.
    # Legacy PTY adapter is reachable via `legacy_pty: true` (driven by
    # `harnex run codex --legacy-pty`). Will be removed in 0.7.0.
    def codex_appserver_enabled?
      true
    end

    def build(key, extra_args = [], legacy_pty: false)
      key_str = key.to_s
      if key_str == "codex"
        return legacy_pty ? Codex.new(extra_args) : CodexAppServer.new(extra_args)
      end

      adapter_class = registry[key_str]
      return adapter_class.new(extra_args) if adapter_class

      Generic.new(key_str, extra_args)
    end

    def registry
      @registry ||= {
        "claude" => Claude,
        "codex" => Codex
      }
    end
  end
end
