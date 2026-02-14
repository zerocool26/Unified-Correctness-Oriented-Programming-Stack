# Unified-Correctness-Oriented-Programming-Stack

Bootstrap implementation from the shared design conversation:
- Cargo monorepo (`lang`, `runtime`, `tool`)
- Lean semantics kernel (`semantics-lean/`)
- Deterministic scheduler + trace record/replay runtime (`crates/runtime`)
- Program-driven distributed services runtime (DSL in `programs/distributed_services.uco`)

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
  --fault-drop-every <n>      Drop every n-th inbound wire message
  --fault-delay-steps <n>     Delay inbound wire messages by n runtime steps
  --fault-reorder-window <n>  Reverse inbound arrivals in chunks of n
```

## Service Language

Default runtime program: `programs/distributed_services.uco`

Syntax:
- `service <Name>`
- `state <name> = <int>`
- `on <MessageType>`
- `log "<template>"`
- `set <state> <int>`
- `inc <state> [by]`
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

`verify` exits non-zero on invariant violations (sequence/seed consistency and message lifecycle checks).

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

Run local CI parity checks:

```bash
pwsh -File scripts/ci_local.ps1
```

If Lean is installed (`lake` on `PATH`), the local CI script also builds `semantics-lean`.

## Notes

- Determinism contract: external nondeterminism is mediated through runtime trace events (`Deliver`, `NetRecv`, `NetSend`).
- Failure injection decisions are traced via `FaultInjected` events and therefore replay-safe.
- Runtime boot actor creation is traced via `Spawn` events.
- Replay mode consumes recorded events and re-injects `NetRecv` before following `Deliver`.
- Replay mode is strict: it fails if trace deliveries remain after `--steps` or if EOF leaves undelivered inbox messages.
- Replay also verifies emitted side effects (`Send`/`NetSend`) against the trace in-order.
- Runtime behavior is executed from the parsed service language, not hardcoded Rust handlers.

## Branch Protection

Recommended required status checks:
- `Rust Checks (Ubuntu)`
- `Lean Kernel (Ubuntu)`
- `Fault Matrix (Windows)`
