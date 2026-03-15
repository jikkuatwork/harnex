require_relative "adapters/base"
require_relative "adapters/generic"
require_relative "adapters/codex"
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

    def build(key, extra_args = [])
      adapter_class = registry[key.to_s]
      return adapter_class.new(extra_args) if adapter_class

      Generic.new(key.to_s, extra_args)
    end

    def registry
      @registry ||= {
        "claude" => Claude,
        "codex" => Codex
      }
    end
  end
end
