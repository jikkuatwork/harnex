require "json"
require "optparse"

module Harnex
  class OrchestrationCommand
    def self.usage(program_name = "harnex orchestration")
      <<~TEXT
        Usage:
          #{program_name} sample --out PATH --run-id ID --generation-id ID [options]
          #{program_name} report --dispatch PATH (--run-id ID | --queue-id ID) [--samples PATH]
              [--failure-budget N] [--budget-unit attempts|families] [--fatal-classes A,B] [--json]

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
          --queue-id ID                 Queue id (alone, or narrowing --run-id)
          --include-preflight           Count `harnex preflight` rows (excluded by default)
          --failure-budget N            Exit 3 once N fatal worker failures are counted
          --budget-unit UNIT            attempts (default) or families (retries joined
                                        by parent attempt/dispatch id count once)
          --fatal-classes A,B           Outcome classes that consume the budget
                                        (default: the classes marked * below)
          --json                        Output the full report JSON
          -h, --help                    Show this help

        Worker outcome classes (dispatch row outcome.class):
          completed   completed_with_proof completed_with_activity
          proof       completed_no_activity* report_missing report_invalid report_rejected
          process     task_failed* provider_capacity* boot_failure* permission_prompt*
                      timeout* process_failed* stopped_by_caller
          fallback    unknown
        The budget is a ledger, not a breaker: enforcement stays with the caller.
        Exit codes: 0 report printed (within budget), 1 error, 2 usage error,
        3 budget breached.
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
      options = { json: false, include_preflight: false }
      report_parser(options).parse!(argv)
      if options[:help]
        puts self.class.usage
        return 0
      end
      if blank?(options[:run_id]) && blank?(options[:queue_id])
        raise OptionParser::MissingArgument, "--run-id or --queue-id"
      end

      dispatch_path = required_option(options[:dispatch], "--dispatch")
      raise ArgumentError, "dispatch file not found: #{dispatch_path}" unless File.file?(dispatch_path)

      report = Harnex::Orchestration.report(
        dispatch_path: dispatch_path,
        samples_path: options[:samples],
        run_id: blank?(options[:run_id]) ? nil : options[:run_id],
        queue_id: blank?(options[:queue_id]) ? nil : options[:queue_id],
        budget: report_budget(options),
        include_preflight: options[:include_preflight]
      )
      if options[:json]
        puts JSON.generate(report)
      else
        puts render_report(report)
      end
      report.dig("failure_budget", "breached") ? BUDGET_BREACHED_EXIT : 0
    end

    # Distinct from 1 (errors) and 2 (usage errors from bin/harnex).
    BUDGET_BREACHED_EXIT = 3

    def report_budget(options)
      if options[:failure_budget].nil?
        if options[:budget_unit] || options[:fatal_classes]
          raise OptionParser::InvalidArgument, "--budget-unit/--fatal-classes need --failure-budget"
        end
        return nil
      end

      limit = Integer(options[:failure_budget], exception: false)
      raise OptionParser::InvalidArgument, "--failure-budget must be a positive integer" unless limit&.positive?

      unit = options[:budget_unit] || "attempts"
      unless Harnex::Orchestration::BUDGET_UNITS.include?(unit)
        raise OptionParser::InvalidArgument, "--budget-unit must be attempts or families"
      end

      fatal = options[:fatal_classes]&.split(",")&.map(&:strip)&.reject(&:empty?)
      unknown = Array(fatal) - Harnex::Session::OUTCOME_CLASSES
      raise OptionParser::InvalidArgument, "unknown outcome class: #{unknown.join(', ')}" unless unknown.empty?
      raise OptionParser::InvalidArgument, "--fatal-classes needs at least one class" if fatal && fatal.empty?

      { limit: limit, unit: unit, fatal_classes: fatal }
    end

    def blank?(value)
      value.to_s.strip.empty?
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
        opts.banner = "Usage: harnex orchestration report --dispatch PATH (--run-id ID | --queue-id ID) [options]"
        opts.on("--dispatch PATH") { |value| options[:dispatch] = value }
        opts.on("--samples PATH") { |value| options[:samples] = value }
        opts.on("--run-id ID") { |value| options[:run_id] = value }
        opts.on("--queue-id ID") { |value| options[:queue_id] = value }
        opts.on("--include-preflight") { options[:include_preflight] = true }
        opts.on("--failure-budget N") { |value| options[:failure_budget] = value }
        opts.on("--budget-unit UNIT") { |value| options[:budget_unit] = value }
        opts.on("--fatal-classes LIST") { |value| options[:fatal_classes] = value }
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
      classes = workers.fetch("outcome_classes")
      lines = [
        "Run: #{format_value(report.fetch('orchestration_run_id'))} queue=#{format_value(report['queue_id'])}",
        "Primary: generations=#{primary.fetch('generation_count')} usage=#{primary.dig('usage', 'status')} total_tokens=#{format_value(primary.dig('usage', 'total_tokens'))} peak_context=#{format_value(primary.dig('context', 'peak_tokens'))} tool_calls=#{primary.fetch('tool_calls')}",
        "Workers: dispatches=#{workers.fetch('dispatches')} usage=#{workers.dig('usage', 'status')} active_s=#{workers.fetch('active_s')} accepted=#{workers.dig('outcomes', 'accepted')} rejected=#{workers.dig('outcomes', 'rejected')} blocked=#{workers.dig('outcomes', 'blocked')} unknown=#{workers.dig('outcomes', 'unknown')}",
        "Outcome classes: #{format_counts(classes.fetch('attempts'))} " \
          "(families=#{classes.fetch('family_count')}: #{format_counts(classes.fetch('families'))})",
        "Ratios: primary_tokens_per_accepted_entry=#{format_value(ratios.fetch('primary_total_tokens_per_accepted_entry'))} primary_tool_calls_per_accepted_entry=#{format_value(ratios.fetch('primary_tool_calls_per_accepted_entry'))}"
      ]
      if (budget = report["failure_budget"])
        verdict = budget.fetch("breached") ? "BREACHED" : "within budget"
        lines << "Failure budget: #{budget.fetch('consumed')}/#{budget.fetch('limit')} #{budget.fetch('unit')} " \
                 "(fatal attempts=#{budget.fetch('fatal_attempts')} families=#{budget.fetch('fatal_families')}) #{verdict}"
      end
      lines.join("\n")
    end

    def format_counts(counts)
      return "-" if counts.empty?

      counts.map { |klass, count| "#{klass}=#{count}" }.join(" ")
    end

    def format_value(value)
      value.nil? ? "-" : value
    end
  end
end
