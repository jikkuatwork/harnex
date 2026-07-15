require "json"
require "optparse"

module Harnex
  class OrchestrationCommand
    def self.usage(program_name = "harnex orchestration")
      <<~TEXT
        Usage:
          #{program_name} sample --out PATH --run-id ID --generation-id ID [options]
          #{program_name} report --dispatch PATH --run-id ID [--samples PATH] [--json]

        Sample options:
          --project-id ID
          --queue-id ID
          --session-id ID
          --event NAME                  sample, generation_started, generation_finished, rotation, recovery, or compaction
          --ts ISO8601
          --context-status STATUS       observed, estimated, unsupported, missing, or zero
          --context-tokens N
          --context-window-tokens N
          --context-percent N
          --context-peak-tokens N
          --context-peak-percent N
          --usage-status STATUS         observed, estimated, unsupported, missing, or zero
          --usage-input-tokens N
          --usage-output-tokens N
          --usage-cached-input-tokens N
          --usage-reasoning-tokens N
          --usage-total-tokens N
          --usage-cost-usd N
          --usage-cost-source TEXT
          --tool-calls N
          --compactions N
          --rotation-reason TEXT

        Report options:
          --dispatch PATH               Dispatch summary JSONL
          --samples PATH                External primary sample JSONL
          --run-id ID                   Logical orchestration run id
          --json                        Output the full report JSON
          -h, --help                    Show this help
      TEXT
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      subcommand = @argv.shift
      case subcommand
      when "sample"
        run_sample(@argv)
      when "report"
        run_report(@argv)
      when "-h", "--help", nil
        puts self.class.usage
        0
      else
        raise OptionParser::ParseError, "unknown orchestration subcommand #{subcommand.inspect}"
      end
    end

    private

    def run_sample(argv)
      options = {
        context: {},
        usage: {}
      }
      sample_parser(options).parse!(argv)
      if options.delete(:help)
        puts self.class.usage
        return 0
      end
      path = required_option(options.delete(:out), "--out")
      options["orchestration_run_id"] = required_option(options.delete(:run_id), "--run-id")
      options["generation_id"] = required_option(options.delete(:generation_id), "--generation-id")
      sample = Harnex::Orchestration.append_sample(path, options)
      puts JSON.generate("ok" => true, "path" => path, "sample" => sample)
      0
    end

    def run_report(argv)
      options = { json: false }
      report_parser(options).parse!(argv)
      if options[:help]
        puts self.class.usage
        return 0
      end
      report = Harnex::Orchestration.report(
        dispatch_path: required_option(options[:dispatch], "--dispatch"),
        samples_path: options[:samples],
        run_id: required_option(options[:run_id], "--run-id")
      )
      if options[:json]
        puts JSON.generate(report)
      else
        puts render_report(report)
      end
      0
    end

    def sample_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: harnex orchestration sample --out PATH --run-id ID --generation-id ID [options]"
        opts.on("--out PATH") { |value| options[:out] = value }
        opts.on("--run-id ID") { |value| options[:run_id] = value }
        opts.on("--generation-id ID") { |value| options[:generation_id] = value }
        opts.on("--project-id ID") { |value| options["project_id"] = value }
        opts.on("--queue-id ID") { |value| options["queue_id"] = value }
        opts.on("--session-id ID") { |value| options["session_id"] = value }
        opts.on("--event NAME") { |value| options["event"] = value }
        opts.on("--ts ISO8601") { |value| options["ts"] = value }
        opts.on("--context-status STATUS") { |value| options[:context]["status"] = value }
        opts.on("--context-tokens N") { |value| options[:context]["terminal_tokens"] = value }
        opts.on("--context-window-tokens N") { |value| options[:context]["window_tokens"] = value }
        opts.on("--context-percent N") { |value| options[:context]["terminal_percent"] = value }
        opts.on("--context-peak-tokens N") { |value| options[:context]["peak_tokens"] = value }
        opts.on("--context-peak-percent N") { |value| options[:context]["peak_percent"] = value }
        opts.on("--usage-status STATUS") { |value| options[:usage]["status"] = value }
        opts.on("--usage-input-tokens N") { |value| options[:usage]["input_tokens"] = value }
        opts.on("--usage-output-tokens N") { |value| options[:usage]["output_tokens"] = value }
        opts.on("--usage-cached-input-tokens N") { |value| options[:usage]["cached_input_tokens"] = value }
        opts.on("--usage-reasoning-tokens N") { |value| options[:usage]["reasoning_tokens"] = value }
        opts.on("--usage-total-tokens N") { |value| options[:usage]["total_tokens"] = value }
        opts.on("--usage-cost-usd N") { |value| options[:usage]["cost_usd"] = value }
        opts.on("--usage-cost-source TEXT") { |value| options[:usage]["cost_source"] = value }
        opts.on("--tool-calls N") { |value| options["tool_calls"] = value }
        opts.on("--compactions N") { |value| options["compactions"] = value }
        opts.on("--rotation-reason TEXT") { |value| options["rotation_reason"] = value }
        opts.on("-h", "--help") { options[:help] = true }
      end
    end

    def report_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: harnex orchestration report --dispatch PATH --run-id ID [options]"
        opts.on("--dispatch PATH") { |value| options[:dispatch] = value }
        opts.on("--samples PATH") { |value| options[:samples] = value }
        opts.on("--run-id ID") { |value| options[:run_id] = value }
        opts.on("--json") { options[:json] = true }
        opts.on("-h", "--help") { options[:help] = true }
      end
    end

    def required_option(value, name)
      text = value.to_s.strip
      raise OptionParser::MissingArgument, name if text.empty?

      text
    end

    def render_report(report)
      primary = report.fetch("primary")
      workers = report.fetch("workers")
      ratios = report.fetch("ratios")
      [
        "Run: #{report.fetch('orchestration_run_id')}",
        "Primary: generations=#{primary.fetch('generation_count')} usage=#{primary.dig('usage', 'status')} total_tokens=#{format_value(primary.dig('usage', 'total_tokens'))} peak_context=#{format_value(primary.dig('context', 'peak_tokens'))} tool_calls=#{primary.fetch('tool_calls')}",
        "Workers: dispatches=#{workers.fetch('dispatches')} usage=#{workers.dig('usage', 'status')} active_s=#{workers.fetch('active_s')} accepted=#{workers.dig('outcomes', 'accepted')} rejected=#{workers.dig('outcomes', 'rejected')} blocked=#{workers.dig('outcomes', 'blocked')} unknown=#{workers.dig('outcomes', 'unknown')}",
        "Ratios: primary_tokens_per_accepted_entry=#{format_value(ratios.fetch('primary_total_tokens_per_accepted_entry'))} primary_tool_calls_per_accepted_entry=#{format_value(ratios.fetch('primary_tool_calls_per_accepted_entry'))}"
      ].join("\n")
    end

    def format_value(value)
      value.nil? ? "-" : value
    end
  end
end
