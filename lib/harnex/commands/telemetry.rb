require "json"
require "optparse"

module Harnex
  class TelemetryCommand
    COMMANDS = %w[assert-canonical reconcile].freeze

    def self.usage(program_name = "harnex telemetry")
      <<~TEXT
        Usage:
          #{program_name} assert-canonical [--canonical PATH | --global] [--source PATH] [--json]
          #{program_name} reconcile [--canonical PATH | --global] --source PATH [--apply] [--json]

        Options:
          --canonical PATH  Canonical dispatch JSONL path
          --global          Use the global harnex dispatch JSONL
          --source PATH     Source JSONL file or directory; repeatable
          --apply           Append missing records when reconciling
          --json            Emit JSON report
          -h, --help        Show this help
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      command = @argv.shift
      case command
      when nil, "-h", "--help"
        puts self.class.usage
        0
      when *COMMANDS
        options = parse_options(command, @argv)
        if options[:help]
          puts self.class.usage
          return 0
        end
        validate_options!(command, options)
        result = TelemetryReconciler.new(
          command: command,
          canonical: canonical_path(options),
          sources: options[:sources],
          apply: command == "reconcile" && options[:apply]
        ).run
        if options[:json]
          puts JSON.generate(result.report)
        else
          puts render_human(result.report)
        end
        result.exitstatus
      else
        raise OptionParser::ParseError, "unknown telemetry subcommand #{command.inspect}"
      end
    end

    private

    def parse_options(command, argv)
      options = { command: command, sources: [], apply: false, json: false }
      parser(options).parse!(argv)
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      options
    end

    def parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: harnex telemetry #{options[:command]} [options]"
        opts.on("--canonical PATH") { |value| options[:canonical] = value }
        opts.on("--global") { options[:global] = true }
        opts.on("--source PATH") { |value| options[:sources] << value }
        opts.on("--apply") { options[:apply] = true }
        opts.on("--json") { options[:json] = true }
        opts.on("-h", "--help") { options[:help] = true }
      end
    end

    def validate_options!(command, options)
      if options[:canonical] && options[:global]
        raise OptionParser::InvalidOption, "--canonical and --global are mutually exclusive"
      end
      if command == "assert-canonical" && options[:apply]
        raise OptionParser::InvalidOption, "--apply is only supported with reconcile"
      end
      return unless command == "reconcile" && options[:sources].empty?

      raise OptionParser::MissingArgument, "reconcile --source required"
    end

    def canonical_path(options)
      return Harnex::DispatchHistory.global_path if options[:global]

      options[:canonical] || Harnex::DispatchHistory.path_for(Dir.pwd)
    end

    def render_human(report)
      lines = [
        "telemetry #{report.fetch(:command)}: #{report.fetch(:status)}",
        "canonical: #{report.fetch(:canonical)}",
        "rows: #{report.fetch(:canonical_rows)} missing=#{report.fetch(:missing)} conflicts=#{report.fetch(:conflicts)} open_starts=#{report.fetch(:open_starts)} appended=#{report.fetch(:appended)}"
      ]
      report.fetch(:diagnostics).each { |diagnostic| lines << "diagnostic: #{diagnostic}" }
      truncated = report.fetch(:diagnostics_truncated)
      lines << "diagnostics truncated: #{truncated}" if truncated.to_i.positive?
      lines.join("\n")
    end
  end
end
