module Harnex
  # Static price table for computing usage.cost_usd when an adapter reports
  # tokens but no cost (plan 33 Phase 2, locked decision 6). Cost is computed,
  # never guessed: an unknown provider/model/service tier or a missing token
  # component leaves cost_usd null.
  #
  # ## Update procedure
  #
  # Rates are USD per 1M tokens, copied by hand from the provider pricing
  # pages at the URLs below. To update:
  #
  # 1. Fetch the provider's pricing page and read the per-1M-token rates for
  #    input, cached input (cache read), and output.
  # 2. Replace the entry's rates and set `as_of` to the date you read them.
  #    Add new models as new entries; never delete an entry solely because a
  #    model left the pricing page (old rows in dispatch.jsonl were priced
  #    against it — the `as_of` on each row records which table vintage
  #    applied).
  # 3. Update the expected costs in test/harnex/pricing_test.rb — rate
  #    changes are meant to be conscious, test-visible edits.
  # 4. Never backfill: rows written before a table change keep the cost they
  #    were written with.
  #
  # Models whose pricing varies by service tier use a nested `service_tiers`
  # table. For those models a nil or unknown service tier is unpriceable. A
  # `max_context_tokens_exclusive` entry also requires an observed context
  # high-water below that boundary; Harnex leaves cost null when context is
  # missing or entered a differently-priced long-context tier. Do not infer
  # standard/flex/fast or context tier outside the recorded measurements.
  # OpenAI documents `priority` as the fast alias for gpt-5.5 short-context
  # pricing; Harnex maps that alias only where the source supports it.
  #
  # Known scheduled change: Anthropic's claude-sonnet-5 entry below carries
  # introductory pricing ($2/$10) that ends 2026-08-31; standard pricing is
  # $3/$15 (cache read $0.30) from 2026-09-01. Refresh the entry then.
  #
  # ## Token semantics (verified 2026-08-02, plan 33 Phase 2)
  #
  # What input_tokens contains depends on the CAPTURE PATH, not just the
  # provider, so the caller passes `input_includes_cached:` (sourced from
  # `Adapters::Base#usage_input_includes_cached?`):
  #
  # - codex app-server (input_includes_cached: true): the JSON
  #   TokenUsageBreakdown reports cachedInputTokens as a subset of
  #   inputTokens and reasoningOutputTokens as a subset of outputTokens
  #   (verified against test/fixtures/codex_schema/v2 and a live captured
  #   row: input 3,084,697 + output 17,705 == total 3,102,402 exactly).
  #   Billable input = input - cached.
  # - codex PTY (false): the scraped TUI line `input=X (+ Y cached)` shows
  #   NON-cached input with cached as a separate additive count (fixture:
  #   total 106,867 == input 104,158 + output 2,709, cached 250,880 > input).
  #   Billable input = input; cached prices additively at the cached rate.
  # - anthropic (false): the Messages API reports input_tokens EXCLUSIVE of
  #   cache reads (cache_read_input_tokens is a separate field). Cache
  #   WRITES (cache_creation_input_tokens, billed at 1.25x input) have no
  #   harnex usage field yet — the Phase 3 Claude usage producer must either
  #   fold them into input_tokens or extend this formula before pricing rows
  #   that include cache writes.
  #
  # Reasoning tokens are never priced separately on any path — they are
  # already inside output_tokens.
  module Pricing
    PRICES = {
      "openai" => {
        # Source: https://developers.openai.com/api/docs/pricing
        "gpt-5.3-codex" => { input: 1.75, cached_input: 0.175, output: 14.00, as_of: "2026-08-02" },
        # Short-context service-tier rates read 2026-08-03. Long-context
        # rates are deliberately absent until exact source pricing is known.
        "gpt-5.5" => {
          max_context_tokens_exclusive: 272_000,
          service_tier_aliases: { "priority" => "fast" }.freeze,
          service_tiers: {
            "standard" => { input: 5.00, cached_input: 0.50, output: 30.00, as_of: "2026-08-03" },
            "flex" => { input: 2.50, cached_input: 0.25, output: 15.00, as_of: "2026-08-03" },
            "fast" => { input: 12.50, cached_input: 1.25, output: 75.00, as_of: "2026-08-03" }
          }.freeze
        }.freeze,
        "gpt-5.2" => { input: 1.75, cached_input: 0.175, output: 14.00, as_of: "2026-08-02" },
        "gpt-5.1" => { input: 1.25, cached_input: 0.125, output: 10.00, as_of: "2026-08-02" },
        "gpt-5" => { input: 1.25, cached_input: 0.125, output: 10.00, as_of: "2026-08-02" },
        "gpt-5-mini" => { input: 0.25, cached_input: 0.025, output: 2.00, as_of: "2026-08-02" }
      }.freeze,
      "anthropic" => {
        # Source: https://claude.com/platform/api (cache read = 0.1x input)
        "claude-fable-5" => { input: 10.00, cached_input: 1.00, output: 50.00, as_of: "2026-08-02" },
        "claude-opus-5" => { input: 5.00, cached_input: 0.50, output: 25.00, as_of: "2026-08-02" },
        "claude-sonnet-5" => { input: 2.00, cached_input: 0.20, output: 10.00, as_of: "2026-08-02" },
        "claude-haiku-4-5" => { input: 1.00, cached_input: 0.10, output: 5.00, as_of: "2026-08-02" }
      }.freeze
    }.freeze

    module_function

    # Returns { cost_usd:, as_of: } or nil when the cost cannot be computed
    # (unknown provider/model/service tier, or input/output token counts missing).
    def compute(provider:, model:, input_tokens:, output_tokens:, cached_tokens: nil,
                service_tier: nil, context_tokens: nil,
                input_includes_cached: false)
      model_entry = PRICES.dig(provider.to_s, model.to_s)
      return nil unless model_entry
      return nil unless context_priceable?(model_entry, context_tokens)

      entry = rates_for_service_tier(model_entry, service_tier)
      return nil unless entry
      return nil unless input_tokens.is_a?(Numeric) && output_tokens.is_a?(Numeric)

      cached = cached_tokens.is_a?(Numeric) ? cached_tokens : 0
      billable_input = input_includes_cached ? input_tokens - cached : input_tokens
      billable_input = 0 if billable_input.negative?

      cost = (billable_input * entry[:input] +
              cached * entry[:cached_input] +
              output_tokens * entry[:output]) / 1_000_000.0
      { cost_usd: cost.round(6), as_of: entry[:as_of] }
    end

    def context_priceable?(entry, context_tokens)
      limit = entry[:max_context_tokens_exclusive]
      return true unless limit

      context_tokens.is_a?(Numeric) && context_tokens >= 0 && context_tokens < limit
    end

    def rates_for_service_tier(entry, service_tier)
      tiers = entry[:service_tiers]
      return entry unless tiers

      tier = service_tier.to_s
      return nil if tier.empty?

      aliases = entry[:service_tier_aliases] || {}
      tiers[aliases.fetch(tier, tier)]
    end
  end
end
