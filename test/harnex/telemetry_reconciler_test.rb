require "json"
require "open3"
require "rbconfig"

require_relative "../test_helper"

class TelemetryReconcilerTest < Minitest::Test
  BIN = File.expand_path("../../bin/harnex", __dir__)
  REPORT_KEYS = %w[
    schema command status canonical canonical_rows families sources present
    missing conflicts open_starts appended diagnostics diagnostics_truncated
  ].freeze

  # Coverage map:
  # - clean mixed-era canonical assertion: test_assert_canonical_accepts_clean_mixed_era_stream
  # - malformed canonical JSON: test_assert_canonical_rejects_malformed_canonical_json
  # - v2 identity/pairing/open starts: test_assert_canonical_enforces_v2_identity_pairing_and_allows_open_starts
  # - source drift and dry-run no-write: test_source_drift_fails_assert_and_reconcile_dry_run_without_writing
  # - apply and idempotency: test_reconcile_apply_appends_missing_once_and_rerun_is_byte_identical
  # - identity conflict zero-write: test_identity_conflict_blocks_full_batch_without_writing
  # - offset identity: test_equivalent_iso_offsets_deduplicate_legacy_identity
  # - source classification/exclusions: test_directory_sources_exclude_canonical_git_and_symlinks
  # - unrelated JSON and malformed declared telemetry: test_source_classifier_ignores_unrelated_json_but_fails_malformed_declared_telemetry
  # - bounded payload-free JSON: test_json_report_is_bounded_and_never_echoes_payloads
  # - CLI help/errors: test_cli_help_unknown_subcommand_option_conflict_and_required_source_contract

  def test_assert_canonical_accepts_clean_mixed_era_stream
    # seam: cli-subprocess
    Dir.mktmpdir("harnex-telemetry-clean") do |dir|
      canonical = File.join(dir, "dispatch.jsonl")
      write_jsonl(
        canonical,
        v2_start(id: "cx-v2", session_id: "sess-v2", started_at: "2026-08-03T01:00:00Z"),
        v2_end(id: "cx-v2", session_id: "sess-v2", started_at: "2026-08-03T01:00:00Z"),
        legacy_thin(id: "cx-v1", started_at: "2026-08-03T02:00:00Z"),
        legacy_rich(id: "cx-rich", started_at: "2026-08-03T03:00:00Z"),
        { "schema_version" => 0, "note" => "historical object" }
      )

      result = telemetry(dir, "assert-canonical", "--canonical", canonical, "--json")

      assert_report(result, exitstatus: 0, command: "assert-canonical", status: "clean")
    end
  end

  def test_assert_canonical_rejects_malformed_canonical_json
    # seam: cli-subprocess
    Dir.mktmpdir("harnex-telemetry-malformed") do |dir|
      canonical = File.join(dir, "dispatch.jsonl")
      File.write(canonical, "#{JSON.generate(v2_start)}\n{\"not-json\"\n")

      result = telemetry(dir, "assert-canonical", "--canonical", canonical, "--json")

      assert_report(
        result,
        exitstatus: 1,
        command: "assert-canonical",
        status: "corrupt",
        diagnostic: "malformed canonical JSON"
      )
    end
  end

  def test_assert_canonical_enforces_v2_identity_pairing_and_allows_open_starts
    # seam: precondition-pin + cli-subprocess
    Dir.mktmpdir("harnex-telemetry-v2") do |dir|
      open_canonical = File.join(dir, "open.jsonl")
      write_jsonl(open_canonical, v2_start(id: "cx-open", session_id: "sess-open"))

      duplicate_canonical = File.join(dir, "duplicate.jsonl")
      write_jsonl(
        duplicate_canonical,
        v2_start(id: "cx-dupe", session_id: "sess-dupe"),
        v2_start(id: "cx-dupe", session_id: "sess-dupe"),
        v2_end(id: "cx-dupe", session_id: "sess-dupe"),
        v2_end(id: "cx-dupe", session_id: "sess-dupe")
      )

      mismatch_canonical = File.join(dir, "mismatch.jsonl")
      write_jsonl(
        mismatch_canonical,
        v2_start(id: "cx-pair", session_id: "sess-a", started_at: "2026-08-03T01:00:00Z"),
        v2_end(id: "cx-pair", session_id: "sess-b", started_at: "2026-08-03T01:00:00Z")
      )

      open_result = telemetry(dir, "assert-canonical", "--canonical", open_canonical, "--json")
      duplicate_result = telemetry(dir, "assert-canonical", "--canonical", duplicate_canonical, "--json")
      mismatch_result = telemetry(dir, "assert-canonical", "--canonical", mismatch_canonical, "--json")

      assert_report(open_result, exitstatus: 0, command: "assert-canonical", status: "clean", open_starts: 1)
      assert_report(duplicate_result, exitstatus: 1, command: "assert-canonical", status: "corrupt", diagnostic: "duplicate v2 identity")
      assert_report(mismatch_result, exitstatus: 1, command: "assert-canonical", status: "corrupt", diagnostic: "unpaired v2 end")
    end
  end

  def test_source_drift_fails_assert_and_reconcile_dry_run_without_writing
    # seam: behavior-change + cli-subprocess
    Dir.mktmpdir("harnex-telemetry-drift") do |dir|
      canonical = File.join(dir, "dispatch.jsonl")
      source = File.join(dir, "legacy-source.jsonl")
      write_jsonl(canonical, legacy_rich(id: "cx-present", started_at: "2026-08-03T04:00:00Z"))
      write_jsonl(source, legacy_rich(id: "cx-missing", started_at: "2026-08-03T05:00:00Z"))
      before = File.binread(canonical)

      assert_result = telemetry(dir, "assert-canonical", "--canonical", canonical, "--source", source, "--json")
      dry_run = telemetry(dir, "reconcile", "--canonical", canonical, "--source", source, "--json")

      assert_equal before, File.binread(canonical), "dry-run/assert must not mutate canonical bytes"
      assert_report(assert_result, exitstatus: 1, command: "assert-canonical", status: "drift", diagnostic: "missing")
      assert_report(dry_run, exitstatus: 1, command: "reconcile", status: "drift", diagnostic: "missing")
    end
  end

  def test_reconcile_apply_appends_missing_once_and_rerun_is_byte_identical
    # seam: behavior-change + cli-subprocess
    Dir.mktmpdir("harnex-telemetry-apply") do |dir|
      canonical = File.join(dir, "dispatch.jsonl")
      source = File.join(dir, "legacy-source.jsonl")
      missing = legacy_rich(id: "cx-apply", started_at: "2026-08-03T06:00:00Z")
      write_jsonl(canonical, legacy_thin(id: "cx-old", started_at: "2026-08-03T01:00:00Z"))
      write_jsonl(source, missing)

      first = telemetry(dir, "reconcile", "--canonical", canonical, "--source", source, "--apply", "--json")
      after_first = File.binread(canonical)
      second = telemetry(dir, "reconcile", "--canonical", canonical, "--source", source, "--apply", "--json")

      assert_report(first, exitstatus: 0, command: "reconcile", status: "clean", appended: 1)
      assert_includes File.readlines(canonical, chomp: true).map { |line| JSON.parse(line)["meta"]&.fetch("id", nil) }, "cx-apply"
      assert_report(second, exitstatus: 0, command: "reconcile", status: "clean", appended: 0)
      assert_equal after_first, File.binread(canonical), "second apply must be byte-identical"
    end
  end

  def test_identity_conflict_blocks_full_batch_without_writing
    # seam: behavior-change + cli-subprocess
    Dir.mktmpdir("harnex-telemetry-conflict") do |dir|
      canonical = File.join(dir, "dispatch.jsonl")
      source = File.join(dir, "source.jsonl")
      write_jsonl(canonical, legacy_rich(id: "cx-conflict", started_at: "2026-08-03T07:00:00Z", exit_code: 0))
      write_jsonl(
        source,
        legacy_rich(id: "cx-conflict", started_at: "2026-08-03T12:30:00+05:30", exit_code: 1),
        legacy_rich(id: "cx-missing-too", started_at: "2026-08-03T07:30:00Z")
      )
      before = File.binread(canonical)

      result = telemetry(dir, "reconcile", "--canonical", canonical, "--source", source, "--apply", "--json")

      assert_equal before, File.binread(canonical), "any identity conflict must block the full apply batch"
      assert_report(result, exitstatus: 1, command: "reconcile", status: "conflict", diagnostic: "identity conflict")
    end
  end

  def test_equivalent_iso_offsets_deduplicate_legacy_identity
    # seam: behavior-change + cli-subprocess
    Dir.mktmpdir("harnex-telemetry-offset") do |dir|
      canonical = File.join(dir, "dispatch.jsonl")
      source = File.join(dir, "source.jsonl")
      write_jsonl(canonical, legacy_rich(id: "cx-offset", started_at: "2026-08-03T08:00:00Z"))
      write_jsonl(source, legacy_rich(id: "cx-offset", started_at: "2026-08-03T13:30:00+05:30"))
      before = File.binread(canonical)

      result = telemetry(dir, "assert-canonical", "--canonical", canonical, "--source", source, "--json")

      assert_equal before, File.binread(canonical), "equivalent-offset dedupe must not rewrite payload text"
      assert_report(result, exitstatus: 0, command: "assert-canonical", status: "clean", missing: 0, conflicts: 0)
    end
  end

  def test_directory_sources_exclude_canonical_git_and_symlinks
    # seam: cli-subprocess
    Dir.mktmpdir("harnex-telemetry-dir") do |dir|
      source_dir = File.join(dir, "sources")
      FileUtils.mkdir_p(File.join(source_dir, ".git"))
      canonical = File.join(source_dir, "dispatch.jsonl")
      write_jsonl(canonical, legacy_rich(id: "cx-present", started_at: "2026-08-03T09:00:00Z"))
      write_jsonl(File.join(source_dir, "missing.jsonl"), legacy_rich(id: "cx-dir-missing", started_at: "2026-08-03T09:10:00Z"))
      write_jsonl(File.join(source_dir, ".git", "ignored.jsonl"), legacy_rich(id: "cx-git-ignored", started_at: "2026-08-03T09:20:00Z"))
      write_jsonl(File.join(source_dir, "generic.json"), { "meta" => { "id" => "not-telemetry", "started_at" => "2026-08-03T09:25:00Z" }, "actual" => {} })
      File.symlink(File.join(source_dir, "missing.jsonl"), File.join(source_dir, "linked.jsonl"))

      result = telemetry(dir, "reconcile", "--canonical", canonical, "--source", source_dir, "--json")

      assert_report(result, exitstatus: 1, command: "reconcile", status: "drift", missing: 1, diagnostic: "cx-dir-missing")
    end
  end

  def test_source_classifier_ignores_unrelated_json_but_fails_malformed_declared_telemetry
    # seam: precondition-pin + cli-subprocess
    Dir.mktmpdir("harnex-telemetry-classifier") do |dir|
      canonical = File.join(dir, "dispatch.jsonl")
      source_dir = File.join(dir, "sources")
      malformed = File.join(dir, "malformed.jsonl")
      FileUtils.mkdir_p(source_dir)
      write_jsonl(canonical, legacy_rich(id: "cx-present", started_at: "2026-08-03T10:00:00Z"))
      write_jsonl(File.join(source_dir, "generic.json"), {
        "meta" => { "id" => "summary", "started_at" => "2026-08-03T10:05:00Z" },
        "actual" => { "exit" => "success" }
      })
      File.write(malformed, "#{JSON.generate(legacy_rich(id: "cx-malformed", started_at: "2026-08-03T10:10:00Z"))}\n{\"broken\"\n")

      ignored = telemetry(dir, "assert-canonical", "--canonical", canonical, "--source", source_dir, "--json")
      fatal = telemetry(dir, "assert-canonical", "--canonical", canonical, "--source", malformed, "--json")

      assert_report(ignored, exitstatus: 0, command: "assert-canonical", status: "clean", missing: 0, conflicts: 0)
      assert_report(fatal, exitstatus: 1, command: "assert-canonical", status: "corrupt", diagnostic: "malformed source telemetry")
    end
  end

  def test_json_report_is_bounded_and_never_echoes_payloads
    # seam: cli-subprocess
    Dir.mktmpdir("harnex-telemetry-secret") do |dir|
      marker = "UNIQUE-SECRET-MARKER-67"
      canonical = File.join(dir, "dispatch.jsonl")
      source = File.join(dir, "source.jsonl")
      write_jsonl(canonical, legacy_thin(id: "cx-old", started_at: "2026-08-03T11:00:00Z"))
      write_jsonl(source, legacy_rich(id: "cx-secret", started_at: "2026-08-03T11:10:00Z", secret: marker))

      result = telemetry(dir, "reconcile", "--canonical", canonical, "--source", source, "--json")

      refute_includes result.stdout, marker
      refute_includes result.stderr, marker
      assert_report(result, exitstatus: 1, command: "reconcile", status: "drift", diagnostic: "cx-secret", max_diagnostics: 50)
    end
  end

  def test_cli_help_unknown_subcommand_option_conflict_and_required_source_contract
    # seam: cli-subprocess
    Dir.mktmpdir("harnex-telemetry-cli") do |dir|
      canonical = File.join(dir, "dispatch.jsonl")
      write_jsonl(canonical, legacy_thin)

      help = telemetry(dir, "--help")
      unknown = telemetry(dir, "not-a-command")
      conflict = telemetry(dir, "assert-canonical", "--canonical", canonical, "--global")
      missing_source = telemetry(dir, "reconcile", "--canonical", canonical, "--json")

      assert_cli(help, exitstatus: 0, stdout: ["assert-canonical", "reconcile"])
      assert_cli(unknown, exitstatus: 2, stderr: ["unknown telemetry subcommand"])
      assert_cli(conflict, exitstatus: 2, stderr: ["--canonical", "--global", "mutually exclusive"])
      assert_cli(missing_source, exitstatus: 2, stderr: ["reconcile", "--source", "required"])
    end
  end

  private

  Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

  def telemetry(cwd, *args)
    out, err, status = Open3.capture3({ "HARNEX_STATE_DIR" => ENV.fetch("HARNEX_STATE_DIR") }, RbConfig.ruby, BIN, "telemetry", *args, chdir: cwd)
    Result.new(stdout: out, stderr: err, status: status)
  end

  def assert_report(result, exitstatus:, command:, status:, diagnostic: nil, max_diagnostics: nil, **fields)
    failures = []
    failures << "expected exit #{exitstatus}, got #{result.status.exitstatus}; stderr=#{result.stderr.inspect}" unless result.status.exitstatus == exitstatus
    report = parse_report(result.stdout, failures)

    if report
      REPORT_KEYS.each { |key| failures << "missing report key #{key.inspect}" unless report.key?(key) }
      failures << "expected schema harnex.telemetry_reconcile.v1, got #{report['schema'].inspect}" unless report["schema"] == "harnex.telemetry_reconcile.v1"
      failures << "expected command #{command.inspect}, got #{report['command'].inspect}" unless report["command"] == command
      failures << "expected status #{status.inspect}, got #{report['status'].inspect}" unless report["status"] == status
      fields.each do |key, value|
        failures << "expected #{key}=#{value.inspect}, got #{report[key.to_s].inspect}" unless report[key.to_s] == value
      end
      if diagnostic
        text = JSON.generate(report.fetch("diagnostics", []))
        failures << "expected diagnostic including #{diagnostic.inspect}, got #{text}" unless text.include?(diagnostic)
      end
      if max_diagnostics
        diagnostics = report.fetch("diagnostics", [])
        failures << "expected diagnostics to be bounded at #{max_diagnostics}, got #{diagnostics.size}" unless diagnostics.size <= max_diagnostics
      end
    end

    assert_empty failures, failures.join("\n")
  end

  def assert_cli(result, exitstatus:, stdout: [], stderr: [])
    failures = []
    failures << "expected exit #{exitstatus}, got #{result.status.exitstatus}" unless result.status.exitstatus == exitstatus
    stdout.each { |text| failures << "stdout missing #{text.inspect}: #{result.stdout.inspect}" unless result.stdout.include?(text) }
    stderr.each { |text| failures << "stderr missing #{text.inspect}: #{result.stderr.inspect}" unless result.stderr.include?(text) }
    assert_empty failures, failures.join("\n")
  end

  def parse_report(stdout, failures)
    report = JSON.parse(stdout)
    return report if report.is_a?(Hash)

    failures << "stdout must be one JSON object, got #{report.class}"
    nil
  rescue JSON::ParserError
    failures << "stdout must be one JSON object, got #{stdout.inspect}"
    nil
  end

  def write_jsonl(path, *records)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, records.map { |record| JSON.generate(record) }.join("\n") + "\n")
  end

  def v2_start(id: "cx-v2", session_id: "sess-v2", started_at: "2026-08-03T01:00:00Z")
    {
      "schema_version" => 2,
      "record_type" => "dispatch_start",
      "id" => id,
      "session_id" => session_id,
      "pid" => 12_345,
      "host" => "test-host",
      "cli" => "codex",
      "started_at" => started_at,
      "repo_root" => "/tmp/repo",
      "meta" => {}
    }
  end

  def v2_end(id: "cx-v2", session_id: "sess-v2", started_at: "2026-08-03T01:00:00Z", exit_code: 0, secret: nil)
    legacy_rich(id: id, started_at: started_at, exit_code: exit_code, secret: secret).merge(
      "schema_version" => 2,
      "record_type" => "dispatch_end",
      "session_id" => session_id,
      "id" => id,
      "started_at" => started_at,
      "status" => exit_code.zero? ? "completed" : "failed",
      "terminal_event" => exit_code.zero? ? "task_complete" : "task_failed"
    )
  end

  def legacy_thin(id: "cx-v1", started_at: "2026-08-03T00:00:00Z")
    {
      "schema_version" => 1,
      "id" => id,
      "started_at" => started_at,
      "ended_at" => started_at,
      "duration_s" => 0,
      "status" => "completed",
      "terminal_event" => "task_complete",
      "meta" => {}
    }
  end

  def legacy_rich(id: "cx-rich", started_at: "2026-08-03T00:00:00Z", exit_code: 0, secret: nil)
    actual = { "exit" => exit_code.zero? ? "success" : "failure", "exit_code" => exit_code }
    actual["prompt"] = secret if secret
    {
      "meta" => { "id" => id, "started_at" => started_at, "claim" => secret }.compact,
      "predicted" => {},
      "actual" => actual,
      "agent" => { "cli" => "codex" },
      "usage" => { "status" => "unsupported" },
      "context" => { "status" => "unsupported" },
      "attribution" => { "status" => "unattributed" },
      "outcome" => { "status" => "changed" },
      "attempt" => { "run_id" => id },
      "reliability" => { "recovered" => false }
    }
  end
end
