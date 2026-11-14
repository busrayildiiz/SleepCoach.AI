# iOS CI and merge safety

## Execution policy

- Draft PR updates: complete app-hosted XCTest target on iPhone 16 Pro, without coverage instrumentation. Feature paths additionally select related UI suites on both standard and compact simulators. Shared/unknown paths or a failed diff select the whole UI target, including newly added suites. Documentation-only changes still run XCTest.
- Ready PRs: full shared scheme (XCTest and XCUITest) with coverage on both simulators after every update. No separate focused UI job runs alongside it.
- Merge queue, main pushes, `v*` tags and manual dispatch: the same full validation.
- PR lifecycle events include ready-for-review and conversion back to draft. Draft merge gates intentionally fail: green fast checks never approve a merge.
- Feature pushes trigger only through `pull_request`, avoiding duplicate push/PR test runs. Branches without an open PR do not run CI. Main/tag pushes validate their resulting revisions separately.
- Superseded PR runs are cancelled; release/manual/merge-group runs are not cancelled by newer workflow runs.

The pinned destinations are Xcode 16.4 (16F6), iOS 18.5, iPhone 16 Pro and iPhone SE (3rd generation). Missing or ambiguous devices fail validation. A runner-image change may require an explicit toolchain/device update.

Full validation has no test filters and keeps the shared scheme's coverage settings and existing signing overrides. App/test source, scheme membership and screenshot scenarios are unchanged. Only Swift package downloads/checkouts are cached, keyed by OS, architecture, toolchain and committed Package.resolved hash. There is no DerivedData cache or build artifact reuse. Artifact bundles contain build/package logs, xcresult, JSON summary and exported screenshots for UI tiers, retained for 30 days. Missing result bundles, zero passing tests, failed exports and missing UI screenshots fail the job. Failures still attempt artifact upload; force cancellation can prevent complete export/upload.

## Required GitHub configuration

Branch protection and ruleset REST reads returned Forbidden during implementation. The available GitHub connector does not expose those settings. No protection settings were changed.

Both existing status names, `build-and-test` and `build-and-test (compact)`, are retained as compatibility gates. They succeed only after `merge-validation`, which requires successful classification and successful full validation of both matrix destinations. Draft, skipped, failed and cancelled full runs cannot satisfy these gates. Fast/focused jobs cannot replace full validation.

Before merging this CI PR, an administrator must:

1. Inspect all main branch protections and applicable repository/organization rulesets. Preserve existing requirements and bypass restrictions.
2. Verify the new check's exact displayed context and GitHub Actions source application. Require `merge-validation` for main, alongside the existing checks during rollout. Keep existing checks until the new gate is verified.
3. Verify an actual successful full run on both simulators, artifact access, and a blocked merge for a failed/cancelled/skipped full run and for a draft PR.
4. Require the branch to be up to date with main, or use a merge queue. With a queue, confirm these checks run and succeed on the `merge_group` integration commit.
5. Restrict bypasses as appropriate. Do not require optional fast/focused statuses; they intentionally do not run on ready PRs.

GitHub can accept skipped required jobs, so the compatibility gates and merge-validation explicitly fail when required work did not succeed. Do not replace them with a conditional job that skips on drafts.

## Release validation

A tag push validates the tagged commit, but does not itself prevent publishing. This repository currently has no release deployment job to attach a dependency to. Before publishing/distributing, manually dispatch iOS CI on the exact release candidate ref and require successful full validation of that SHA. Any future release publication workflow must depend on full validation of the same SHA. Protect release tags/rules and publishing permissions to enforce that process; do not interpret a post-tag run as an enforced pre-publication gate.

## Timing baseline and comparison

Historical logs retrieved through the GitHub connector:

- Run 43478997349 / job 132070269889 (standard): runner log 18:09:25–18:24:01 UTC on 2026-11-13, approximately 14m36s. Explicit package resolution was approximately 10 seconds. UI execution reported 587.856 seconds (9m48s): Home 137.339s, Recording 297.626s, Hero 152.884s. These are suite durations, not additive critical-path measurements of all build/test work.
- Run 43461879066 / compact job 132029190118: 15 UI tests reported 623.291 seconds (10m23s); the selected device was iPhone SE (3rd generation), iOS 18.5.

Draft XCTest feedback is estimated at 3–8 minutes, roughly 45–80% below the measured standard job. Focused runs retain the relevant UI duration and cold build/setup costs. Both-device focused work consumes additional runner minutes. Package caching alone is likely a small improvement against the measured ten-second resolution baseline. Full validation still includes all UI execution; do not expect the same reduction as fast feedback.

The new workflow writes package-resolution and combined build/test step durations to job summaries, alongside artifact links. Job/step timestamps and xcresult summaries provide the after baseline. Compare several cold/warm runs on similar revisions and simulator classes, recording queue time separately. No post-change macOS timings were available during local implementation.

## Local verification

Run `actionlint` and `python3 -m unittest discover -s .github/scripts -p 'test_*.py' -v` before changing routing or gates. Tests cover feature routing, unknown/shared changes, invalid diff fallback and the fail-closed gate across success/failure/cancelled/skipped/missing outcomes. XCTest/XCUITest requires macOS/Xcode and must be validated by the PR run.
