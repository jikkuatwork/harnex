require_relative "../test_helper"

class PricingTest < Minitest::Test
  # Codex app-server semantics: cached is a subset of input, reasoning a
  # subset of output — billable input = input - cached, reasoning never
  # priced.
  def test_inclusive_input_subtracts_cached
    priced = Harnex::Pricing.compute(
      provider: "openai", model: "gpt-5.3-codex",
      input_tokens: 1_000_000, output_tokens: 100_000, cached_tokens: 400_000,
      input_includes_cached: true
    )

    # 600k * 1.75 + 400k * 0.175 + 100k * 14.00 = 2_520_000 per-1M units
    assert_in_delta 2.52, priced[:cost_usd], 1e-9
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, priced[:as_of])
  end

  # Codex PTY semantics: the scraped TUI line reports non-cached input with
  # cached as a separate additive count — mirror of the transcript fixture
  # `total=106,867 input=104,158 (+ 250,880 cached) output=2,709`.
  def test_exclusive_input_prices_cached_additively
    priced = Harnex::Pricing.compute(
      provider: "openai", model: "gpt-5.3-codex",
      input_tokens: 104_158, output_tokens: 2_709, cached_tokens: 250_880
    )

    expected = (104_158 * 1.75 + 250_880 * 0.175 + 2_709 * 14.00) / 1_000_000.0
    assert_in_delta expected, priced[:cost_usd], 1e-6
  end

  # Anthropic semantics: input excludes cache reads — cached prices
  # additively at the cache-read rate.
  def test_anthropic_cost_prices_cached_additively
    priced = Harnex::Pricing.compute(
      provider: "anthropic", model: "claude-opus-5",
      input_tokens: 1_000_000, output_tokens: 100_000, cached_tokens: 400_000
    )

    # 1M * 5.00 + 400k * 0.50 + 100k * 25.00 = 7_700_000 per-1M units
    assert_in_delta 7.7, priced[:cost_usd], 1e-9
  end

  def test_gpt_5_5_flex_prices_effective_service_tier
    priced = Harnex::Pricing.compute(
      provider: "openai", model: "gpt-5.5", service_tier: "flex",
      input_tokens: 1_000_000, output_tokens: 100_000, cached_tokens: 400_000,
      input_includes_cached: true
    )

    # 600k * 2.50 + 400k * 0.25 + 100k * 15.00 = 3_100_000 per-1M units
    assert_in_delta 3.1, priced[:cost_usd], 1e-9
    assert_equal "2026-08-03", priced[:as_of]
  end

  def test_gpt_5_5_service_tiers_price_distinctly
    cases = {
      "standard" => 6.2,
      "flex" => 3.1,
      "fast" => 15.5,
      "priority" => 15.5
    }

    cases.each do |service_tier, expected_cost|
      priced = Harnex::Pricing.compute(
        provider: "openai", model: "gpt-5.5", service_tier: service_tier,
        input_tokens: 1_000_000, output_tokens: 100_000, cached_tokens: 400_000,
        input_includes_cached: true
      )

      assert_in_delta expected_cost, priced[:cost_usd], 1e-9, service_tier
    end
  end

  def test_gpt_5_5_unknown_or_missing_service_tier_returns_nil
    assert_nil Harnex::Pricing.compute(
      provider: "openai", model: "gpt-5.5", service_tier: "turbo",
      input_tokens: 100, output_tokens: 100, cached_tokens: 0
    )
    assert_nil Harnex::Pricing.compute(
      provider: "openai", model: "gpt-5.5", service_tier: nil,
      input_tokens: 100, output_tokens: 100, cached_tokens: 0
    )
  end

  def test_flat_price_models_do_not_require_service_tier
    priced = Harnex::Pricing.compute(
      provider: "openai", model: "gpt-5.3-codex", service_tier: nil,
      input_tokens: 1_000_000, output_tokens: 100_000, cached_tokens: 400_000,
      input_includes_cached: true
    )

    assert_in_delta 2.52, priced[:cost_usd], 1e-9
  end

  def test_unknown_model_returns_nil
    assert_nil Harnex::Pricing.compute(
      provider: "openai", model: "gpt-legacy-unknown",
      input_tokens: 100, output_tokens: 100, cached_tokens: 0
    )
  end

  def test_unknown_provider_returns_nil
    assert_nil Harnex::Pricing.compute(
      provider: nil, model: "gpt-5.3-codex",
      input_tokens: 100, output_tokens: 100, cached_tokens: 0
    )
  end

  def test_missing_token_components_return_nil
    assert_nil Harnex::Pricing.compute(
      provider: "openai", model: "gpt-5.3-codex",
      input_tokens: nil, output_tokens: 100, cached_tokens: 0
    )
    assert_nil Harnex::Pricing.compute(
      provider: "openai", model: "gpt-5.3-codex",
      input_tokens: 100, output_tokens: nil, cached_tokens: 0
    )
  end

  def test_nil_cached_tokens_treated_as_zero
    priced = Harnex::Pricing.compute(
      provider: "openai", model: "gpt-5",
      input_tokens: 1_000_000, output_tokens: 0, cached_tokens: nil
    )

    assert_in_delta 1.25, priced[:cost_usd], 1e-9
  end

  def test_cached_exceeding_inclusive_input_clamps_billable_input_to_zero
    priced = Harnex::Pricing.compute(
      provider: "openai", model: "gpt-5",
      input_tokens: 100, output_tokens: 0, cached_tokens: 200,
      input_includes_cached: true
    )

    # billable input clamps to 0; cached still prices: 200 * 0.125 / 1M
    assert_in_delta 200 * 0.125 / 1_000_000.0, priced[:cost_usd], 1e-12
  end

  def test_zero_tokens_price_to_zero
    priced = Harnex::Pricing.compute(
      provider: "openai", model: "gpt-5.3-codex",
      input_tokens: 0, output_tokens: 0, cached_tokens: 0
    )

    assert_equal 0.0, priced[:cost_usd]
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, priced[:as_of])
  end

  # Guard against the real captured app-server row regressing: the formula
  # must reproduce a plausible cost for observed live numbers.
  def test_live_codex_row_prices
    priced = Harnex::Pricing.compute(
      provider: "openai", model: "gpt-5.3-codex",
      input_tokens: 3_084_697, output_tokens: 17_705, cached_tokens: 2_924_416,
      input_includes_cached: true
    )

    expected = ((3_084_697 - 2_924_416) * 1.75 + 2_924_416 * 0.175 + 17_705 * 14.00) / 1_000_000.0
    assert_in_delta expected, priced[:cost_usd], 1e-6
  end
end
