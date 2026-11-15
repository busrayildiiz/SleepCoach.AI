# iOS CI and merge safety

## Execution policy

- Draft PR updates: complete app-hosted XCTest target on iPhone 16 Pro, without coverage instrumentation or automatic XCUITest. This applies to every update, including unknown/shared and documentation-only changes. Classification records deferred UI coverage in the job summary; it never approves that coverage or starts extra simulator jobs.
- Ready PRs: full shared scheme (XCTest and XCUITest) with coverage on both simulators after every update. No separate focused UI job runs alongside it.
- Merge queue, main pushes, `v*` tags and manual dispatch: the same full validation.
- PR lifecycle events include ready-for-review and conversion back to draft. Draft merge gates intentionally fail: green fast checks never approve a merge.
- Feature pushes trigger only through `pull_request`, avoiding duplicate push/PR test runs. Branches without an open PR do not run CI. Main/tag pushes validate their resulting revisions separately.
- Superseded PR runs are cancelled; release/manual/merge-group runs are not cancelled by newer workflow runs.

The pinned destinations are Xcode 16.4 (16F6), iOS 18.5, iPhone 16 Pro and iPhone SE (3rd generation). Missing or ambiguous devices fail validation. A runner-image change may require an explicit toolchain/device update.

Full validation has no test filters and keeps the shared scheme's coverage settings and existing signing overrides. App/test source, scheme membership and screenshot scenarios are unchanged. Only Swift package downloads/checkouts are cached, keyed by OS, architecture, toolchain and committed Package.resolved hash. There is no DerivedData cache or build artifact reuse. Each job explicitly boots its selected destination and runs test execution serially (`-parallel-testing-enabled NO`) to avoid extra simulator clones and competing app hosts; both device jobs remain independent. The job budget is 45 minutes, with a 35-minute build/test timeout and a bounded result-export step. Artifact bundles contain build/package logs, xcresult, JSON summary and exported screenshots for UI tiers, retained for 30 days. Missing result bundles, zero passing tests, failed exports and missing UI screenshots fail the job. Failures still attempt artifact upload; force cancellation can prevent complete export/upload.

## Explicit draft UI checkpoints

Use **Actions → iOS UI checkpoint → Run workflow**, select the PR head branch, then supply the open draft PR number and its complete current 40-character head SHA. Choose `standard` (default) or `both` devices. Equivalent CLI:

```sh
gh workflow run ios-ui-checkpoint.yml --ref YOUR_PR_BRANCH \
  -f pr_number=YOUR_PR_NUMBER -f head_sha=YOUR_CURRENT_40_CHARACTER_SHA -f devices=standard
```

The new workflow becomes dispatchable once it exists on the default branch; its first live checkpoint run remains a rollout verification until then. Dispatch requires repository Actions write access. Cross-repository/fork PR checkpoints are rejected. The selected workflow revision must equal the requested PR head, and the PR must still be open and draft. These checks run before testing and again at completion, so a new push, closure or ready transition makes the result fail as stale. In-flight simulator work can still consume minutes after a push; it cannot approve the new revision. Repeating a checkpoint cancels its predecessor without cancelling normal iOS CI or CodeQL.

The run name, validation summaries and artifact `revision.txt` identify the exact SHA. `checkpoint-result` requires successful request validation, every selected device, and a final freshness check. Find screenshots, xcresult, JSON summaries and logs under that run's artifact links; retention is 30 days. This optional workflow has no merge-approval job and must not become a required check. Keep PRs draft during iteration; mark ready only when full validation is wanted.

Checkpoint mappings:

| Change | Deferred/requested UI coverage |
| --- | --- |
| `TodayPlanPresentation.swift`, `TodayPlanCard.swift` | `TodayPlanUITests` |
| Hero card/model | Home dashboard, Hero and Today's Plan |
| Current session card | Home dashboard and Hero |
| Recording forms/ring | `RecordingNavigationTests` |
| Existing UI test file | Its suite, including `TodayPlanUITests` |
| Shared navigation, services, dependencies, CI, unknown/new paths or failed diff | Entire UI target, including future suites |
| Docs and unit tests only | No UI recommendation; explicit empty checkpoints fail |

Selections combine across paths; one broad change expands the entire checkpoint to `ALL`. The reusable runner shares the classifier's allowlist and refuses empty/invalid filters. Routing tests check the discovered UI suite names against the allowlist. Final merge validation never uses these mappings or filters.

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

## CodeQL setup transition

`.github/workflows/codeql.yml` is the advanced setup: Swift uses a traced manual Xcode build, and Actions and Python use build mode `none`. All three use `security-extended` (the default security queries plus additional queries), without path exclusions. Analysis runs on main pushes, PRs to main, merge groups, manual dispatch and weekly on Monday at 04:23 UTC. Scheduled runs start after this workflow reaches the default branch.

GitHub rejects advanced SARIF processing while repository-level CodeQL default setup is enabled. This is a repository setting; changing workflow YAML alone cannot resolve it. An administrator must inspect the current default setup's languages/query suite, preserve any additional coverage, then switch the repository to advanced setup in Settings → Code security → CodeQL analysis. Keep the advanced workflow and every required check enabled. Do not disable uploads, ignore analysis errors, remove required checks, or treat a generated SARIF file as successful processing.

Re-run the complete CodeQL workflow after the setting transition, including the cancelled Swift job, and verify successful server-side processing for `/language:swift`, `/language:actions` and `/language:python` on the current PR revision. Verify iOS CI's full validation on both simulators and all merge gates independently. Before merging, account for any interval before the advanced workflow reaches main; after merging, verify its main-push analysis and weekly schedule. PR #25 is not to be merged automatically.

During this repair, the CLI default-setup/protection endpoints returned Forbidden and the available GitHub connector did not expose setup/protection settings. The browser could not navigate because its runtime returned “Browser Use could not read requirements”. The repository setting transition therefore remains unverified until an administrator completes it and real CodeQL runs process successfully.

## Release validation

A tag push validates the tagged commit, but does not itself prevent publishing. This repository currently has no release deployment job to attach a dependency to. Before publishing/distributing, manually dispatch iOS CI on the exact release candidate ref and require successful full validation of that SHA. Any future release publication workflow must depend on full validation of the same SHA. Protect release tags/rules and publishing permissions to enforce that process; do not interpret a post-tag run as an enforced pre-publication gate.

## Timing baseline and comparison

Measured from retrieved runner logs on 2026-11-15. Job wall duration is first-to-last log timestamp, excluding queue time; these are not workflow end-to-end latency or total billed minutes. UI duration is reported XCTest UI-suite execution. Different revisions and suite counts prevent a controlled speedup claim.

| Pre-v2 run | State/result | Standard job | Compact job | UI execution standard / compact |
| --- | --- | --- | --- | --- |
| [#71 / 43745407835](https://github.com/busrayildiiz/SleepCoach.AI/actions/runs/43745407835) | Ready, successful, 451 unit + 28 UI tests per device | 26m46s | 28m47s | 18m32s / 20m08s |
| [#74 / 43745654036](https://github.com/busrayildiiz/SleepCoach.AI/actions/runs/43745654036) | Ready, successful, older branch with 18 UI tests | 13m09s | 18m49s | 8m39s / 10m14s |
| [#72 / 43745460368](https://github.com/busrayildiiz/SleepCoach.AI/actions/runs/43745460368) | Draft, cancelled at ready transition | XCTest and standard UI jobs cancelled before usable logs | Focused job logged ~6s before cancellation | No completed UI execution; not a draft feedback benchmark |
| [#77 / 43750470682](https://github.com/busrayildiiz/SleepCoach.AI/actions/runs/43750470682) | Draft hotfix, cancelled while queued | No completed XCTest feedback | No completed focused UI feedback | No measurable completed draft duration |

Observed iOS workflow spans, from the classify job's first log to the final compatibility-gate logs, were approximately **29m06s for #71** (18:12:22–18:41:29 UTC) and **36m38s for #74** (18:18:07–18:54:44 UTC). These spans include time waiting between jobs but exclude any queue before classification and exclude the independent CodeQL workflow. #74's macOS jobs started around 18:35:41 UTC, over 17 minutes after classification began; queue delays can outweigh runner-time savings.

Evidence job IDs for #71: standard `132907524598`, compact `132907524613`; #74: `132909257548`, `132909257576`; #72 compact: `132907700199`. Failed/cancelled or queued runs are not treated as successful timings. No recent completed three-tier draft run was available in the inspected revisions; the prior 3–8 minute estimate was not a measurement.

Post-v2 measurements remain pending publication after hotfix integration. On the new PR, first leave it draft until the single `fast-xctest` job completes, record its run/HEAD/job wall and logged package/build-test durations, and verify no UI job exists. Then mark the same HEAD ready and record both full jobs, all test counts, screenshots and merge gates. Compare against #71's 28-UI-test workload with queue time and cold/warm package-cache differences stated. Do not report a percentage improvement until those runs complete. Manual checkpoint positive/stale-head checks also require the workflow to reach main.

The expected cost reduction is removing two automatically scheduled UI simulator jobs per draft update. Complete XCTest still requires Xcode compilation, app-host launch, simulator boot and package resolution; there is no DerivedData cache. Requested UI checkpoints pay for UI build/execution and screenshot export on the selected devices. Ready/full validation retains both complete shared schemes with coverage and artifacts; its cost is deliberately unchanged. Existing Swift/Actions/Python CodeQL jobs remain unchanged; a JavaScript analysis covers the new checkpoint guard. CodeQL remains independent and can still dominate the time until every PR check finishes. Timings are now written to both runner logs and job summaries; artifact revision files bind the evidence to its checkout.

## Local verification

Run `actionlint` and `python3 -m unittest discover -s .github/scripts -p 'test_*.py' -v` before changing routing or gates. Tests cover actual event-routing shell execution, feature/UI suite mappings, unknown/shared changes, invalid diff fallback, focused filter validation, initial/final checkpoint SHA validation (Node tests), and the fail-closed gate across 75 success/failure/cancelled/skipped/missing combinations. XCTest/XCUITest requires macOS/Xcode and must be validated by the PR run.

## First rollout failure and correction

Run 43532365270 exposed two issues: compact failed the existing Still Sleeping end-editor assertion after a center tap on a SwiftUI switch row at accessibility XXXL; standard passed all 15 UI tests but reached the 30-minute job limit after a long simulator startup delay. The compact log also reported a cloned unit-test app host launch failure (NSMachErrorDomain -308). Results and screenshot artifacts were successfully exported for both jobs, and all merge gates correctly remained non-successful.

The correction explicitly boots the destination, serializes test execution to avoid cloned test hosts, and separates the build/test budget from artifact cleanup. It does not retry failed tests or remove coverage. The recording test now taps the trailing switch control, asserts its initial and final values, waits for the end-editor visibility transition, and retains every existing persistence/navigation assertion and screenshot scenario. Build/test timing summaries now include failed command exit codes too. These changes require confirmation from the next macOS run; Linux checks cannot establish simulator success.
