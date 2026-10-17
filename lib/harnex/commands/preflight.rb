require "json"
require "net/http"
require "open3"
require "securerandom"
require "shellwords"
require "tmpdir"
require "uri"

module Harnex
  # `harnex preflight ADAPTER`: one tiny end-to-end dispatch that proves an
  # adapter can work in a named cwd before an unattended run launches (#56).
  # It drives the real `harnex run` path in a child process and judges the
  # result from harness-observed evidence: the registry, the files the worker
  # had to write, and the dispatch row's receipt fields. Never worker prose.
  class Preflight
    SCHEMA = "harnex.preflight.v1"
    DEFAULT_TIMEOUT_S = 180.0
    DEFAULT_REGISTRATION_TIMEOUT_S = 30.0
    PERMISSION_GRACE_S = 15.0
    POLL_INTERVAL_S = 0.5
    ROW_GRACE_S = 10.0
    STATUSES = %w[pass fail unsupported skipped].freeze
    CHECKS = %w[
      registration boot permission task_read workspace_write command_exit
      receipt claims completion stop
    ].freeze
    # The first failing check names the verdict's failure class; process
    # classes reuse the #57 outcome vocabulary where one applies.
    FAILURE_CLASSES = {
      "registration" => "registration_timeout",
      "boot" => "boot_failure",
      "permission" => "permission_prompt",
      "task_read" => "task_read_denied",
      "workspace_write" => "workspace_write_denied",
      "command_exit" => "command_unobserved",
      "receipt" => "receipt_missing",
      "claims" => "claims_missing",
      "completion" => "completion_missing",
      "stop" => "timeout",
      "commit" => "commit_failed"
    }.freeze

    def self.usage(program_name = "harnex preflight")
      <<~TEXT
        Usage: #{program_name} ADAPTER [options] [--] [cli-args...]

        Runs one tiny end-to-end dispatch through `harnex run ADAPTER` and prints
        a JSON verdict. Exits 0 only when every required check passes.

        Options:
          --cwd DIR           Workspace to dispatch in (default: current directory)
          --task-root DIR     Where the pinned task file is written (default: #{Dir.tmpdir})
          --commit-check      Also prove a commit in a throwaway scratch repo
                              (never the caller's repo)
          --timeout DUR       Per-dispatch deadline (default: #{DEFAULT_TIMEOUT_S.to_i}s)
          --registration-timeout DUR
                              Registration deadline (default: #{DEFAULT_REGISTRATION_TIMEOUT_S.to_i}s)
          --model NAME        Passed to `harnex run --model`
          --effort LEVEL      Passed to `harnex run --effort`
          --legacy-pty        (codex only) Probe the legacy PTY adapter
          --id ID             Dispatch id (default: pf-<adapter>-<random>)
          -h, --help          Show this help

        Checks: #{CHECKS.first(5).join(', ')},
          #{CHECKS.drop(5).join(', ')}, plus commit with --commit-check.
        Each is pass, fail, unsupported (the adapter cannot expose that evidence,
        e.g. PTY command exits), or skipped. The verdict also reports usage, cost
        and context telemetry provenance for the adapter.

        Common patterns:
          #{program_name} pi --cwd ~/repo -- --no-approve
          #{program_name} codex --cwd ~/repo --commit-check -- -c model=gpt-5.5
          #{program_name} pi --cwd ~/repo && harnex run pi --cwd ~/repo --context "..."

        Gotchas:
          Preflight spends one real model turn (two with --commit-check).
          Its dispatch row lands in history with phase=preflight and is excluded
          from orchestration report rollups unless --include-preflight is passed.
          Run it for the chosen adapter and one declared fallback before an
          unattended queue; both must sit inside your dispatch-model policy.
          It proves plumbing (boot, files, commands, receipts), not model quality.
      TEXT
    end

    def initialize(argv, out: $stdout, err: $stderr, harnex_command: nil)
      @argv = argv.dup
      @out = out
      @err = err
      @harnex_command = harnex_command || [Gem.ruby, File.expand_path("../../../bin/harnex", __dir__)]
      @options = {
        cwd: nil,
        task_root: nil,
        commit_check: false,
        timeout_s: DEFAULT_TIMEOUT_S,
        registration_timeout_s: DEFAULT_REGISTRATION_TIMEOUT_S,
        model: nil,
        effort: nil,
        legacy_pty: false,
        id: nil,
        help: false
      }
    end

    def run
      adapter, child_args = parse(@argv)
      if @options[:help]
        @out.puts self.class.usage
        return 0
      end
      raise OptionParser::MissingArgument, "ADAPTER" if adapter.nil?

      verdict = execute(adapter, child_args)
      @out.puts JSON.generate(verdict)
      verdict["ok"] ? 0 : 1
    end

    private

    def execute(adapter, child_args)
      started = monotonic
      cwd = File.expand_path(@options[:cwd] || Dir.pwd)
      raise OptionParser::InvalidArgument, "--cwd #{cwd} is not a directory" unless File.directory?(cwd)

      task_root = File.expand_path(@options[:task_root] || Dir.tmpdir)
      id = Harnex.normalize_id(@options[:id] || "pf-#{adapter.gsub(/[^a-z0-9]+/i, '-')}-#{SecureRandom.hex(3)}")
      probe = run_probe(adapter, child_args, id: id, cwd: cwd, task_root: task_root, commit: false)
      checks = probe.fetch(:checks)
      if @options[:commit_check]
        checks << if checks.any? { |check| check["status"] == "fail" }
                    check("commit", "skipped", "workspace probe failed; commit probe not attempted")
                  else
                    commit_check(adapter, child_args, id: "#{id}-commit", task_root: task_root)
                  end
      end

      failed = checks.find { |item| item["status"] == "fail" }
      failure = failed && FAILURE_CLASSES.fetch(failed["name"], failed["name"])
      # A failed or missing completion is named by the #57 outcome class.
      failure = probe.dig(:row, "outcome", "class") || failure if failed && failed["name"] == "completion"
      {
        "schema" => SCHEMA,
        "ok" => failed.nil?,
        "failure" => failure,
        "adapter" => adapter,
        "id" => id,
        "cwd" => cwd,
        "task_root" => task_root,
        "checks" => checks,
        "outcome_class" => probe.dig(:row, "outcome", "class"),
        "telemetry" => telemetry_capability(probe[:row]),
        "dispatch_history_path" => Harnex::DispatchHistory.path_for(cwd),
        "duration_s" => (monotonic - started).round(1)
      }
    end

    def commit_check(adapter, child_args, id:, task_root:)
      scratch = Dir.mktmpdir("harnex-preflight-commit")
      git(scratch, "init", "-q")
      git(scratch, "-c", "user.name=harnex", "-c", "user.email=harnex@localhost",
          "commit", "-q", "--allow-empty", "-m", "harnex preflight base")
      base = git(scratch, "rev-parse", "HEAD")
      probe = run_probe(adapter, child_args, id: id, cwd: scratch, task_root: task_root, commit: true)
      head = git(scratch, "rev-parse", "HEAD")
      committed = git(scratch, "show", "#{head}:preflight.txt").strip if head != base
      if head == base
        failed = probe[:checks].find { |item| item["status"] == "fail" }
        check("commit", "fail", "no commit in scratch repo#{failed ? " (#{failed['name']}: #{failed['detail']})" : ''}")
      elsif committed == probe[:token]
        check("commit", "pass", "scratch repo advanced to #{head[0, 12]}")
      else
        check("commit", "fail", "commit #{head[0, 12]} does not carry the task token")
      end
    rescue StandardError => e
      check("commit", "fail", "commit probe error: #{e.class}: #{e.message}")
    ensure
      FileUtils.rm_rf(scratch) if scratch
    end

    def run_probe(adapter, child_args, id:, cwd:, task_root:, commit:)
      token = "harnex-preflight-token-#{SecureRandom.hex(6)}"
      gate = "echo harnex-preflight-#{SecureRandom.hex(4)}"
      task_path = File.join(task_root, "harnex-preflight-#{id}.md")
      out_path = commit ? File.join(cwd, "preflight.txt") : File.join(cwd, ".harnex", "preflight", "#{id}.txt")
      FileUtils.mkdir_p(task_root)
      File.write(task_path, "#{token}\n")

      launch = launch(adapter, child_args, id: id, cwd: cwd,
                      prompt: prompt(id, task_path, out_path, gate, commit: commit), gate: gate)
      watch = if launch[:ok]
                watch_session(id, cwd)
              else
                # A late registration must not leave an orphan worker behind.
                stop_session(id, cwd) if launch[:launched]
                {}
              end
      row = launch[:ok] || launch[:launched] ? wait_for_row(id, cwd) : nil
      checks = evaluate(launch, watch, row, token: token, out_path: out_path)
      { checks: checks, row: row, token: token }
    ensure
      FileUtils.rm_f(task_path) if task_path
      unless commit || out_path.nil?
        FileUtils.rm_f(out_path)
        preflight_dir = File.dirname(out_path)
        Dir.rmdir(preflight_dir) if File.directory?(preflight_dir) && Dir.empty?(preflight_dir)
      end
    end

    def prompt(id, task_path, out_path, gate, commit:)
      claims = %(printf '{"claims":{"summary":"preflight #{id} ok","verdict":"pass"}}' > "$HARNEX_ARTIFACT_CLAIMS_PATH")
      steps = [
        "Read the task file: #{task_path}",
        "Write exactly the token from that file, and nothing else, to: #{out_path}",
        "Run this exact shell command: #{gate}"
      ]
      steps << "Run this exact shell command: git add preflight.txt && git commit -q -m harnex-preflight" if commit
      steps << "Run this exact shell command: #{claims}"
      steps << "Reply with the single word DONE."
      lines = ["Harnex preflight check #{id}. This is a plumbing test: follow these steps exactly, in order, and do nothing else."]
      steps.each_with_index { |step, index| lines << "#{index + 1}. #{step}" }
      lines.join("\n")
    end

    def launch(adapter, child_args, id:, cwd:, prompt:, gate:)
      argv = @harnex_command + [
        "run", adapter, "--detach", "--id", id, "--cwd", cwd,
        "--description", "harnex preflight",
        "--context", prompt, "--auto-stop", "--final-gate", gate,
        "--phase", "preflight",
        "--timeout", @options[:registration_timeout_s].to_s
      ]
      argv += ["--model", @options[:model]] if @options[:model]
      argv += ["--effort", @options[:effort]] if @options[:effort]
      argv << "--legacy-pty" if @options[:legacy_pty]
      argv += ["--"] + child_args unless child_args.empty?
      stdout, stderr, status = Open3.capture3(*argv, chdir: cwd)
      payload = begin
        JSON.parse(stdout.lines.last.to_s)
      rescue JSON::ParserError
        {}
      end
      {
        ok: status.success? && payload["ok"] == true,
        # A registration timeout can still leave a live or finished session.
        launched: stderr.include?("did not register"),
        payload: payload,
        stderr: stderr.strip.lines.last(3).join.strip,
        pid: payload["pid"]
      }
    end

    # Polls until the session's registry disappears (teardown done) or the
    # deadline passes. A prompt the adapter reports as blocking (trust or
    # confirmation) that persists past PERMISSION_GRACE_S fails fast.
    def watch_session(id, cwd)
      deadline = monotonic + @options[:timeout_s]
      blocked_since = nil
      result = { registered: true, alive_at_registration: nil }
      first = true
      loop do
        registry = Harnex.read_registry(cwd, id)
        return result.merge(exited: true) unless registry

        if first
          result[:alive_at_registration] = Harnex.alive_pid?(registry["pid"])
          first = false
        end
        state = live_agent_state(registry)
        if state == "blocked"
          blocked_since ||= monotonic
          if monotonic - blocked_since >= PERMISSION_GRACE_S
            stop_session(id, cwd)
            return result.merge(blocked: true, exited: wait_registry_gone(id, cwd))
          end
        else
          blocked_since = nil
        end
        if monotonic >= deadline
          stop_session(id, cwd)
          return result.merge(timed_out: true, exited: wait_registry_gone(id, cwd))
        end
        sleep POLL_INTERVAL_S
      end
    end

    def live_agent_state(registry)
      uri = URI("http://#{registry['host']}:#{registry['port']}/status")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{registry['token']}" if registry["token"]
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) { |http| http.request(request) }
      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)["agent_state"]
    rescue StandardError
      nil
    end

    def stop_session(id, cwd)
      Open3.capture3(*@harnex_command, "stop", "--id", id, "--repo", cwd, chdir: cwd)
    rescue StandardError
      nil
    end

    def wait_registry_gone(id, cwd)
      deadline = monotonic + ROW_GRACE_S
      sleep POLL_INTERVAL_S while Harnex.read_registry(cwd, id) && monotonic < deadline
      Harnex.read_registry(cwd, id).nil?
    end

    def wait_for_row(id, cwd)
      path = Harnex::DispatchHistory.path_for(cwd)
      deadline = monotonic + ROW_GRACE_S
      loop do
        row = last_end_row(path, id)
        return row if row || monotonic >= deadline

        sleep POLL_INTERVAL_S
      end
    end

    def last_end_row(path, id)
      return nil unless File.file?(path)

      File.readlines(path).reverse_each do |line|
        row = JSON.parse(line)
        return row if row.is_a?(Hash) && row["record_type"] == "dispatch_end" && row["id"] == id
      rescue JSON::ParserError
        next
      end
      nil
    end

    def evaluate(launch, watch, row, token:, out_path:)
      checks = []
      outcome_class = row&.dig("outcome", "class")
      unless launch[:ok]
        boot_failed = outcome_class == "boot_failure"
        checks << check("registration", boot_failed ? "skipped" : "fail",
                        launch[:stderr].empty? ? "harnex run failed before registration" : launch[:stderr])
        checks << check("boot", boot_failed ? "fail" : "skipped",
                        boot_failed ? "session died before its first turn" : "not reached")
        (CHECKS - %w[registration boot]).each { |name| checks << check(name, "skipped", "not reached") }
        return checks
      end

      checks << check("registration", "pass", "registered as #{launch.dig(:payload, 'mode')} pid #{launch[:pid]}")
      checks << if watch[:alive_at_registration] == false || outcome_class == "boot_failure"
                  check("boot", "fail", "session died before its first turn (#{outcome_class || 'no row'})")
                else
                  check("boot", "pass", "session alive after registration")
                end
      checks << if watch[:blocked] || outcome_class == "permission_prompt"
                  check("permission", "fail", "adapter stayed on a trust/confirmation prompt")
                else
                  check("permission", "pass", "no blocking prompt observed")
                end

      written = File.file?(out_path) ? File.read(out_path).strip : nil
      if turn_failed_before_work?(row, written)
        reason = "not reached: the turn failed before doing any work"
        %w[task_read workspace_write command_exit receipt claims].each { |name| checks << check(name, "skipped", reason) }
        checks << check("completion", "fail", "turn failed: #{redact(row.dig('actual', 'last_error')) || row.dig('outcome', 'class')}")
        checks << stop_check(watch, row, expected: "failure")
        return checks
      end

      checks << if written.nil?
                  check("task_read", "skipped", "no output file to compare")
                elsif written == token
                  check("task_read", "pass", "output carries the task token")
                else
                  check("task_read", "fail", "output does not carry the task token (task file unreadable?)")
                end
      checks << if written.nil?
                  check("workspace_write", "fail", "#{out_path} was not written")
                else
                  check("workspace_write", "pass", "wrote #{out_path}")
                end
      checks << command_check(row)
      checks << receipt_check(row)
      checks << claims_check(row)
      checks << completion_check(row)
      checks << stop_check(watch, row)
      checks
    end

    def command_check(row)
      return check("command_exit", "fail", "no dispatch row") unless row

      gates = row.dig("validation", "final_gates") || {}
      observation = row.dig("observed", "command_observation")
      case gates["status"]
      when "pass" then check("command_exit", "pass", "gate command exit observed as 0")
      when "fail" then check("command_exit", "fail", "gate command observed with a nonzero exit")
      else
        if observation == "unsupported"
          check("command_exit", "unsupported", "adapter does not expose command exits")
        else
          check("command_exit", "fail", "gate command not observed (command_observation=#{observation || 'none'})")
        end
      end
    end

    def receipt_check(row)
      return check("receipt", "fail", "no dispatch row") unless row

      report = row["artifact_report"] || {}
      if report["ingest_status"] != "ok" || report["author"] != "harnex"
        check("receipt", "fail", "no harness receipt ingested (#{report['ingest_status'] || 'missing'})")
      elsif %w[accepted no_change].include?(row.dig("outcome", "status"))
        check("receipt", "pass", "harness receipt #{row.dig('outcome', 'status')}")
      else
        check("receipt", "fail", "harness receipt #{row.dig('outcome', 'status') || 'unknown'}")
      end
    end

    def claims_check(row)
      summary = row&.dig("claims", "summary").to_s
      if summary.include?("preflight")
        check("claims", "pass", "worker claims ingested")
      else
        check("claims", "fail", "worker claims not ingested from HARNEX_ARTIFACT_CLAIMS_PATH")
      end
    end

    def completion_check(row)
      return check("completion", "fail", "no dispatch row") unless row

      if row["terminal_event"] == "task_complete"
        check("completion", "pass", "task_complete (#{row.dig('outcome', 'class')})")
      else
        check("completion", "fail", "terminal #{row['terminal_event'] || 'none'} (#{row.dig('outcome', 'class') || 'unknown'})")
      end
    end

    # expected: "failure" when the turn already failed; then a clean exit
    # path only proves teardown, and stop passes on that alone.
    def stop_check(watch, row, expected: "success")
      return check("stop", "fail", "did not finish within #{@options[:timeout_s].round}s") if watch[:timed_out]
      return check("stop", "fail", "session did not stop cleanly") unless watch[:exited] && row

      exit_reason = row.dig("actual", "exit")
      if exit_reason == expected
        check("stop", "pass", expected == "success" ? "auto-stop exited cleanly" : "session torn down after the failed turn")
      else
        check("stop", "fail", "exit #{exit_reason || 'unknown'}")
      end
    end

    # A provider/auth/model error fails the turn before any tool runs. Report
    # that root cause instead of blaming the workspace or the receipt.
    def turn_failed_before_work?(row, written)
      return false unless row && row["terminal_event"] == "task_failed"

      written.nil? && Array(row.dig("observed", "commands")).empty? && row.dig("actual", "tool_calls").to_i.zero?
    end

    def redact(text)
      return nil if text.nil?

      text.to_s.gsub(/\b(sk|rk|pk)-[A-Za-z0-9_*\-]{4,}/, "\\1-[redacted]").gsub(/Bearer\s+\S+/, "Bearer [redacted]")[0, 240]
    end

    # usage/cost/context provenance from the dispatch row; never absent.
    def telemetry_capability(row)
      return { "usage" => "unavailable", "cost" => "unavailable", "context" => "unavailable" } unless row

      usage = row["usage"] || {}
      cost = if usage["cost_usd"].nil?
               "unsupported"
             elsif usage["cost_source"] == "provider_reported"
               "observed"
             else
               "estimated"
             end
      {
        "usage" => usage["status"] || "missing",
        "cost" => cost,
        "cost_source" => usage["cost_source"],
        "context" => row.dig("context", "status") || "missing"
      }
    end

    def check(name, status, detail)
      { "name" => name, "status" => status, "detail" => detail.to_s }
    end

    def git(dir, *args)
      stdout, stderr, status = Open3.capture3("git", "-C", dir, *args)
      raise "git #{args.first} failed: #{stderr.strip}" unless status.success?

      stdout.strip
    end

    def parse(argv)
      adapter = nil
      child_args = []
      index = 0
      while index < argv.length
        arg = argv[index]
        case arg
        when "--"
          child_args = argv[(index + 1)..] || []
          break
        when "-h", "--help" then @options[:help] = true
        when "--cwd" then @options[:cwd] = value(argv, index += 1, arg)
        when "--task-root" then @options[:task_root] = value(argv, index += 1, arg)
        when "--commit-check" then @options[:commit_check] = true
        when "--timeout"
          @options[:timeout_s] = Harnex.parse_duration_seconds(value(argv, index += 1, arg), option_name: arg)
        when "--registration-timeout"
          @options[:registration_timeout_s] = Harnex.parse_duration_seconds(value(argv, index += 1, arg), option_name: arg)
        when "--model" then @options[:model] = value(argv, index += 1, arg)
        when "--effort" then @options[:effort] = value(argv, index += 1, arg)
        when "--legacy-pty" then @options[:legacy_pty] = true
        when "--id" then @options[:id] = value(argv, index += 1, arg)
        else
          raise OptionParser::InvalidOption, arg if arg.start_with?("-")
          raise OptionParser::NeedlessArgument, arg if adapter

          adapter = arg
        end
        index += 1
      end
      [adapter, child_args]
    end

    def value(argv, index, name)
      text = argv[index]
      raise OptionParser::MissingArgument, name if text.nil? || text.start_with?("-")

      text
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
