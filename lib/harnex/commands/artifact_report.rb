require "json"
require "optparse"

module Harnex
  class ArtifactReportCommand
    def self.usage(program_name = "harnex artifact-report")
      <<~TEXT
        Usage:
          #{program_name} init PATH [--force]
          #{program_name} validate PATH [--final]

        Commands:
          init       Write a legacy/manual harnex.artifact_report.v1 skeleton
          validate   Validate a harness receipt or legacy document without printing data

        Options:
          --final    Require an accepted/no_change final harness receipt, or the
                     legacy passing-proof contract
          --force    Replace an existing file during init
          -h, --help Show this help

        Normal `harnex run` sessions generate their own receipt; workers do not
        need `init`. Both commands print machine-readable JSON. `validate` exits
        0 only when the requested contract is satisfied; diagnostics contain
        field paths and shape errors, never report payloads or transcripts.
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      command = @argv.shift
      case command
      when "init"
        run_init(@argv)
      when "validate"
        run_validate(@argv)
      when nil, "help", "-h", "--help"
        puts self.class.usage
        0
      else
        raise OptionParser::ParseError, "unknown artifact-report command #{command.inspect}"
      end
    end

    private

    def run_init(argv)
      options = { force: false, help: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: harnex artifact-report init PATH [--force]"
        opts.on("--force", "Replace an existing report") { options[:force] = true }
        opts.on("-h", "--help", "Show help") { options[:help] = true }
      end
      parser.parse!(argv)
      return print_help if options[:help]

      path = exactly_one_path!(argv, parser)
      report_path = ArtifactReport.initialize_file(path, force: options[:force])
      result = ArtifactReport.validate(report_path)
      puts JSON.generate(result.public_payload(final: false).merge("created" => true))
      result.ok ? 0 : 1
    end

    def run_validate(argv)
      options = { final: false, help: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: harnex artifact-report validate PATH [--final]"
        opts.on("--final", "Require accepted final proof") { options[:final] = true }
        opts.on("-h", "--help", "Show help") { options[:help] = true }
      end
      parser.parse!(argv)
      return print_help if options[:help]

      path = exactly_one_path!(argv, parser)
      result = ArtifactReport.validate(path, final: options[:final])
      puts JSON.generate(result.public_payload(final: options[:final]))
      result.ok ? 0 : 1
    end

    def exactly_one_path!(argv, parser)
      raise OptionParser::MissingArgument, "PATH" if argv.empty?
      raise OptionParser::InvalidArgument, "expected exactly one PATH\n#{parser}" unless argv.length == 1

      argv.first
    end

    def print_help
      puts self.class.usage
      0
    end
  end
end
