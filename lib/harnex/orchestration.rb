require "fileutils"
require "json"
require "time"

module Harnex
  module Orchestration
    SAMPLE_SCHEMA = "harnex.orchestrator_sample.v1"
    REPORT_SCHEMA = "harnex.orchestration_tax.v1"
    ROLES = %w[primary worker].freeze
    SAMPLE_EVENTS = %w[
      sample generation_started generation_finished rotation recovery compaction
    ].freeze
    USAGE_FIELDS = %w[
      input_tokens output_tokens cached_input_tokens reasoning_tokens total_tokens cost_usd
    ].freeze
    CONTEXT_FIELDS = %w[
      terminal_tokens window_tokens terminal_percent peak_tokens peak_percent
    ].freeze
    STATUSES = %w[observed estimated unsupported missing zero].freeze

    module_function

    def normalize_metadata(meta)
      values = stringify_keys(meta || {})
      run_id = string_value(values["orchestration_run_id"])
      generation_id = string_value(values["orchestration_generation_id"])
      role = string_value(values["orchestration_role"])
      role = nil unless ROLES.include?(role)
      return nil unless run_id || generation_id || role

      {
        "run_id" => run_id,
        "generation_id" => generation_id,
        "role" => role,
        "project_id" => string_value(values["project_id"]),
        "queue_id" => string_value(values["queue_id"]),
        "session_id" => string_value(values["orchestration_session_id"]),
        "rotation_reason" => string_value(values["orchestration_rotation_reason"])
      }
    end

    def append_sample(path, attrs)
      sample = normalize_sample(attrs)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644) do |file|
        file.write(JSON.generate(sample))
        file.write("\n")
      end
      sample
    end

    def normalize_sample(attrs)
      values = stringify_keys(attrs || {})
      run_id = required_string(values, "orchestration_run_id")
      generation_id = required_string(values, "generation_id")
      event = string_value(values["event"]) || "sample"
      event = "sample" unless SAMPLE_EVENTS.include?(event)
      sample = {
        "schema" => SAMPLE_SCHEMA,
        "orchestration_run_id" => run_id,
        "generation_id" => generation_id,
        "project_id" => string_value(values["project_id"]),
        "queue_id" => string_value(values["queue_id"]),
        "session_id" => string_value(values["session_id"]),
        "event" => event,
        "ts" => iso8601_time(values["ts"] || Time.now),
        "context" => normalize_context(values["context"]),
        "usage" => normalize_usage(values["usage"]),
        "tool_calls" => non_negative_integer(values["tool_calls"]),
        "compactions" => non_negative_integer(values["compactions"]),
        "rotation_reason" => string_value(values["rotation_reason"])
      }
      sample
    end

    def report(dispatch_path:, samples_path: nil, run_id:)
      build_report(
        dispatch_rows: load_jsonl(dispatch_path),
        sample_rows: samples_path ? load_jsonl(samples_path) : [],
        run_id: run_id
      )
    end

    def build_report(dispatch_rows:, sample_rows:, run_id:)
      selected_dispatches = dispatch_rows.select { |row| dispatch_run_id(row) == run_id }
      samples = sample_rows.select do |row|
        row.is_a?(Hash) &&
          row["schema"].to_s == SAMPLE_SCHEMA &&
          row["orchestration_run_id"].to_s == run_id.to_s
      end
      primary_dispatches, worker_dispatches = selected_dispatches.partition do |row|
        row.dig("orchestration", "role").to_s == "primary"
      end

      primary_sources = primary_dispatch_usage_sources(primary_dispatches) + sample_usage_sources(samples)
      primary_contexts = primary_dispatch_context_sources(primary_dispatches) + sample_context_sources(samples)
      generations = build_generations(primary_dispatches, samples)
      accepted_work = accepted_work_keys(worker_dispatches)
      outcome_counts = deduped_outcome_counts(worker_dispatches)
      primary_usage = summarize_usage(primary_sources)
      worker_usage = summarize_usage(worker_dispatches.map { |row| row["usage"] }.compact)
      primary_tool_calls = sum_numeric(primary_dispatches.map { |row| row.dig("actual", "tool_calls") }) +
        latest_sample_sum(samples, "tool_calls")
      primary_compactions = sum_numeric(primary_dispatches.map { |row| row.dig("reliability", "compactions") }) +
        latest_sample_sum(samples, "compactions")
      accepted_count = accepted_work.length

      {
        "schema" => REPORT_SCHEMA,
        "orchestration_run_id" => run_id,
        "generated_at" => Time.now.iso8601,
        "project_id" => first_known_value(selected_dispatches, samples, "project_id"),
        "queue_id" => first_known_value(selected_dispatches, samples, "queue_id"),
        "primary" => {
          "generation_count" => generations.length,
          "generations" => generations,
          "usage" => primary_usage,
          "context" => summarize_context(primary_contexts),
          "tool_calls" => primary_tool_calls,
          "compactions" => primary_compactions,
          "wall_s" => primary_wall_seconds(primary_dispatches, samples),
          "coverage" => {
            "usage_status" => primary_usage["status"],
            "context_status" => summarize_context(primary_contexts)["status"],
            "dispatch_rows" => primary_dispatches.length,
            "external_samples" => samples.length
          }
        },
        "workers" => {
          "dispatches" => worker_dispatches.length,
          "usage" => worker_usage,
          "active_s" => sum_numeric(worker_dispatches.map { |row| row.dig("actual", "duration_s") }),
          "outcomes" => outcome_counts,
          "accepted_work_ids" => accepted_work.sort
        },
        "ratios" => {
          "primary_total_tokens_per_accepted_entry" => ratio(primary_usage["total_tokens"], accepted_count),
          "primary_cost_usd_per_accepted_entry" => ratio(primary_usage["cost_usd"], accepted_count),
          "primary_tool_calls_per_accepted_entry" => ratio(primary_tool_calls, accepted_count)
        },
        "coverage" => {
          "primary_usage_status" => primary_usage["status"],
          "worker_usage_status" => worker_usage["status"],
          "primary_context_status" => summarize_context(primary_contexts)["status"]
        }
      }
    end

    def load_jsonl(path)
      return [] unless path && File.file?(path)

      File.readlines(path, chomp: true).filter_map do |line|
        next if line.strip.empty?

        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    def normalize_usage(value)
      usage = stringify_keys(value || {})
      status = normalize_status(usage["status"])
      has_measurement = USAGE_FIELDS.any? { |field| !numeric_or_nil(usage[field]).nil? }
      status ||= has_measurement ? "observed" : "missing"
      {
        "status" => status,
        "cost_usd" => numeric_or_nil(usage["cost_usd"]),
        "cost_source" => string_value(usage["cost_source"]),
        "input_tokens" => numeric_or_nil(usage["input_tokens"]),
        "output_tokens" => numeric_or_nil(usage["output_tokens"]),
        "cached_input_tokens" => numeric_or_nil(usage["cached_input_tokens"] || usage["cached_tokens"]),
        "reasoning_tokens" => numeric_or_nil(usage["reasoning_tokens"]),
        "total_tokens" => numeric_or_nil(usage["total_tokens"])
      }
    end

    def normalize_context(value)
      context = stringify_keys(value || {})
      status = normalize_status(context["status"])
      has_measurement = CONTEXT_FIELDS.any? { |field| !numeric_or_nil(context[field]).nil? }
      status ||= has_measurement ? "observed" : "missing"
      samples = non_negative_integer(context["samples"])
      samples = has_measurement ? 1 : 0 if samples.nil?
      {
        "status" => status,
        "source" => string_value(context["source"]),
        "terminal_tokens" => numeric_or_nil(context["terminal_tokens"] || context["tokens"]),
        "window_tokens" => numeric_or_nil(context["window_tokens"] || context["context_window"]),
        "terminal_percent" => numeric_or_nil(context["terminal_percent"] || context["percent"]),
        "peak_tokens" => numeric_or_nil(context["peak_tokens"] || context["terminal_tokens"] || context["tokens"]),
        "peak_percent" => numeric_or_nil(context["peak_percent"] || context["terminal_percent"] || context["percent"]),
        "samples" => samples,
        "missing_samples" => non_negative_integer(context["missing_samples"]) || 0,
        "latest_sample_status" => string_value(context["latest_sample_status"] || status)
      }
    end

    def dispatch_run_id(row)
      row.dig("orchestration", "run_id") || row.dig("meta", "orchestration_run_id")
    end

    def primary_dispatch_usage_sources(rows)
      rows.map { |row| row["usage"] }.compact
    end

    def primary_dispatch_context_sources(rows)
      rows.map { |row| row["context"] }.compact
    end

    def sample_usage_sources(samples)
      latest_by_generation_session(samples, "usage").map { |sample| sample["usage"] }.compact
    end

    def sample_context_sources(samples)
      samples.map { |sample| sample["context"] }.compact
    end

    def build_generations(primary_dispatches, samples)
      generation_ids = []
      generation_ids.concat(primary_dispatches.map { |row| row.dig("orchestration", "generation_id") })
      generation_ids.concat(samples.map { |row| row["generation_id"] })
      generation_ids = generation_ids.compact.map(&:to_s).reject(&:empty?).uniq

      generation_ids.map do |generation_id|
        dispatches = primary_dispatches.select { |row| row.dig("orchestration", "generation_id").to_s == generation_id }
        generation_samples = samples.select { |row| row["generation_id"].to_s == generation_id }
        contexts = dispatches.map { |row| row["context"] }.compact + generation_samples.map { |row| row["context"] }.compact
        {
          "id" => generation_id,
          "sessions" => generation_sessions(dispatches, generation_samples),
          "rotation_reason" => generation_rotation_reason(dispatches, generation_samples),
          "usage" => summarize_usage(dispatches.map { |row| row["usage"] }.compact + sample_usage_sources(generation_samples)),
          "context" => summarize_context(contexts),
          "tool_calls" => sum_numeric(dispatches.map { |row| row.dig("actual", "tool_calls") }) +
            latest_sample_sum(generation_samples, "tool_calls"),
          "compactions" => sum_numeric(dispatches.map { |row| row.dig("reliability", "compactions") }) +
            latest_sample_sum(generation_samples, "compactions")
        }
      end
    end

    def generation_sessions(dispatches, samples)
      values = dispatches.map { |row| row.dig("orchestration", "session_id") || row.dig("meta", "id") }
      values.concat(samples.map { |row| row["session_id"] })
      values.compact.map(&:to_s).reject(&:empty?).uniq.sort
    end

    def generation_rotation_reason(dispatches, samples)
      dispatches.map { |row| row.dig("orchestration", "rotation_reason") }
        .concat(samples.map { |row| row["rotation_reason"] })
        .compact
        .map(&:to_s)
        .reject(&:empty?)
        .first
    end

    def summarize_usage(usages)
      usages = usages.select { |usage| usage.is_a?(Hash) }
      statuses = usages.map { |usage| normalize_status(usage["status"]) || "missing" }
      summary = {
        "status" => combined_status(statuses),
        "cost_usd" => sum_or_nil(usages.map { |usage| usage["cost_usd"] }),
        "input_tokens" => sum_or_nil(usages.map { |usage| usage["input_tokens"] }),
        "output_tokens" => sum_or_nil(usages.map { |usage| usage["output_tokens"] }),
        "cached_input_tokens" => sum_or_nil(usages.map { |usage| usage["cached_input_tokens"] || usage["cached_tokens"] }),
        "reasoning_tokens" => sum_or_nil(usages.map { |usage| usage["reasoning_tokens"] }),
        "total_tokens" => sum_or_nil(usages.map { |usage| usage["total_tokens"] })
      }
      summary
    end

    def summarize_context(contexts)
      contexts = contexts.select { |context| context.is_a?(Hash) }
      statuses = contexts.map { |context| normalize_status(context["status"]) || "missing" }
      terminal = latest_context_with_value(contexts, "terminal_tokens")
      peak = contexts.max_by { |context| numeric_or_nil(context["peak_tokens"] || context["terminal_tokens"]) || -1 }
      peak_value = peak && (numeric_or_nil(peak["peak_tokens"]) || numeric_or_nil(peak["terminal_tokens"]))
      peak_percent = peak && (numeric_or_nil(peak["peak_percent"]) || numeric_or_nil(peak["terminal_percent"]))
      {
        "status" => combined_status(statuses),
        "source" => contexts.map { |context| string_value(context["source"]) }.compact.first,
        "terminal_tokens" => terminal && numeric_or_nil(terminal["terminal_tokens"]),
        "window_tokens" => terminal && numeric_or_nil(terminal["window_tokens"]),
        "terminal_percent" => terminal && numeric_or_nil(terminal["terminal_percent"]),
        "peak_tokens" => peak_value,
        "peak_percent" => peak_percent,
        "samples" => sum_numeric(contexts.map { |context| context["samples"] }),
        "missing_samples" => sum_numeric(contexts.map { |context| context["missing_samples"] })
      }
    end

    def latest_context_with_value(contexts, field)
      contexts.reverse.find { |context| !numeric_or_nil(context[field]).nil? }
    end

    def accepted_work_keys(rows)
      rows.select { |row| row.dig("outcome", "status").to_s == "accepted" }
        .map { |row| work_key(row) }
        .compact
        .uniq
    end

    def deduped_outcome_counts(rows)
      by_work = {}
      rows.each do |row|
        key = work_key(row) || row.dig("attempt", "run_id") || row.dig("meta", "id")
        next unless key

        outcome = classify_worker_outcome(row)
        by_work[key] = stronger_outcome(by_work[key], outcome)
      end
      %w[accepted rejected blocked unknown].to_h { |status| [status, by_work.values.count(status)] }
    end

    def classify_worker_outcome(row)
      status = row.dig("outcome", "status").to_s
      return status if %w[accepted rejected].include?(status)
      return "blocked" if row.dig("attempt", "status").to_s == "failed"
      return "blocked" if %w[failure timeout boot_failure].include?(row.dig("actual", "exit").to_s)

      "unknown"
    end

    def stronger_outcome(current, candidate)
      order = { "unknown" => 0, "blocked" => 1, "rejected" => 2, "accepted" => 3 }
      return candidate unless current

      order.fetch(candidate, 0) > order.fetch(current, 0) ? candidate : current
    end

    def work_key(row)
      attribution = row["attribution"]
      if attribution.is_a?(Hash) && string_value(attribution["work_type"]) && string_value(attribution["work_id"])
        return "#{attribution['work_type']}:#{attribution['work_id']}"
      end

      queue = row["queue"]
      return nil unless queue.is_a?(Hash)

      %w[entry_id issue plan queue_id].each do |field|
        value = string_value(queue[field])
        return "#{field}:#{value}" if value
      end
      nil
    end

    def primary_wall_seconds(dispatches, samples)
      dispatch_wall = sum_numeric(dispatches.map { |row| row.dig("actual", "duration_s") })
      sample_wall = samples_by_generation(samples).values.sum do |generation_samples|
        times = generation_samples.filter_map { |sample| parse_time(sample["ts"]) }.sort
        times.length > 1 ? (times.last - times.first).to_i : 0
      end
      dispatch_wall + sample_wall
    end

    def first_known_value(dispatches, samples, field)
      dispatches.map { |row| row.dig("queue", field) || row.dig("orchestration", field) }
        .concat(samples.map { |row| row[field] })
        .compact
        .map(&:to_s)
        .reject(&:empty?)
        .first
    end

    def latest_sample_sum(samples, field)
      sum_numeric(latest_by_generation_session(samples, field).map { |sample| sample[field] })
    end

    def latest_by_generation_session(samples, field)
      samples.select { |sample| !sample[field].nil? }
        .group_by { |sample| [sample["generation_id"], sample["session_id"]] }
        .values
        .map { |group| group.max_by { |sample| parse_time(sample["ts"]) || Time.at(0) } }
    end

    def samples_by_generation(samples)
      samples.group_by { |sample| sample["generation_id"].to_s }
    end

    def combined_status(statuses)
      statuses = statuses.compact
      return "missing" if statuses.empty?
      return statuses.first if statuses.uniq.length == 1

      useful = statuses - %w[missing unsupported]
      return useful.uniq.length == 1 ? useful.first : "mixed" unless useful.empty?

      statuses.include?("missing") ? "missing" : "unsupported"
    end

    def ratio(value, count)
      return nil unless value.is_a?(Numeric) && count.to_i.positive?

      value.to_f / count
    end

    def sum_or_nil(values)
      numeric = values.filter_map { |value| numeric_or_nil(value) }
      return nil if numeric.empty?

      numeric.sum
    end

    def sum_numeric(values)
      values.filter_map { |value| numeric_or_nil(value) }.sum
    end

    def stringify_keys(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, item), memo| memo[key.to_s] = item }
    end

    def required_string(values, key)
      string_value(values[key]) || raise(ArgumentError, "#{key} is required")
    end

    def string_value(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def numeric_or_nil(value)
      return value if value.is_a?(Numeric) && value.finite?
      return nil if value.nil? || value.to_s.strip.empty?

      Float(value)
    rescue ArgumentError
      nil
    end

    def non_negative_integer(value)
      numeric = numeric_or_nil(value)
      return nil unless numeric

      integer = numeric.to_i
      integer.negative? ? nil : integer
    end

    def normalize_status(value)
      status = string_value(value)
      STATUSES.include?(status) ? status : nil
    end

    def iso8601_time(value)
      return value.iso8601 if value.respond_to?(:iso8601)

      parse_time(value)&.iso8601 || Time.now.iso8601
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
