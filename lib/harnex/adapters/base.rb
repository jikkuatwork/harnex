require "open3"
require "timeout"

module Harnex
  module Adapters
    class Base
      PROMPT_PREFIXES = [">", "\u203A", "\u276F"].freeze
      AGENT_VERSION_TIMEOUT_SECONDS = 2.0

      # Adapter contract — subclasses MUST implement:
      #   base_command          -> Array[String]  CLI args to spawn
      #
      # Subclasses MAY override:
      #   input_state(text)     -> Hash           Parse screen for state
      #   build_send_payload    -> Hash           Build injection payload
      #   inject_exit(writer)   -> void           Send a stop/exit sequence
      #   infer_repo_path(argv) -> String         Extract repo path from CLI args
      #   wait_for_sendable     -> String         Wait for a send-ready snapshot

      attr_reader :key

      def initialize(key, extra_args = [])
        @key = key
        @extra_args = extra_args.dup
      end

      # Default transport. Structured adapters override to :stdio_jsonrpc
      # (Codex app-server) or :stdio_jsonl_rpc (Pi RPC); Session#run uses
      # this to pick the I/O path.
      def transport
        :pty
      end

      # Vendor of the underlying agent — populates DISPATCH meta.agent_provider.
      # Subclasses override (claude → "anthropic", codex → "openai").
      def provider
        nil
      end

      # Whether the usage this adapter captures reports input_tokens
      # INCLUSIVE of cached_tokens. Depends on the capture path, not just
      # the provider: codex app-server JSON reports cached as a subset of
      # input, while the codex TUI line the PTY adapter scrapes shows
      # non-cached input with cached as a separate additive count. Feeds
      # Pricing.compute (plan 33 Phase 2).
      def usage_input_includes_cached?
        false
      end

      # Probes `<base_command.first> --version` with a short timeout and
      # memoizes the result for the adapter's lifetime. Returns nil when
      # the binary is missing, exits non-zero, or stalls past the timeout.
      def agent_version
        return @agent_version if defined?(@agent_version)

        @agent_version = probe_agent_version
      end

      def describe
        { transport: transport }
      end

      def build_command
        base_command + @extra_args
      end

      def base_command
        raise NotImplementedError, "#{self.class} must define #base_command"
      end

      def infer_repo_path(_argv)
        Dir.pwd
      end

      def input_state(screen_text)
        {
          state: "unknown",
          input_ready: nil
        }
      end

      def parse_session_summary(_transcript_tail)
        {}
      end

      # Whether this adapter has a supported source for token/cost telemetry.
      # A supported source can still be missing for a particular run.
      def usage_telemetry_supported?
        false
      end

      # Whether this adapter exposes active context-window occupancy separately
      # from cumulative usage. Supported sources can still yield no valid sample.
      def context_telemetry_supported?
        false
      end

      def context_telemetry_source
        nil
      end

      def send_wait_seconds(submit:, enter_only:)
        0.0
      end

      def wait_for_sendable_state?(_state, submit:, enter_only:)
        false
      end

      def wait_for_sendable(screen_snapshot_fn, submit:, enter_only:, force:)
        snapshot = screen_snapshot_fn.call
        return snapshot if force

        wait_secs = send_wait_seconds(submit: submit, enter_only: enter_only).to_f
        return snapshot unless wait_secs.positive?

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_secs
        state = input_state(snapshot)

        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline &&
              wait_for_sendable_state?(state, submit: submit, enter_only: enter_only)
          sleep 0.05
          snapshot = screen_snapshot_fn.call
          state = input_state(snapshot)
        end

        snapshot
      end

      def build_send_payload(text:, submit:, enter_only:, screen_text:, force: false)
        state = input_state(screen_text)
        if !force && blocked_state?(state, enter_only: enter_only)
          raise ArgumentError, blocked_message(state, enter_only: enter_only)
        end

        payload = enter_only ? "" : text.to_s
        payload << submit_bytes if submit || enter_only

        {
          text: payload,
          newline: false,
          input_state: state,
          force: force
        }
      end

      def inject_exit(writer, delay_ms: 0)
        writer.write("/exit")
        writer.flush
        sleep(delay_ms / 1000.0) if delay_ms.positive?
        writer.write(submit_bytes)
        writer.flush
      end

      protected

      def probe_agent_version
        cli = base_command.first
        return nil unless cli

        Timeout.timeout(AGENT_VERSION_TIMEOUT_SECONDS) do
          stdout, status = Open3.capture2(cli, "--version", err: File::NULL, in: File::NULL)
          return nil unless status.success?

          stdout.to_s.lines.first&.strip
        end
      rescue Errno::ENOENT, Timeout::Error, StandardError
        nil
      end

      def submit_bytes
        "\r"
      end

      def blocked_state?(state, enter_only:)
        state[:input_ready] == false && !allow_control_action?(state, enter_only: enter_only)
      end

      def allow_control_action?(_state, enter_only:)
        enter_only ? false : false
      end

      def blocked_message(state, enter_only:)
        suffix = enter_only ? " for Enter-only input" : ""
        "session is not ready for #{key} prompt input#{suffix} (state: #{state[:state]})"
      end

      def prompt_line?(line)
        stripped = line.to_s.strip
        return false if stripped.empty?
        return false if stripped.match?(/\A(?:[>\u203A\u276F]\s*)?\d+\./)

        PROMPT_PREFIXES.any? { |prefix| stripped.start_with?(prefix) }
      end

      def recent_lines(screen_text, limit: 40)
        normalized_screen_text(screen_text).lines.last(limit)
      end

      def normalized_screen_text(screen_text)
        text = screen_text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
        text = text.gsub(/\e\][^\a]*?(?:\a|\e\\)/, "")
        text = text.gsub(/\e\[\d*(?:;1)?H/, "\n")
        text = text.gsub(/\e(?:[@-Z\\-_]|\[[0-?]*[ -\/]*[@-~])/, "")
        text.gsub(/\r\n?/, "\n")
      end
    end
  end
end
