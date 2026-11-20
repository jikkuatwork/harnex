---
status: open
priority: P3
created: 2026-11-21
updated: 2026-11-21
tags: macos, darwin, tests, portability
type: bug
related: 99
---

# Issue 100 — The test suite has 19 failures on macOS

## What happened (2026-11-21)

First full suite run on a Mac (Ruby 3.3.0, minitest 5.20). Before #99 it had 858
runs, 21 failures and 6 errors. The 8 caused by #99 are fixed. These 19 remain;
none of them stopped `harnex ask` from working.

## Failures, by cause

**`/var` vs `/private/var` (16, test-only).** macOS temp dirs (`Dir.mktmpdir`)
live under `/var/folders/…`, which links to `/private/var/folders/…`. harnex
canonicalizes paths (realpath, `git rev-parse`, a child's `pwd`), but the tests
build expectations from the raw tmpdir. Fix in the tests: compare against
`File.realpath(dir)`, or create tmpdirs through a helper that canonicalizes them.

- SessionTest: `test_run_emits_usage_and_git_events_before_exited`,
  `test_summary_event_points_at_the_only_telemetry_destination`
- DispatchHistoryTest: `test_path_resolution_handles_repo_deep_tree_and_global_fallback`
- RunnerTest: `test_run_cwd_expands_relative_directory_from_invocation_cwd`,
  `test_run_cwd_uses_non_git_directory_for_child_root_and_walked_stream_path`,
  `test_run_root_overrides_metadata_without_changing_child_cwd`,
  `test_run_artifact_report_exposes_harness_receipt_and_claims_paths`,
  `test_run_cwd_accepts_git_directory`
- ConfigTest: `test_load_repo_returns_empty_config_when_file_is_absent`
- StatusCommandTest: `test_status_hints_at_sessions_in_other_repos_when_current_repo_is_empty`
- LanesTest: `test_a_name_whose_worker_runs_in_another_repo_is_refused_a_stale_one_is_not`,
  `test_config_puts_worktree_lanes_beside_the_checkout_and_land_honours_it`,
  `test_delegate_in_a_worktree_prints_the_reply_and_what_to_do_next`
- CompletionNotifierTest: `test_typed_marker_payloads_and_stale_cleanup`,
  `test_owned_delivery_is_registered_then_settled_without_erasing_reused_id_history`,
  `test_hook_receives_environment_and_runs_from_repo_root`

**No `/proc` (2, a real but minor gap).** `Harnex.parent_pid`
(`lib/harnex/core.rb`) reads `/proc/<pid>/stat` and returns `nil` on macOS, so
`tmux_pane_for_pid` cannot walk to an ancestor's pane. It degrades to "no pane";
`ps -o ppid= -p <pid>` would work on both platforms.

- CoreTest: `test_parent_pid_returns_ppid_for_current_process`,
  `test_tmux_pane_for_pid_finds_ancestor_match`

**Needs a look (1).** `RunnerTest#test_observed_receipt_captures_uncommitted_product_delta_not_harness_files`
expected `["PRODUCT.md"]` and got `[]`. This is probably the same path mismatch inside the receipt's
change filter. If so, it is a real gap: on macOS, lane receipts in a temp-dir
repo would miss uncommitted product files. Check before calling it test-only.

## Acceptance

- [ ] The full suite is green on macOS and still green on Linux.
- [ ] `parent_pid` works without `/proc`.
- [ ] The receipt-delta failure is explained and fixed where it lives.
