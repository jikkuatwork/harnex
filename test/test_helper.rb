require "minitest/autorun"
require "tmpdir"
require "fileutils"

# Isolate state dir so tests never touch real sessions
ENV["HARNEX_STATE_DIR"] = Dir.mktmpdir("harnex-test-state")

# Clear any session env that would pollute tests
%w[
  HARNEX_ID HARNEX_DESCRIPTION HARNEX_SESSION_ID HARNEX_SESSION_CLI
  HARNEX_SESSION_REPO_ROOT HARNEX_HOST HARNEX_BASE_PORT
  HARNEX_PORT_SPAN HARNEX_TRACE HARNEX_ARTIFACT_REPORT_PATH
  HARNEX_VALIDATION_REPORT_PATH HARNEX_ARTIFACT_CLAIMS_PATH
  HARNEX_ARTIFACT_REPORT_SCHEMA HARNEX_ARTIFACT_REPORT_MODE
  HARNEX_ARTIFACT_REPORT_REQUIRED
].each { |key| ENV.delete(key) }

require_relative "../lib/harnex"

# Clean up temp state dir when tests finish
Minitest.after_run do
  FileUtils.rm_rf(ENV["HARNEX_STATE_DIR"])
end
