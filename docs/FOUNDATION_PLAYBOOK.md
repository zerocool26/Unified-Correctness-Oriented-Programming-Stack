# Foundation Playbook (Brick by Brick)

This document is the operational contract for developing this stack.
It defines what each correctness brick guarantees, how to change the system safely, and how to decide what to build next.

## Why This Exists

The project is a correctness-first runtime and verification stack.
The easiest way to damage correctness is to make local fixes that bypass global invariants.
This playbook keeps development layered so each change strengthens, not weakens, the foundation.

## System Bricks

### Brick 1: Deterministic Runtime Core

Goal:
- Same input + same trace + same configuration => same behavior.

Guarantees:
- Deterministic scheduling tie-breaks.
- Deterministic `msg_id` generation per node.
- Deterministic timer IDs.
- Runtime behavior driven by explicit control flow, not implicit thread timing.

Failure mode if broken:
- Replay drift, impossible forensic analysis, non-reproducible bugs.

### Brick 2: Trace as Source of Truth

Goal:
- Externalized, append-only evidence for all meaningful runtime decisions.

Guarantees:
- Trace captures delivery, network ingress/egress, timer firing, effects, logs, faults, and actor spawn.
- Nothing critical is "in runtime only" without trace evidence.

Failure mode if broken:
- Hidden nondeterminism and unverifiable behavior.

### Brick 3: Strict Replay Engine

Goal:
- Replay is executable proof that trace and runtime semantics match.

Guarantees:
- Replay rejects missing, extra, or misordered emitted events.
- Replay rejects early stop and undelivered inbox leftovers.
- Replay consumes inbound network evidence and timer evidence from trace.
- Timer emission in replay follows traced `TimerFired` events.

Failure mode if broken:
- False confidence from passing record runs that cannot be re-executed.

### Brick 4: Local Invariant Verifier (`tool verify`)

Goal:
- Catch single-trace correctness failures independent of runtime internals.

Guarantees:
- Delivery/effect coupling checks.
- Declared vs observed effect checks.
- Timer-to-send evidence checks.
- Message lifecycle and provenance consistency checks.

Failure mode if broken:
- Local traces look plausible but violate semantic contracts.

### Brick 5: Cluster Invariant Verifier (`tool cluster-verify`)

Goal:
- Prove closed-run cross-node consistency.

Guarantees:
- Every in-cluster `NetSend` is explained by matching `NetRecv` or traced drop fault.
- Payload equality across send/recv pairs.
- Cross-trace lineage parent consistency when parents are in-cluster.

Failure mode if broken:
- Per-node correctness with global inconsistency.

### Brick 6: Scenario Harnesses

Goal:
- Convert contracts into executable regression artifacts.

Guarantees:
- Fault matrix validates drop/delay/reorder behavior under replay + verify.
- Closed 2-node and 3-node scenarios validate end-to-end trace + replay + cluster checks.
- Mixed-fault closed 2-node and 3-node cluster matrices validate bounded drop/delay/reorder combinations with cluster-verify and fault-target rotation.
- Multi-target mixed-fault 3-node matrix validates concurrent bounded fault profiles across multiple nodes.
- Multi-target mixed-fault 3-node matrix enforces at least two active concurrent fault targets and bounded minimum cluster evidence under burst-driven traffic pressure.
- Partition/churn envelope 3-node matrix validates partition-like and churn-like stress envelopes with replay + verify + cluster-verify.
- Scenario failures surface structured verifier diagnostics (`--report-json`) including invariant code and first-failure context.
- Matrix execution emits machine-readable indexes linking scenario traces/reports with pass/fail status, aggregate fault/traffic/cluster counters, and invariant-code bucket rollups.
- Matrix scripts continue through all scenarios so failure artifacts are retained before returning non-zero.
- Script failures are hard failures (non-zero) in local and CI flows.

Failure mode if broken:
- Regressions only discovered in ad-hoc manual testing.

### Brick 7: CI Enforcement

Goal:
- Ensure every push is checked against the same correctness policy.

Guarantees:
- Rust checks + tests.
- Lean kernel build.
- Windows fault and cluster scenarios.
- Invariant trend summaries are generated and compared against prior baseline snapshots.
- Invariant trend gate enforces absolute and delta thresholds in local/CI flows.
- Trend policy profile selection is rule-driven from branch/source context when profile is not explicitly set.
- Trend policy profiles support explicit temporary debt windows with expiration metadata and fail-closed expiry behavior.
- CI validates debt-window metadata/expiry across profiles and can fail protected branches for near-expiry windows.
- Trend history snapshots are persisted with bounded retention for longitudinal analysis.
- Trend signals are synthesized into a compact machine-readable report for bots/dashboards.
- Trend notifications/export artifacts are synthesized from signals and can be delivered to external webhooks.
- Generated artifact storage is bounded by retention policy.

Failure mode if broken:
- Correctness checks become optional and drift over time.

## Development Process (Brick by Brick)

Use this sequence for every change.

1. State invariant in one sentence.
- Example: "Replay timer firing must be driven by traced `TimerFired` order."

2. Reproduce with executable evidence.
- Prefer failing script/test over anecdotal bug description.

3. Fix lowest responsible brick.
- Runtime semantics bug -> runtime.
- Validation gap -> tool.
- Coverage gap -> scripts/CI.
- Avoid weakening verifier/script checks to pass.

4. Add permanent regression coverage.
- Unit test for local behavior.
- Scenario assertion for end-to-end behavior.

5. Run policy gate locally.
- `pwsh -File scripts/ci_local.ps1`

6. Update contract docs.
- Record what invariant got stronger and where it is enforced.

## Definition of Done (DoD)

A change is done only if all are true:
- Invariant is explicitly documented.
- Failing reproduction exists before fix (or equivalent evidence).
- Fix is in the minimal correct layer.
- Regression protection added.
- Local CI passes.
- No verifier weakening to "make tests green."

## Change Acceptance Checklist

Before merging:
- [ ] `cargo fmt --all -- --check`
- [ ] `cargo check --workspace --all-targets --locked`
- [ ] `cargo test --workspace --locked`
- [ ] `pwsh -File scripts/ci_local.ps1`
- [ ] Updated docs for changed guarantees
- [ ] New or updated scenario assertions if behavior changed

## Anti-Patterns (Do Not Do)

- "Fix" by relaxing replay/verify/cluster checks without root-cause remediation.
- Add feature behavior that is not represented in trace.
- Merge scenario scripts that don’t return hard failures on command errors.
- Treat demos as tests (all scenarios should assert, not only print).
- Accept flaky behavior as normal under deterministic modes.

## Prioritization Framework

When choosing next work, prioritize in this order:

1. Soundness bugs
- Anything that can produce false correctness positives.

2. Reproducibility gaps
- Behavior that cannot be replayed or diagnosed from traces.

3. Coverage gaps in executable contracts
- Missing scenario/test around known high-risk paths.

4. Developer velocity improvements
- Better diagnostics, clearer failure summaries, faster local CI feedback.

## Current Highest-Leverage Next Bricks

1. Adaptive trend policy profiles
- Add debt-window renewal reminder/escalation workflows on top of current metadata/expiry enforcement.
- Add validation/lint checks for profile resolution rules to prevent accidental policy drift.

2. Historical analytics and alerting
- Build rollup metrics from history (moving windows, slope/drift, failure burst detection).
- Add richer PR annotation adapters and escalation routing policies on top of existing webhook export payloads.

3. Time-phased fault choreography
- Add within-run fault phase transitions (enter/exit partition/churn windows).
- Extend assertions to verify convergence/recovery trajectories after fault withdrawal.

## Ownership Model

Every contributor touching runtime/tool/scripts should:
- Preserve strictness first.
- Add regression evidence.
- Keep docs aligned with actual enforcement.

If a strict check must be temporarily reduced, it must include:
- a tracking issue,
- a failing reproduction,
- a target restoration plan.
