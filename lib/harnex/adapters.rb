require_relative "adapters/base"
require_relative "adapters/generic"
require_relative "adapters/claude"
require_relative "adapters/opencode"
require_relative "adapters/pi"

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
      key_str = key.to_s
      adapter_class = registry[key_str]
      return adapter_class.new(extra_args) if adapter_class

      Generic.new(key_str, extra_args)
    end

    def registry
      @registry ||= {
        "claude" => Claude,
        "opencode" => Opencode,
        "pi" => Pi
      }
    end
  end
end
