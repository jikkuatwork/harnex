require_relative "../../test_helper"

class RuntimeControlsTest < Minitest::Test
  def test_run_runtime_budget_forms_and_child_boundary
    [
      ["--max-runtime", "2m", "pi"],
      ["pi", "--max-runtime=120s"]
    ].each do |argv|
      runner = Harnex::Runner.new(argv)
      assert_equal ["pi", []], runner.send(:extract_wrapper_options, argv)
      assert_equal 120.0, runner.instance_variable_get(:@options)[:max_runtime_s]
    end
    argv = ["pi", "--", "--max-runtime", "child-value"]
    runner = Harnex::Runner.new(argv)
    assert_equal ["pi", ["--max-runtime", "child-value"]], runner.send(:extract_wrapper_options, argv)
    assert_nil runner.instance_variable_get(:@options)[:max_runtime_s]
  end

  def test_invalid_runtime_budget_is_rejected_before_launch
    %w[0 -1 NaN Infinity 3fortnights].push("9" * 400).each do |value|
      argv = ["pi", "--max-runtime", value]
      assert_raises(OptionParser::ParseError, value[0, 20]) do
        Harnex::Runner.new(argv).send(:extract_wrapper_options, argv)
      end
    end
  end

  def test_budget_is_passed_to_session
    Dir.mktmpdir("runtime-controls") do |repo|
      argv = ["pi", "--max-runtime", "20s"]
      runner = Harnex::Runner.new(argv)
      runner.send(:extract_wrapper_options, argv)
      runner.instance_variable_get(:@options)[:id] = "runtime-test"
      session = runner.send(:build_session, Harnex::Adapters::Pi.new, repo)
      assert_equal 20.0, session.status_payload[:runtime_budget][:limit_s]
    end
  end

  def test_doctor_advertises_versioned_runtime_capabilities
    doctor = Harnex::Doctor.new(["--adapter", "pi"])
    doctor.stub(:check_pi, { name: "pi", ok: true }) do
      doctor.stub(:retention_payload, { ok: true }) do
        out, = capture_io { assert_equal 0, doctor.run }
        payload = JSON.parse(out)
        assert_equal Harnex::VERSION, payload["harnex_version"]
        assert_equal 1, payload.dig("capabilities", "runtime_budget")
        assert_equal 1, payload.dig("capabilities", "work_activity")
        assert_equal 1, payload.dig("capabilities", "stop_provenance")
      end
    end
  end

  def test_stop_cli_sends_typed_provenance
    captured = nil
    http = Object.new
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:body) { '{"ok":true}' }
    http.define_singleton_method(:request) do |request|
      captured = JSON.parse(request.body)
      response
    end
    registry = { "host" => "127.0.0.1", "port" => 1 }
    Harnex.stub(:read_registry, registry) do
      Net::HTTP.stub(:start, ->(*_args, **_kwargs, &block) { block.call(http) }) do
        capture_io do
          assert_equal 0, Harnex::Stopper.new(["--id", "x", "--reason", "completion", "--origin", "watch"]).run
        end
      end
    end
    assert_equal({ "reason" => "completion", "origin" => "watch" }, captured)
  end
end
