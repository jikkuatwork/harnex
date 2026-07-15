require_relative "../../test_helper"
require "json"
require "stringio"

class ArtifactReportCommandTest < Minitest::Test
  def test_init_and_validate_emit_machine_readable_results
    Dir.mktmpdir("harnex-artifact-report-command") do |dir|
      path = File.join(dir, "reports", "worker.json")

      out, err = capture_io do
        assert_equal 0, Harnex::ArtifactReportCommand.new(["init", path]).run
      end
      assert_empty err
      initialized = JSON.parse(out)
      assert_equal true, initialized.fetch("ok")
      assert_equal true, initialized.fetch("created")
      assert_equal [], initialized.fetch("diagnostics")
      assert_path_exists path

      out, = capture_io do
        assert_equal 0, Harnex::ArtifactReportCommand.new(["validate", path]).run
      end
      assert_equal true, JSON.parse(out).fetch("ok")

      out, = capture_io do
        assert_equal 1, Harnex::ArtifactReportCommand.new(["validate", path, "--final"]).run
      end
      final = JSON.parse(out)
      assert_equal false, final.fetch("ok")
      assert_equal true, final.fetch("final")
      assert final.fetch("diagnostics").all? { |item| item.keys.sort == %w[code message path] }
    end
  end

  def test_validate_diagnostics_do_not_echo_payload_values
    Dir.mktmpdir("harnex-artifact-report-command") do |dir|
      path = File.join(dir, "worker.json")
      secret = "do-not-echo-this-report-value"
      File.write(path, JSON.generate(
        schema: Harnex::ArtifactReport::SCHEMA,
        outcome: secret
      ))

      out, = capture_io do
        assert_equal 1, Harnex::ArtifactReportCommand.new(["validate", path]).run
      end

      payload = JSON.parse(out)
      assert_equal "$.outcome", payload.fetch("diagnostics").first.fetch("path")
      refute_includes out, secret
    end
  end

  def test_cli_help_lists_artifact_report_command
    assert_includes Harnex::CLI.new([]).send(:usage), "harnex artifact-report init|validate"
    assert_includes Harnex::CLI.new([]).send(:help, "artifact-report"), "--final"
  end
end
