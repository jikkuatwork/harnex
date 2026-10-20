# A PTY adapter that scrapes one usage line from its transcript, standing in
# for the Codex PTY adapter (removed in 0.20.0) in telemetry and schema tests:
#   Token usage: total=106,867 input=104,158 (+ 250,880 cached) output=2,709 (reasoning 870)
#   To continue this session, run usage-cli resume <uuid>
class TranscriptUsageAdapter < Harnex::Adapters::Base
  def initialize(version: nil)
    super("usage-cli", [])
    @version = version
  end

  def base_command = ["usage-cli"]
  def provider = "openai"
  def usage_telemetry_supported? = true
  def agent_version = @version

  def parse_session_summary(text)
    line = text[/Token usage: .+$/].to_s
    number = ->(pattern) { line[pattern, 1]&.delete(",")&.to_i }
    {
      total_tokens: number.call(/total=([\d,]+)/), input_tokens: number.call(/input=([\d,]+)/),
      cached_tokens: number.call(/\(\+ ([\d,]+) cached\)/), output_tokens: number.call(/output=([\d,]+)/),
      reasoning_tokens: number.call(/reasoning ([\d,]+)/),
      agent_session_id: text[/resume ([0-9a-f-]{36})/, 1]
    }.compact
  end

  def self.summary_script
    <<~RUBY
      puts "Token usage: total=106,867 input=104,158 (+ 250,880 cached) output=2,709 (reasoning 870)"
      puts "To continue this session, run usage-cli resume 019ddf05-0f03-7d70-904f-23db7f00640f"
    RUBY
  end
end
