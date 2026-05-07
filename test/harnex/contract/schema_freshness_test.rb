require_relative "../../test_helper"
require "json"
require "open3"
require "tmpdir"

# Phase 6 of plan 29 — schema drift gate (#30).
#
# Re-runs `codex app-server generate-json-schema` and compares each
# fixture in test/fixtures/codex_schema/ against the freshly-generated
# equivalent. Fails when Codex's schema for a type harnex has adopted
# changes shape; passes silently when only Codex schemas harnex
# doesn't ship fixtures for changed.
#
# Skips cleanly if codex CLI is not on PATH (e.g. CI without codex
# installed) or HARNEX_SKIP_SCHEMA_DRIFT=1 is set. Comparison is
# parse-then-compare so key-order changes alone never trip the gate.
class SchemaFreshnessTest < Minitest::Test
  FIXTURE_DIR = File.expand_path("../../fixtures/codex_schema", __dir__)

  def setup
    skip("HARNEX_SKIP_SCHEMA_DRIFT=1") if ENV["HARNEX_SKIP_SCHEMA_DRIFT"] == "1"
    skip("codex CLI not on PATH") unless system("which codex > /dev/null 2>&1")
  end

  def test_shipped_fixtures_match_freshly_generated_schema
    Dir.mktmpdir("harnex-codex-schema") do |out_dir|
      output, status = Open3.capture2e(
        "codex", "app-server", "generate-json-schema", "--out", out_dir
      )
      unless status.success?
        flunk("codex app-server generate-json-schema failed (exit #{status.exitstatus}):\n#{output}")
      end

      messages = shipped_fixtures.filter_map { |rel| drift_message_for(rel, out_dir) }
      assert_empty messages, messages.join("\n")
    end
  end

  private

  def shipped_fixtures
    Dir.glob("**/*.json", base: FIXTURE_DIR).sort
  end

  def drift_message_for(rel, fresh_dir)
    shipped_path = File.join(FIXTURE_DIR, rel)
    fresh_path = File.join(fresh_dir, rel)

    unless File.exist?(fresh_path)
      return <<~MSG
        Schema drift detected in #{rel}.

        Codex no longer emits this schema. Either remove the fixture
        from test/fixtures/codex_schema/ or update harnex to use the
        replacement type.
      MSG
    end

    return nil if JSON.parse(File.read(shipped_path)) == JSON.parse(File.read(fresh_path))

    <<~MSG
      Schema drift detected in #{rel}.

      Codex's schema for this type has changed since the fixture was
      captured. Refresh the fixture:

          codex app-server generate-json-schema --out /tmp/codex-schema
          cp /tmp/codex-schema/#{rel} test/fixtures/codex_schema/#{rel}

      Then re-run the suite. If the change requires harnex changes, file
      an issue and patch the adapter.
    MSG
  end
end
