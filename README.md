# Unified-Correctness-Oriented-Programming-Stack

Bootstrap implementation from the shared design conversation:
- Cargo monorepo (`lang`, `runtime`, `tool`)
- Lean semantics kernel (`semantics-lean/`)
- Deterministic scheduler + trace record/replay runtime (`crates/runtime`)
- Program-driven distributed services runtime (DSL in `programs/distributed_services.uco`)

Detailed engineering contract:
- `docs/FOUNDATION_PLAYBOOK.md`

## Foundation (Brick by Brick)

This stack is built as layered correctness bricks. Each higher brick depends on the one below it.

1. Deterministic execution core
- Runtime scheduling is deterministic for a fixed input trace and config.
- Message IDs and timer IDs are deterministic per node.
- Timers, inbound network events, and delivery order are controlled by runtime policy, not wall clock races.

2. Trace contract as system truth
- Runtime emits immutable trace events for causal decisions and side effects.
- Core event families are `Deliver`, `EffectObserved`, `Send`, `NetSend`, `NetRecv`, `TimerFired`, `FaultInjected`, `FaultPolicy`, `Log`, `Spawn`.
- Any behavior not represented in the trace is treated as nondeterminism debt.

3. Strict replay as executable proof
- Replay mode consumes recorded trace evidence and reconstructs execution.
- Replay validates emitted side effects exactly against trace order.
- Replay rejects partial consumption, extra emitted effects, and undelivered inbox leftovers.
- Replay timer behavior is trace-driven for distributed interleavings (`TimerFired` events drive timer dispatch in replay).

4. Local trace invariant verifier
- `tool verify` enforces message lifecycle, sequencing, effect declaration/observation consistency, timer-send adjacency, and lineage integrity.
- This is the first non-runtime line of defense and must remain strict.

5. Cross-node cluster verifier
- `tool cluster-verify` composes local verification with network-level and lineage-level distributed invariants.
- It validates `NetSend`/`NetRecv`/drop evidence and payload equivalence across traces.
- It validates in-cluster lineage parent consistency across node traces.

6. Scenario harnesses as regression artifacts
- Fault matrix scenarios prove fault policies under replay and verification.
- Closed 2-node, 3-node, mixed-fault 2-node matrix, and mixed-fault 3-node matrix scenarios prove cross-node consistency and replay checks end-to-end.
- Mixed-fault cluster matrices rotate fault targets across nodes under bounded delay/drop/reorder combinations.
- Multi-target mixed-fault 3-node matrix scenarios validate concurrent bounded fault profiles across multiple nodes.
- Matrix indexes are emitted even on scenario failure and include invariant-code rollups for triage.
- Scripts are assertion-bearing tests, not demos.

7. CI as policy enforcement
- Linux jobs gate Rust compile/test and Lean kernel build.
- Windows jobs gate fault matrix, cluster scenarios, mixed-fault closed cluster matrices (2-node + 3-node), multi-target mixed-fault 3-node matrix, and partition/churn envelope 3-node matrix.
- Local CI mirrors policy for fast pre-push failure.

## Development Process (Brick by Brick)

Use this loop for every feature or bug fix:

1. Define invariant first
- Example: "Every replay timer firing must correspond to a traced `TimerFired` and matching emitted event."

2. Reproduce with a failing scenario
- Prefer script-backed distributed scenarios over synthetic unit-only failures.

3. Patch minimal layer
- Runtime for execution semantics.
- Tool for verification semantics.
- Script for scenario policy.
- Do not weaken upper-layer checks to hide lower-layer bugs.

4. Add regression protection
- Add unit/integration tests where practical.
- Add or tighten scenario assertions.

5. Wire into CI path
- Ensure `scripts/ci_local.ps1` and workflow jobs exercise the new invariant.

6. Update contract docs
- Document what became stricter and where it is enforced.

## Current Critical Features

1. Deterministic record/replay runtime with distributed wire support.
2. Effect-aware service DSL with required handler effect declarations.
3. Provenance lineage propagation and validation.
4. Strict local trace verifier (`tool verify`).
5. Strict multi-trace cluster verifier (`tool cluster-verify`).
6. Fault injection with replay-safe trace evidence.
7. Structured verifier diagnostics (`--report-json`) for CI triage.
8. Scripted end-to-end scenarios with CI enforcement.
9. Trend gate enforcement (`invariant_trend_gate.ps1`) with absolute + delta thresholds.
10. Bounded trend history snapshots (`invariant_trend_history.ps1`) with index retention.
11. Partition/churn envelope matrix for higher-order distributed stress.
12. Machine-readable trend signals (`invariant_trend_signals.ps1`) for bot/dashboard consumers.
13. Trend notification/export bridge (`invariant_trend_notify.ps1`) with GitHub summary + optional webhook delivery.
14. Adaptive policy profile resolution from config rules (`profile_resolution` in `configs/invariant-trend-policies.json`).
15. Policy rule lint gate (`invariant_trend_policy_lint.ps1`) preventing misconfigured profile selection/debt metadata.
16. Config-declared profile resolution test cases (`profile_resolution.tests`) executed by lint to prevent mapping drift.

## Next Critical Bricks

1. Adaptive trend gate tuning
- Add automated debt-window renewal reminders/escalation ownership workflows beyond expiry metadata checks.
- Add policy change approval automation (required reviewers/sign-off for threshold or rule relaxations).

2. Historical analytics depth
- Add rollup views over history index (moving windows, rate-of-change, failure bursts).
- Add richer PR annotation adapters and escalation routing policies on top of notification payloads.

3. Dynamic fault choreography
- Add time-phased partition/churn schedules (fault activation windows during a single run).
- Extend scenario assertions to prove recovery trajectories, not only steady-state consistency.

## Workspace Layout

```txt
.
├─ .gitignore
├─ Cargo.lock
├─ Cargo.toml
├─ Dockerfile
├─ docker-compose.yml
├─ crates/
│  ├─ lang/
│  ├─ runtime/
│  └─ tool/
├─ demo-traces/
└─ semantics-lean/
```

## Runtime CLI

```txt
runtime [options]
  --program <path>            Service language program path
  --trace <path>              Trace file path (default: trace.jsonl)
  --replay                    Replay from trace instead of recording
  --node-id <uuid>            Fixed node id for distributed runs
  --listen <host:port>        Listen for wire messages
  --peer <uuid=host:port>     Peer mapping (repeatable)
  --bootstrap-hello           Send hello from this node to all peers at startup
  --bootstrap-burst <n>       Number of hello messages per peer (default: 1)
  --steps <n>                 Max runtime scheduling steps (default: 40)
  --idle-sleep-ms <n>         Sleep n ms on idle steps (record mode only)
  --startup-wait-ms <n>       Wait n ms before scheduling loop (record mode only)
  --fault-drop-every <n>      Drop every n-th inbound wire message
  --fault-delay-steps <n>     Delay inbound wire messages by n runtime steps
  --fault-reorder-window <n>  Reverse inbound arrivals in chunks of n
  --fault-phase <s:e:d:l:r>   Override faults for steps [s..e] (e may be *)
```

## Service Language

Default runtime program: `programs/distributed_services.uco`

Syntax:
- `service <Name>`
- `state <name> = <int>`
- `on <MessageType>`
- `effects <effect...>` (required for every handler) where effects are: `log`, `state_read`, `state_write`, `send_local`, `send_remote`, `timer_local`, `timer_remote`
- `log "<template>"`
- `set <state> <int>`
- `inc <state> [by]`
- `timer <steps> <Service> <MessageType> "<template>"`
- `timer <steps> local <Service> <MessageType> "<template>"`
- `timer <steps> remote <peers|sender|node:<uuid>> <Service> <MessageType> "<template>"`
- `if <state> == <int> <action...>`
- `send local <Service> <MessageType> "<template>"`
- `send remote peers <Service> <MessageType> "<template>"`
- `send remote sender <Service> <MessageType> "<template>"`
- `send remote node:<uuid> <Service> <MessageType> "<template>"`

Template variables:
- `$self_node`, `$self_service`
- `$from_node`, `$from_service`
- `$type`, `$text`
- `$state.<name>` for declared per-service state values
- `$prov.origin_node`, `$prov.origin_service`
- `$prov.origin_msg`, `$prov.parent_node`, `$prov.parent_msg`, `$prov.hops`

## Quick Start (Single Node)

Record a run:

```bash
cargo run -p runtime -- --program programs/distributed_services.uco --trace trace.jsonl
```

Replay the exact delivery schedule:

```bash
cargo run -p runtime -- --program programs/distributed_services.uco --replay --trace trace.jsonl
```

Inspect the trace:

```bash
cargo run -p tool -- trace.jsonl
```

Verify trace invariants:

```bash
cargo run -p tool -- verify trace.jsonl
```

Emit structured diagnostics JSON while verifying:

```bash
cargo run -p tool -- verify trace.jsonl --report-json verify.report.json
```

`verify` exits non-zero on invariant violations (sequence/seed consistency and message lifecycle checks).

Verify a closed distributed run across multiple node traces:

```bash
cargo run -p tool -- cluster-verify demo-traces/node1.trace.jsonl demo-traces/node2.trace.jsonl demo-traces/node3.trace.jsonl
```

Emit structured diagnostics JSON while cluster verifying:

```bash
cargo run -p tool -- cluster-verify demo-traces/node1.trace.jsonl demo-traces/node2.trace.jsonl demo-traces/node3.trace.jsonl --report-json cluster.report.json
```

`cluster-verify` first runs local `verify` on each trace, then checks cross-node network evidence:
- every in-cluster `NetSend` must have either matching `NetRecv` or receiver-side `FaultInjected(Drop)`
- matching `NetSend`/`NetRecv` payloads must be identical
- cross-node lineage parent references must resolve consistently when parent nodes are in the provided trace set
- use this for closed runs where all participating node traces are provided and steps are high enough to drain in-cluster traffic

Inspect provenance lineage summary:

```bash
cargo run -p tool -- lineage trace.jsonl
```

Trace one message lineage path (`from_node` + `msg_id`):

```bash
cargo run -p tool -- lineage-path trace.jsonl 00000000-0000-0000-0000-000000000302 00000000-0000-0000-0000-000000000304
```

## Lean Kernel

Build the formal kernel:

```bash
cd semantics-lean
lake build
```

## Distributed 3-Node Demo (Docker Compose)

Run the demo:

```bash
docker compose up --build
```

This starts:
- `node1` (bootstraps hello messages)
- `node2`
- `node3`

Each node writes a trace to:
- `demo-traces/node1.trace.jsonl`
- `demo-traces/node2.trace.jsonl`
- `demo-traces/node3.trace.jsonl`

Inspect one trace:

```bash
cargo run -p tool -- demo-traces/node1.trace.jsonl
```

Replay one node locally from its trace:

```bash
cargo run -p runtime -- --replay --node-id 00000000-0000-0000-0000-000000000101 --trace demo-traces/node1.trace.jsonl
```

Fault-injected run example:

```bash
cargo run -p runtime -- --listen 127.0.0.1:7001 --trace trace.jsonl --fault-drop-every 3 --fault-delay-steps 2 --fault-reorder-window 2
```

## Scripted Fault Scenario (with assertions)

Run an end-to-end two-node scenario where node2 drops every inbound network message and verifies trace invariants:

```bash
pwsh -File scripts/fault_scenario.ps1
```

The script asserts:
- at least one `FaultInjected` event exists in node2 trace
- zero `NetRecv` events exist for node2 when `--fault-drop-every 1` is active

Run a full matrix (`drop`, `delay`, `reorder`) with per-scenario assertions and replay checks:

```bash
pwsh -File scripts/fault_matrix.ps1
```

CI executes this same matrix on `windows-latest` via `.github/workflows/ci.yml`.
CI also executes closed two-node, closed three-node, mixed-fault closed two-node matrix, mixed-fault closed three-node matrix, and multi-target mixed-fault three-node matrix scenarios on `windows-latest`.
CI also executes partition/churn envelope three-node matrix scenarios, invariant trend gating, and invariant trend history retention on `windows-latest`.

Run local CI parity checks:

```bash
pwsh -File scripts/ci_local.ps1
```

Local CI runs:
- Rust format/check/test
- fault matrix
- closed two-node cluster scenario
- closed three-node cluster scenario
- mixed-fault closed two-node cluster matrix
- mixed-fault closed three-node cluster matrix
- multi-target mixed-fault closed three-node matrix
- partition/churn envelope three-node matrix
- phased choreography closed three-node matrix
- invariant trend summary from matrix indexes
- invariant trend policy lint (profile/rule/debt metadata validation)
- invariant trend policy gate (profile-driven thresholds with config-based branch/source auto resolution)
- invariant trend debt-window guard (warnings + strict-profile fail mode for near-expiry windows)
- invariant trend history snapshot/index retention
- invariant trend history analytics
- invariant trend signals synthesis (machine-readable status for dashboards/bots)
- invariant trend notification/export synthesis (markdown + JSON payload + optional webhook delivery)
- artifact storage guard for generated `demo-traces` outputs
- Lean kernel build if `lake` is installed on `PATH`

Run a closed two-node cluster scenario (bidirectional listeners + cluster verify):

```bash
pwsh -File scripts/cluster_scenario.ps1
```

Run a closed three-node cluster scenario (full mesh listeners + cluster verify):

```bash
pwsh -File scripts/cluster3_scenario.ps1
```

Run a mixed-fault closed two-node cluster scenario (configurable fault target + replay + cluster verify):

```bash
pwsh -File scripts/cluster_fault_scenario.ps1
```

Example: rotate the mixed fault policy to `node1`:

```bash
pwsh -File scripts/cluster_fault_scenario.ps1 -FaultTarget node1 -FaultDelaySteps 2 -FaultReorderWindow 2
```

Run the mixed-fault closed two-node matrix (multiple bounded fault combinations + fault-target rotation + index artifact):

```bash
pwsh -File scripts/cluster_fault_matrix.ps1
```

Run the mixed-fault closed three-node matrix (multiple bounded fault combinations + fault-target rotation + index artifact):

```bash
pwsh -File scripts/cluster3_fault_matrix.ps1
```

Run the multi-target mixed-fault closed three-node matrix (concurrent bounded fault profiles + index artifact):

```bash
pwsh -File scripts/cluster3_multi_fault_matrix.ps1
```

Run the partition/churn envelope closed three-node matrix (partition-like + churn-like stress envelopes + index artifact):

```bash
pwsh -File scripts/cluster3_envelope_matrix.ps1
```

Build stable invariant trend summaries from matrix indexes:

```bash
pwsh -File scripts/invariant_trends.ps1
```

Compare against a previous summary baseline:

```bash
pwsh -File scripts/invariant_trends.ps1 -PreviousSummaryPath demo-traces/invariant-trends.prev.json
```

Enforce trend policy thresholds (absolute + delta):

```bash
pwsh -File scripts/invariant_trend_gate.ps1 -SummaryPath demo-traces/invariant-trends.summary.json -GateReportPath demo-traces/invariant-trends.gate.json -MaxTotalIssues 0 -MaxLocalIssues 0 -MaxClusterIssues 0 -MaxTotalDeltaIncrease 0 -MaxLocalDeltaIncrease 0 -MaxClusterDeltaIncrease 0 -MaxSingleCodeDeltaIncrease 0
```

Lint trend policy profile/rule/debt-window configuration:

```bash
pwsh -File scripts/invariant_trend_policy_lint.ps1 -PolicyFilePath configs/invariant-trend-policies.json -ReportPath demo-traces/invariant-trends.policy-lint.json
```

Enforce thresholds through a named policy profile:

```bash
pwsh -File scripts/invariant_trend_policy.ps1 -SummaryPath demo-traces/invariant-trends.summary.json -PolicyFilePath configs/invariant-trend-policies.json -Profile strict -GateReportPath demo-traces/invariant-trends.gate.json -PolicyReportPath demo-traces/invariant-trends.policy.json
```

Resolve profile automatically from `profile_resolution` rules:

```bash
pwsh -File scripts/invariant_trend_policy.ps1 -SummaryPath demo-traces/invariant-trends.summary.json -PolicyFilePath configs/invariant-trend-policies.json -BranchName feature/my-change -RunSource local -GateReportPath demo-traces/invariant-trends.gate.json -PolicyReportPath demo-traces/invariant-trends.policy.json
```

Validate debt-window metadata/expiry across policy profiles:

```bash
pwsh -File scripts/invariant_trend_debt_windows.ps1 -PolicyFilePath configs/invariant-trend-policies.json -ReportPath demo-traces/invariant-trends.debt-windows.json -WarnDays 14 -FailDays 7
```

Build compact machine-readable trend signals:

```bash
pwsh -File scripts/invariant_trend_signals.ps1 -SummaryPath demo-traces/invariant-trends.summary.json -GateReportPath demo-traces/invariant-trends.gate.json -PolicyReportPath demo-traces/invariant-trends.policy.json -DebtWindowReportPath demo-traces/invariant-trends.debt-windows.json -AnalyticsPath demo-traces/invariant-history/analytics.json -SignalsPath demo-traces/invariant-trends.signals.json
```

Build notification/export artifacts and optionally deliver to a webhook:

```bash
pwsh -File scripts/invariant_trend_notify.ps1 -SignalsPath demo-traces/invariant-trends.signals.json -SummaryPath demo-traces/invariant-trends.summary.json -MarkdownPath demo-traces/invariant-trends.notify.md -PayloadPath demo-traces/invariant-trends.notify.payload.json -MinSeverity warn -AppendGitHubStepSummary
```

For CI webhook delivery, set secret `INVARIANT_TREND_WEBHOOK_URL`; set repo variable `INVARIANT_TREND_NOTIFY_FAIL_ON_DELIVERY=true` to fail the run when webhook delivery fails.

Persist trend history snapshots with bounded retention:

```bash
pwsh -File scripts/invariant_trend_history.ps1 -SummaryPath demo-traces/invariant-trends.summary.json -HistoryDir demo-traces/invariant-history -IndexPath demo-traces/invariant-history/index.json -MaxEntries 120
```

Enforce a bounded storage budget for generated trace/report artifacts:

```bash
pwsh -File scripts/artifact_storage_guard.ps1 -MaxTotalMB 64 -KeepLatest 120 -MinKeep 60
```

The multi-target matrix drives higher stress envelopes using:
- per-scenario `NodeSteps`/`ReplaySteps`
- node1 bootstrap burst pressure (`BootstrapBurst`)
- minimum active concurrent fault targets (`MinActiveFaultNodes=2`)
- minimum cluster evidence threshold (`MinClusterEvidence`)

The matrices write:
- `demo-traces/cluster-fault-matrix.index.json`
- `demo-traces/cluster3-fault-matrix.index.json`
- `demo-traces/cluster3-multi-fault-matrix.index.json`
- `demo-traces/cluster3-envelope-fault-matrix.index.json`
- `demo-traces/invariant-trends.summary.json`
- `demo-traces/invariant-trends.summary.md`
- `demo-traces/invariant-trends.gate.json`
- `demo-traces/invariant-trends.policy-lint.json`
- `demo-traces/invariant-trends.policy.json`
- `demo-traces/invariant-trends.debt-windows.json`
- `demo-traces/invariant-trends.signals.json`
- `demo-traces/invariant-trends.notify.md`
- `demo-traces/invariant-trends.notify.payload.json`
- `demo-traces/invariant-history/index.json`
- `demo-traces/artifact-storage.summary.json`

Each index links scenarios to traces and `--report-json` artifacts and includes:
- pass/fail counts
- aggregate fault/traffic/cluster-verify counters
- aggregate fault counts by target and by node
- invariant-code bucket rollups (`local_verify` and `cluster_verify`)

All matrix scripts continue through all scenarios, write index artifacts, and then fail if any scenario failed.

CI restores the previous trend summary from a branch-local cache, computes `delta_from_previous`, enforces trend thresholds, appends a bounded trend history snapshot/index, saves the new baseline for the next run, and enforces an artifact storage budget before uploading trace artifacts.
CI lints profile-resolution/debt-window policy configuration before policy gating.
CI resolves trend policy profiles from `profile_resolution` branch/source rules, then validates debt-window metadata and expiration; strict profile runs fail when windows are within 7 days of expiry.
CI also synthesizes invariant trend signals into a compact JSON report for bot/dashboard consumption.
CI also generates a notification markdown/payload artifact, appends it to GitHub step summary, and can post to a configured webhook via `INVARIANT_TREND_WEBHOOK_URL`.

All cluster scripts run local `tool verify` on each trace, replay checks (`runtime --replay`) per node, and `tool cluster-verify`.

## Notes

- Determinism contract: external nondeterminism is mediated through runtime trace events (`Deliver`, `NetRecv`, `NetSend`).
- Failure injection decisions and phase transitions are traced via `FaultInjected` and `FaultPolicy` events and are replay-safe.
- Runtime boot actor creation is traced via `Spawn` events.
- Timer actions are traced via `TimerFired` and replay-checked for deterministic firing order.
- Service `log` side effects are traced via `Log` events and replay-checked in-order.
- Every `Deliver` is followed by `EffectObserved`, recording declared vs observed handler effects for that delivery.
- Program load requires explicit `effects ...` declarations for every handler.
- Replay mode consumes recorded events and re-injects `NetRecv` before following `Deliver`.
- Replay mode is strict: it fails if trace deliveries remain after `--steps` or if EOF leaves undelivered inbox messages.
- Replay also verifies emitted side effects (`EffectObserved`/`Send`/`NetSend`/`Log`) against the trace in-order.
- `tool verify` enforces that observed effects are a subset of declared effects and that effect evidence appears after each delivery.
- `tool cluster-verify` enforces cross-node `NetSend`/`NetRecv`/drop consistency and in-cluster lineage parent consistency for closed distributed runs.
- `--startup-wait-ms` can be used in record mode to avoid startup race sends before peers are listening.
- Runtime payloads carry provenance lineage (origin/parent/hops), and `tool verify` checks lineage consistency.
- Runtime behavior is executed from the parsed service language, not hardcoded Rust handlers.
- Trend policy profiles can include optional debt windows with explicit `allow_until_utc`, `owner`, and `tracking_issue` metadata; expired windows fail closed.
- Trend policy profile selection can be rule-driven (`profile_resolution`) using branch exact/glob/regex plus run source and pull request context.
- Trend policy lint validates rule/profile references, selector sanity, debt-window metadata, and `profile_resolution.tests` expected mappings before policy gate execution.
- Generated matrix/trend artifacts under `demo-traces` are gitignored and bounded by `artifact_storage_guard.ps1` plus bounded trend history retention (`invariant_trend_history.ps1`) to prevent repository bloat while preserving source development files.

## Branch Protection

Recommended required status checks:
- `Rust Checks (Ubuntu)`
- `Lean Kernel (Ubuntu)`
- `Fault Matrix (Windows)`
- `Cluster Scenarios (Windows)`
