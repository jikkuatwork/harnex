module Harnex
  module Adapters
    class Generic < Base
      def initialize(cli_name, extra_args = [])
        @cli_name = cli_name
        super(cli_name, extra_args)
      end

      def base_command
        [@cli_name]
      end
    end
  end
end
