require_relative "../test_helper"

class GemspecTest < Minitest::Test
  def test_public_documentation_is_packaged
    spec = Gem::Specification.load(File.expand_path("../../harnex.gemspec", __dir__))

    refute_nil spec
    %w[
      README.md
      GUIDE.md
      TECHNICAL.md
      docs/configuration.md
      docs/dispatch-telemetry.md
      docs/events.md
      guides/01_dispatch.md
      guides/04_monitoring.md
    ].each do |path|
      assert_includes spec.files, path
    end
  end
end
