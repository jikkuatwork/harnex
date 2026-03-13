require_relative "adapters/base"
require_relative "adapters/codex"
require_relative "adapters/claude"

module Harnex
  module Adapters
    module_function

    def supported
      registry.keys.sort
    end

    def build(key, extra_args = [])
      adapter_class = registry[key.to_s]
      raise ArgumentError, unsupported_adapter_message(key) unless adapter_class

      adapter_class.new(extra_args)
    end

    def unsupported_adapter_message(key)
      "unsupported cli #{key.inspect} (supported: #{supported.join(', ')})"
    end

    def registry
      @registry ||= {
        "claude" => Claude,
        "codex" => Codex
      }
    end
  end
end
