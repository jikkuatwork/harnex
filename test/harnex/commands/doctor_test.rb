require_relative "../../test_helper"
require "json"

class DoctorTest < Minitest::Test
  def test_help
    assert_output(/Usage: harnex doctor/) { Harnex::Doctor.new(["--help"]).run }
  end

  def test_parse_version_from_canonical_output
    doctor = Harnex::Doctor.new
    assert_equal Gem::Version.new("0.128.0"),
      doctor.send(:parse_version, "codex-cli 0.128.0\n")
  end

  def test_parse_version_returns_nil_for_garbage
    doctor = Harnex::Doctor.new
    assert_nil doctor.send(:parse_version, "no version here")
  end

  def test_min_version_constant
    assert_equal Gem::Version.new("0.128.0"), Harnex::Doctor::MIN_CODEX_VERSION
  end
end
