# Confirmed product decisions

These are confirmed product requirements, not a claim that all features exist.
Implementation status below is verified against `main` at `d860622`.
Update status when the corresponding code lands; documentation alone does not authorize a behavior change.

## Sleep accounting

| Confirmed decision | Status on this main baseline |
| --- | --- |
| Night sleep belongs to the Sleep Day on which it starts, together with that day's naps. | Partial: existing summaries group by session start date; explicit Sleep Day completion/provisional state is absent. |
| Sleep Day Total and Rolling 24h Sleep are separate metrics. | Pending: main has start-date daily totals, not a separate clipped rolling 24-hour metric. |
| Subtract explicit, valid, attached awake intervals from sleep. | Partial: `SleepRecord.totalMinutes` subtracts parent-linked break durations; interval clipping and awake unions are absent. |
| Never double-count overlapping sleep records or duplicate awake intervals. | Pending: main sums durations and can double-count overlaps. |

The accounting corrections are implemented on `fix/sleep-day-rolling-accounting`
(`14ac666`, with test-fixture corrections in `810854f`), but neither commit is in this main baseline.
Do not copy that implementation into unrelated tasks or describe it as merged.

Accounting details already confirmed for that work:
- Sleep Day Total is net daytime sleep plus net night sleep starting on that Sleep Day.
- Finalize only after the associated night is completed; ongoing or missing-end totals remain provisional.
- Rolling 24h measures actual net sleep in `[now - 24 elapsed hours, now]`; clip sleep and awake intervals to the window.
- Valid attached awake intervals take precedence over overlapping sleep intervals.
- Flag conflicting nap/night classifications or Sleep Day assignments as data-quality issues; mark affected subtotals unreliable rather than allocating shared time arbitrarily.
- V1 grouping uses the device's current timezone. Preserve timestamps and leave room for future original-timezone metadata.
- Never rewrite timestamps to assign a Sleep Day or promote inferred endings to confirmed observations.
- Keep daytime and rolling 24-hour comparisons against their corresponding age-based ranges.

## Personalization

**Confirmed policy, pending implementation:** personalization requires at least
**7 recent, sufficiently valid recording days**, which need not be consecutive.

Current main differs: `DefaultPhaseAgent` declares personalized mode at 14 tracked days;
the orchestrator counts all distinct sleep/wake dates, without a recent-valid-day eligibility gate.
`DaytimePredictionAgent` labels days 7–13 blended and uses a tracked-days/14 observation weight.
These existing constants are implementation facts, not the confirmed seven-day policy.

The exact recency window and sufficient-validity criteria still need definition.
Do not invent thresholds or change eligibility as part of an accounting or documentation task.

## Free and Premium access

| Confirmed decision | Current implementation status |
| --- | --- |
| Basic sleep tracking remains free. | Tracking is available without subscription checks; a formal entitlement model is not implemented. |
| The first personalized summary is free after sufficient data. | Pending: no first-summary entitlement or consumption lifecycle exists in the inspected active flow. |
| Detailed predictions and AI coaching require Premium. | Pending: current prediction/coach screens do not enforce a Premium entitlement. |
| No automatic subscription enrollment. | No subscription purchase/enrollment flow exists; future enrollment must require explicit user action. |

The README's use of “premium” also describes presentation; it does not demonstrate billing or access control.
The first-free-summary entitlement scope/lifecycle remains to be specified before implementation.

## References

- [Architecture](ARCHITECTURE.md): current code ownership and legacy paths.
- [Existing refactor guide](architecture/sleep-list-view-refactor.md): persistence compatibility and extraction boundaries.
- [README](../README.md): overview; its 14-day discussion describes the older implementation, not the confirmed policy above.
