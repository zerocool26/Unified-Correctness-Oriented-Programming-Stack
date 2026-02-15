use anyhow::{bail, Context, Result};
use runtime::event::{ActorId, EffectKind, EventKind, FaultAction, MsgId, TraceEvent};
use runtime::trace::TraceReader;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use uuid::Uuid;

enum Command {
    Summary {
        path: String,
    },
    Verify {
        path: String,
        report_json: Option<String>,
    },
    LineageSummary {
        path: String,
    },
    LineagePath {
        path: String,
        node: runtime::event::NodeId,
        msg_id: MsgId,
    },
    ClusterVerify {
        paths: Vec<String>,
        report_json: Option<String>,
    },
}

#[derive(Debug, Clone, serde::Serialize)]
struct ProblemDetail {
    code: &'static str,
    seq: Option<u64>,
    node: Option<String>,
    actor: Option<String>,
    msg_id: Option<String>,
    message: String,
}

#[derive(Debug, Clone, serde::Serialize)]
struct VerifyDiagnosticsReport {
    mode: &'static str,
    path: String,
    ok: bool,
    pending_messages: usize,
    issue_count: usize,
    first_issue: Option<ProblemDetail>,
    issues: Vec<ProblemDetail>,
}

#[derive(Debug, Clone, serde::Serialize)]
struct LocalTraceDiagnostics {
    path: String,
    ok: bool,
    pending_messages: usize,
    issue_count: usize,
    first_issue: Option<ProblemDetail>,
    issues: Vec<ProblemDetail>,
}

#[derive(Debug, Clone, serde::Serialize)]
struct ClusterDiagnostics {
    matched_recv: usize,
    matched_drop: usize,
    resolved_lineage_parents: usize,
    external_lineage_parents: usize,
    external_inbound: usize,
    external_outbound: usize,
    issue_count: usize,
    first_issue: Option<ProblemDetail>,
    issues: Vec<ProblemDetail>,
}

#[derive(Debug, Clone, serde::Serialize)]
struct ClusterVerifyDiagnosticsReport {
    mode: &'static str,
    ok: bool,
    traces: Vec<String>,
    local: Vec<LocalTraceDiagnostics>,
    cluster: Option<ClusterDiagnostics>,
}

fn usage_message() -> &'static str {
    "usage:\n  cargo run -p tool -- <trace.jsonl>\n  cargo run -p tool -- summary <trace.jsonl>\n  cargo run -p tool -- verify <trace.jsonl> [--report-json <path>]\n  cargo run -p tool -- cluster-verify <trace1.jsonl> <trace2.jsonl> [traceN.jsonl...] [--report-json <path>]\n  cargo run -p tool -- lineage <trace.jsonl>\n  cargo run -p tool -- lineage-path <trace.jsonl> <from_node_uuid> <msg_id_uuid>"
}

fn split_report_json_flag(args: &[String]) -> Result<(Vec<String>, Option<String>)> {
    let mut out = Vec::new();
    let mut report_json = None;
    let mut i = 0usize;
    while i < args.len() {
        if args[i] == "--report-json" {
            i += 1;
            let value = args.get(i).context("missing value for --report-json")?;
            if report_json.is_some() {
                bail!("duplicate --report-json");
            }
            report_json = Some(value.clone());
        } else {
            out.push(args[i].clone());
        }
        i += 1;
    }
    Ok((out, report_json))
}

fn parse_command() -> Result<Command> {
    let raw_args: Vec<String> = std::env::args().skip(1).collect();
    let (args, report_json) = split_report_json_flag(&raw_args)?;

    match args.as_slice() {
        [path] if report_json.is_none() => Ok(Command::Summary { path: path.clone() }),
        [cmd, path] if cmd == "summary" => {
            if report_json.is_some() {
                bail!("--report-json is only valid with verify or cluster-verify");
            }
            Ok(Command::Summary { path: path.clone() })
        }
        [cmd, path] if cmd == "verify" => Ok(Command::Verify {
            path: path.clone(),
            report_json,
        }),
        [cmd, paths @ ..] if cmd == "cluster-verify" => {
            if paths.len() < 2 {
                bail!("cluster-verify requires at least 2 trace paths");
            }
            Ok(Command::ClusterVerify {
                paths: paths.to_vec(),
                report_json,
            })
        }
        [cmd, path] if cmd == "lineage" => {
            if report_json.is_some() {
                bail!("--report-json is only valid with verify or cluster-verify");
            }
            Ok(Command::LineageSummary { path: path.clone() })
        }
        [cmd, path, node, msg_id] if cmd == "lineage-path" => {
            if report_json.is_some() {
                bail!("--report-json is only valid with verify or cluster-verify");
            }
            let node =
                Uuid::parse_str(node).map_err(|_| anyhow::anyhow!("invalid node id `{node}`"))?;
            let msg_id = Uuid::parse_str(msg_id)
                .map_err(|_| anyhow::anyhow!("invalid msg id `{msg_id}`"))?;
            Ok(Command::LineagePath {
                path: path.clone(),
                node,
                msg_id,
            })
        }
        _ => bail!("{}", usage_message()),
    }
}

fn classify_problem(problem: &str) -> &'static str {
    if problem.contains("seq mismatch") {
        "trace_seq_mismatch"
    } else if problem.contains("seed mismatch") {
        "trace_seed_mismatch"
    } else if problem.contains("without prior Send/NetRecv") {
        "deliver_without_source"
    } else if problem.contains("without EffectObserved") {
        "deliver_without_effect_observed"
    } else if problem.contains("without preceding Deliver") {
        "effect_without_deliver"
    } else if problem.contains("does not match preceding Deliver") {
        "effect_deliver_mismatch"
    } else if problem.contains("undeclared observed effects") {
        "effect_undeclared_observed"
    } else if problem.contains("duplicate declared effects") {
        "effect_declared_duplicate"
    } else if problem.contains("duplicate observed effects") {
        "effect_observed_duplicate"
    } else if problem.contains("payload decode failed") {
        "payload_decode_failed"
    } else if problem.contains("payload missing provenance") {
        "payload_missing_provenance"
    } else if problem.contains("invalid provenance field") {
        "payload_invalid_provenance_field"
    } else if problem.contains("has hops=0 but") {
        "lineage_invalid_root"
    } else if problem.contains("has hops>0 but parent_msg_id is self") {
        "lineage_parent_self"
    } else if problem.contains("does not match parent") || problem.contains("has hops=") {
        "lineage_parent_mismatch"
    } else if problem.contains("dropped earlier but later NetRecv observed") {
        "fault_drop_recv_conflict"
    } else if problem.contains("TimerFired") && problem.contains("not followed by Send/NetSend") {
        "timer_without_immediate_emit"
    } else if problem.contains("TimerFired") && problem.contains("expected next send from actor") {
        "timer_emit_actor_mismatch"
    } else if problem.contains("TimerFired")
        && problem.contains("reached end-of-trace without Send/NetSend")
    {
        "timer_without_emit_end_of_trace"
    } else if problem.contains("unknown actor") {
        "unknown_actor_reference"
    } else if problem.contains("no matching NetRecv or Drop fault") {
        "cluster_send_missing_inbound_evidence"
    } else if problem.contains("has no matching NetSend in provided traces") {
        "cluster_missing_send"
    } else if problem.contains("payload mismatch") {
        "cluster_payload_mismatch"
    } else if problem.contains("has both NetRecv and Drop fault evidence") {
        "cluster_conflicting_recv_and_drop"
    } else if problem.contains("missing in-cluster parent") {
        "cluster_missing_lineage_parent"
    } else if problem.contains("duplicate NetSend key")
        || problem.contains("duplicate NetRecv key")
        || problem.contains("duplicate Drop fault key")
    {
        "cluster_duplicate_network_key"
    } else if problem.contains("duplicate delivered lineage key") {
        "cluster_duplicate_lineage_key"
    } else if problem.contains("invalid parent reference") {
        "lineage_invalid_parent_reference"
    } else if problem.contains("mixes multiple node ids") {
        "cluster_trace_mixed_nodes"
    } else if problem.contains("has no node-scoped events") {
        "cluster_trace_missing_node_scope"
    } else {
        "unknown"
    }
}

fn extract_first_u64_after(problem: &str, marker: &str) -> Option<u64> {
    let idx = problem.find(marker)?;
    let rest = &problem[idx + marker.len()..];
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return None;
    }
    digits.parse::<u64>().ok()
}

fn parse_uuid_token(raw: &str) -> Option<String> {
    let token =
        raw.trim_matches(|c: char| c != '-' && !c.is_ascii_hexdigit() && c != '/' && c != '`');
    for candidate in token.split('/') {
        if Uuid::parse_str(candidate).is_ok() {
            return Some(candidate.to_string());
        }
    }
    None
}

fn extract_uuid_after(problem: &str, marker: &str) -> Option<String> {
    let idx = problem.find(marker)?;
    let rest = &problem[idx + marker.len()..];
    let token = rest
        .split(|c: char| c.is_whitespace() || c == ',' || c == ')' || c == ']' || c == ';')
        .next()?;
    parse_uuid_token(token)
}

fn extract_all_uuids(problem: &str) -> Vec<String> {
    let mut out = Vec::new();
    for token in problem.split(|c: char| {
        c.is_whitespace()
            || c == ','
            || c == ':'
            || c == '('
            || c == ')'
            || c == '['
            || c == ']'
            || c == ';'
    }) {
        if let Some(uuid) = parse_uuid_token(token) {
            if !out.contains(&uuid) {
                out.push(uuid);
            }
        }
    }
    out
}

fn build_problem_detail(problem: &str) -> ProblemDetail {
    let seq = extract_first_u64_after(problem, "seq ");
    let mut msg_id = extract_uuid_after(problem, "msg_id=")
        .or_else(|| extract_uuid_after(problem, "msg_id "))
        .or_else(|| extract_uuid_after(problem, "msg_id"));
    let mut node = extract_uuid_after(problem, "node=")
        .or_else(|| extract_uuid_after(problem, "from_node="))
        .or_else(|| extract_uuid_after(problem, "local_node="));
    let actor = extract_uuid_after(problem, "actor=")
        .or_else(|| extract_uuid_after(problem, "actor "))
        .or_else(|| extract_uuid_after(problem, "to="))
        .or_else(|| extract_uuid_after(problem, "from actor "));

    let uuids = extract_all_uuids(problem);
    if node.is_none() {
        node = uuids.first().cloned();
    }
    if msg_id.is_none() {
        msg_id = uuids.get(1).cloned();
    }

    ProblemDetail {
        code: classify_problem(problem),
        seq,
        node,
        actor,
        msg_id,
        message: problem.to_string(),
    }
}

fn write_json_report<T: serde::Serialize>(path: &str, report: &T) -> Result<()> {
    let json = serde_json::to_string_pretty(report).context("serialize report json")?;
    fs::write(path, json).with_context(|| format!("write report json `{path}`"))?;
    Ok(())
}

fn event_kind_name(kind: &EventKind) -> &'static str {
    match kind {
        EventKind::Spawn { .. } => "Spawn",
        EventKind::Send { .. } => "Send",
        EventKind::Deliver { .. } => "Deliver",
        EventKind::TimerFired { .. } => "TimerFired",
        EventKind::NetRecv { .. } => "NetRecv",
        EventKind::NetSend { .. } => "NetSend",
        EventKind::Log { .. } => "Log",
        EventKind::EffectObserved { .. } => "EffectObserved",
        EventKind::FaultInjected { .. } => "FaultInjected",
        EventKind::FaultPolicy { .. } => "FaultPolicy",
    }
}

fn read_events(path: &str) -> Result<Vec<TraceEvent>> {
    let mut reader = TraceReader::open(path)?;
    let mut events = Vec::new();
    while let Some(ev) = reader.next()? {
        events.push(ev);
    }
    Ok(events)
}

fn print_summary(path: &str, events: &[TraceEvent]) {
    let mut by_kind: BTreeMap<&'static str, u64> = BTreeMap::new();
    for ev in events {
        *by_kind.entry(event_kind_name(&ev.kind)).or_insert(0) += 1;
    }

    println!("trace: {path}");
    println!("total events: {}", events.len());
    for (kind, count) in by_kind {
        println!("{kind:>10}: {count}");
    }
}

struct VerifyReport {
    problems: Vec<String>,
    pending_messages: usize,
}

#[derive(Debug, Clone)]
struct ClusterTrace {
    path: String,
    events: Vec<TraceEvent>,
}

#[derive(Debug, Clone, Default)]
struct ClusterVerifyReport {
    problems: Vec<String>,
    matched_recv: usize,
    matched_drop: usize,
    resolved_lineage_parents: usize,
    external_lineage_parents: usize,
    external_inbound: usize,
    external_outbound: usize,
}

fn to_problem_details(problems: &[String]) -> Vec<ProblemDetail> {
    problems.iter().map(|p| build_problem_detail(p)).collect()
}

fn build_verify_diagnostics(path: &str, report: &VerifyReport) -> VerifyDiagnosticsReport {
    let issues = to_problem_details(&report.problems);
    VerifyDiagnosticsReport {
        mode: "verify",
        path: path.to_string(),
        ok: issues.is_empty(),
        pending_messages: report.pending_messages,
        issue_count: issues.len(),
        first_issue: issues.first().cloned(),
        issues,
    }
}

fn build_local_trace_diagnostics(path: &str, report: &VerifyReport) -> LocalTraceDiagnostics {
    let issues = to_problem_details(&report.problems);
    LocalTraceDiagnostics {
        path: path.to_string(),
        ok: issues.is_empty(),
        pending_messages: report.pending_messages,
        issue_count: issues.len(),
        first_issue: issues.first().cloned(),
        issues,
    }
}

fn build_cluster_diagnostics(report: &ClusterVerifyReport) -> ClusterDiagnostics {
    let issues = to_problem_details(&report.problems);
    ClusterDiagnostics {
        matched_recv: report.matched_recv,
        matched_drop: report.matched_drop,
        resolved_lineage_parents: report.resolved_lineage_parents,
        external_lineage_parents: report.external_lineage_parents,
        external_inbound: report.external_inbound,
        external_outbound: report.external_outbound,
        issue_count: issues.len(),
        first_issue: issues.first().cloned(),
        issues,
    }
}

#[derive(Debug, Clone, serde::Deserialize)]
struct MessageProvenance {
    origin_node: String,
    origin_service: String,
    origin_msg_id: String,
    #[serde(default)]
    parent_node: String,
    parent_msg_id: String,
    hops: u64,
}

#[derive(Debug, Clone, serde::Deserialize)]
struct RuntimePayload {
    #[serde(rename = "type")]
    msg_type: String,
    from_node: String,
    from_service: String,
    #[serde(default)]
    provenance: Option<MessageProvenance>,
}

#[derive(Debug, Clone)]
struct DeliveredLineage {
    origin_msg_id: MsgId,
    origin_node: String,
    origin_service: String,
    hops: u64,
}

type LineageKey = (Uuid, MsgId);

#[derive(Debug, Clone)]
struct DeliveredPayload {
    seq: u64,
    node: runtime::event::NodeId,
    to: ActorId,
    msg_id: MsgId,
    payload: serde_json::Value,
}

#[derive(Debug, Clone)]
struct LineageRecord {
    key: LineageKey,
    seq: u64,
    local_node: runtime::event::NodeId,
    to: ActorId,
    from_service: String,
    msg_type: String,
    provenance: MessageProvenance,
}

#[derive(Debug, Clone, Default)]
struct LineageSummary {
    total: usize,
    roots: usize,
    resolved_parents: usize,
    unresolved_internal_parents: usize,
    unresolved_external_parents: usize,
    invalid_parent_refs: usize,
    max_hops: u64,
}

fn parse_uuid_field(seq: u64, field: &str, raw: &str, problems: &mut Vec<String>) -> Option<Uuid> {
    match Uuid::parse_str(raw) {
        Ok(v) => Some(v),
        Err(_) => {
            problems.push(format!(
                "Deliver at seq {} has invalid provenance field {}=`{}`",
                seq, field, raw
            ));
            None
        }
    }
}

fn effect_name(effect: EffectKind) -> &'static str {
    match effect {
        EffectKind::Log => "log",
        EffectKind::StateRead => "state_read",
        EffectKind::StateWrite => "state_write",
        EffectKind::SendLocal => "send_local",
        EffectKind::SendRemote => "send_remote",
        EffectKind::TimerLocal => "timer_local",
        EffectKind::TimerRemote => "timer_remote",
    }
}

fn format_effects(effects: &BTreeSet<EffectKind>) -> String {
    effects
        .iter()
        .map(|effect| effect_name(*effect))
        .collect::<Vec<_>>()
        .join(", ")
}

fn verify_payload_lineage(
    seq: u64,
    _local_node: Uuid,
    msg_id: MsgId,
    payload: &serde_json::Value,
    delivered_lineage: &mut HashMap<LineageKey, DeliveredLineage>,
    problems: &mut Vec<String>,
) {
    let runtime_payload: RuntimePayload = match serde_json::from_value(payload.clone()) {
        Ok(m) => m,
        Err(err) => {
            problems.push(format!(
                "Deliver at seq {} msg_id={} payload decode failed: {}",
                seq, msg_id, err
            ));
            return;
        }
    };

    let Some(prov) = runtime_payload.provenance else {
        problems.push(format!(
            "Deliver at seq {} msg_id={} payload missing provenance",
            seq, msg_id
        ));
        return;
    };

    let Some(origin_msg_id) = parse_uuid_field(seq, "origin_msg_id", &prov.origin_msg_id, problems)
    else {
        return;
    };
    let parent_node_raw = if prov.parent_node.is_empty() {
        runtime_payload.from_node.as_str()
    } else {
        prov.parent_node.as_str()
    };
    let Some(parent_node) = parse_uuid_field(seq, "parent_node", parent_node_raw, problems) else {
        return;
    };
    let Some(parent_msg_id) = parse_uuid_field(seq, "parent_msg_id", &prov.parent_msg_id, problems)
    else {
        return;
    };
    let Some(from_node_id) =
        parse_uuid_field(seq, "from_node", &runtime_payload.from_node, problems)
    else {
        return;
    };

    if prov.hops == 0 {
        if origin_msg_id != msg_id {
            problems.push(format!(
                "Deliver at seq {} msg_id={} has hops=0 but origin_msg_id={}",
                seq, msg_id, origin_msg_id
            ));
        }
        if parent_msg_id != msg_id {
            problems.push(format!(
                "Deliver at seq {} msg_id={} has hops=0 but parent_msg_id={}",
                seq, msg_id, parent_msg_id
            ));
        }
        if parent_node != from_node_id {
            problems.push(format!(
                "Deliver at seq {} msg_id={} has hops=0 but parent_node={} != from_node={}",
                seq, msg_id, parent_node, from_node_id
            ));
        }
        if prov.origin_node != runtime_payload.from_node {
            problems.push(format!(
                "Deliver at seq {} msg_id={} has hops=0 but origin_node={} != from_node={}",
                seq, msg_id, prov.origin_node, runtime_payload.from_node
            ));
        }
        if prov.origin_service != runtime_payload.from_service {
            problems.push(format!(
                "Deliver at seq {} msg_id={} has hops=0 but origin_service={} != from_service={}",
                seq, msg_id, prov.origin_service, runtime_payload.from_service
            ));
        }
    } else {
        if parent_node == from_node_id && parent_msg_id == msg_id {
            problems.push(format!(
                "Deliver at seq {} msg_id={} has hops>0 but parent_msg_id is self",
                seq, msg_id
            ));
        }

        let parent_key = (parent_node, parent_msg_id);
        if let Some(parent) = delivered_lineage.get(&parent_key) {
            let expected_hops = parent.hops.saturating_add(1);
            if prov.hops != expected_hops {
                problems.push(format!(
                    "Deliver at seq {} msg_id={} has hops={} but parent {}/{} has hops={}",
                    seq, msg_id, prov.hops, parent_node, parent_msg_id, parent.hops
                ));
            }
            if origin_msg_id != parent.origin_msg_id {
                problems.push(format!(
                    "Deliver at seq {} msg_id={} origin_msg_id={} does not match parent {}/{} origin {}",
                    seq, msg_id, origin_msg_id, parent_node, parent_msg_id, parent.origin_msg_id
                ));
            }
            if prov.origin_node != parent.origin_node {
                problems.push(format!(
                    "Deliver at seq {} msg_id={} origin_node={} does not match parent {}/{} origin_node={}",
                    seq, msg_id, prov.origin_node, parent_node, parent_msg_id, parent.origin_node
                ));
            }
            if prov.origin_service != parent.origin_service {
                problems.push(format!(
                    "Deliver at seq {} msg_id={} origin_service={} does not match parent {}/{} origin_service={}",
                    seq, msg_id, prov.origin_service, parent_node, parent_msg_id, parent.origin_service
                ));
            }
        }
    }

    delivered_lineage.insert(
        (from_node_id, msg_id),
        DeliveredLineage {
            origin_msg_id,
            origin_node: prov.origin_node,
            origin_service: prov.origin_service,
            hops: prov.hops,
        },
    );
}

fn collect_deliveries_with_payload(events: &[TraceEvent]) -> Vec<DeliveredPayload> {
    let mut produced: HashMap<(ActorId, MsgId), Vec<serde_json::Value>> = HashMap::new();
    let mut out = Vec::new();

    for ev in events {
        match &ev.kind {
            EventKind::Send {
                to,
                msg_id,
                payload,
                ..
            }
            | EventKind::NetRecv {
                to,
                msg_id,
                payload,
                ..
            } => {
                produced
                    .entry((*to, *msg_id))
                    .or_default()
                    .push(payload.clone());
            }
            EventKind::Deliver { node, to, msg_id } => {
                let key = (*to, *msg_id);
                if let Some(queue) = produced.get_mut(&key) {
                    if !queue.is_empty() {
                        let payload = queue.remove(0);
                        out.push(DeliveredPayload {
                            seq: ev.seq,
                            node: *node,
                            to: *to,
                            msg_id: *msg_id,
                            payload,
                        });
                    }
                    if queue.is_empty() {
                        produced.remove(&key);
                    }
                }
            }
            _ => {}
        }
    }

    out
}

fn lineage_parent_key(rec: &LineageRecord) -> Result<LineageKey> {
    let parent_node = if rec.provenance.parent_node.is_empty() {
        rec.key.0
    } else {
        Uuid::parse_str(&rec.provenance.parent_node)
            .with_context(|| format!("invalid parent_node `{}`", rec.provenance.parent_node))?
    };
    let parent_msg_id = Uuid::parse_str(&rec.provenance.parent_msg_id)
        .with_context(|| format!("invalid parent_msg_id `{}`", rec.provenance.parent_msg_id))?;
    Ok((parent_node, parent_msg_id))
}

fn build_lineage_index(events: &[TraceEvent]) -> HashMap<LineageKey, LineageRecord> {
    let mut out = HashMap::new();
    for delivery in collect_deliveries_with_payload(events) {
        let payload: RuntimePayload = match serde_json::from_value(delivery.payload) {
            Ok(p) => p,
            Err(_) => continue,
        };
        let Some(provenance) = payload.provenance else {
            continue;
        };
        let Ok(from_node) = Uuid::parse_str(&payload.from_node) else {
            continue;
        };

        let key = (from_node, delivery.msg_id);
        out.insert(
            key,
            LineageRecord {
                key,
                seq: delivery.seq,
                local_node: delivery.node,
                to: delivery.to,
                from_service: payload.from_service,
                msg_type: payload.msg_type,
                provenance,
            },
        );
    }
    out
}

fn summarize_lineage(index: &HashMap<LineageKey, LineageRecord>) -> LineageSummary {
    let mut summary = LineageSummary {
        total: index.len(),
        ..Default::default()
    };

    for rec in index.values() {
        summary.max_hops = summary.max_hops.max(rec.provenance.hops);
        if rec.provenance.hops == 0 {
            summary.roots += 1;
            continue;
        }

        let parent = match lineage_parent_key(rec) {
            Ok(parent) => parent,
            Err(_) => {
                summary.invalid_parent_refs += 1;
                continue;
            }
        };

        if index.contains_key(&parent) {
            summary.resolved_parents += 1;
        } else if parent.0 == rec.local_node {
            summary.unresolved_internal_parents += 1;
        } else {
            summary.unresolved_external_parents += 1;
        }
    }

    summary
}

fn print_lineage_summary(path: &str, events: &[TraceEvent]) {
    let index = build_lineage_index(events);
    let summary = summarize_lineage(&index);

    println!("lineage: {path}");
    println!("indexed messages: {}", summary.total);
    println!("roots (hops=0): {}", summary.roots);
    println!("resolved parent refs: {}", summary.resolved_parents);
    println!(
        "unresolved internal parent refs: {}",
        summary.unresolved_internal_parents
    );
    println!(
        "unresolved external parent refs: {}",
        summary.unresolved_external_parents
    );
    println!("invalid parent refs: {}", summary.invalid_parent_refs);
    println!("max hops: {}", summary.max_hops);
}

fn print_lineage_path(
    path: &str,
    events: &[TraceEvent],
    node: runtime::event::NodeId,
    msg_id: MsgId,
) -> Result<()> {
    let index = build_lineage_index(events);
    let mut current = (node, msg_id);
    let mut visited: HashSet<LineageKey> = HashSet::new();

    println!("lineage-path: {path}");
    println!("start: {}/{}", node, msg_id);

    for depth in 0..256 {
        let Some(rec) = index.get(&current) else {
            if depth == 0 {
                bail!(
                    "lineage start message not found in trace: {}/{}",
                    node,
                    msg_id
                );
            }
            println!(
                "{depth:>3}: missing {}/{} (parent not present in this trace)",
                current.0, current.1
            );
            return Ok(());
        };

        println!(
            "{depth:>3}: key={}/{} type={} from_service={} hops={} deliver_seq={} deliver_node={} to={}",
            rec.key.0,
            rec.key.1,
            rec.msg_type,
            rec.from_service,
            rec.provenance.hops,
            rec.seq,
            rec.local_node,
            rec.to
        );

        if rec.provenance.hops == 0 {
            println!("      root reached");
            return Ok(());
        }

        let parent = match lineage_parent_key(rec) {
            Ok(p) => p,
            Err(err) => {
                println!("      invalid parent reference: {err}");
                return Ok(());
            }
        };

        if parent == current {
            println!("      parent points to self");
            return Ok(());
        }
        if !visited.insert(current) {
            println!("      cycle detected");
            return Ok(());
        }

        current = parent;
    }

    println!("      depth limit reached");
    Ok(())
}

fn verify_trace(events: &[TraceEvent]) -> VerifyReport {
    let mut problems = Vec::new();
    let mut seed: Option<u64> = None;
    let mut expected_seq: u64 = 0;

    let mut spawned: HashMap<ActorId, String> = HashMap::new();
    let mut produced: HashMap<(ActorId, MsgId), Vec<serde_json::Value>> = HashMap::new();
    let mut delivered_lineage: HashMap<LineageKey, DeliveredLineage> = HashMap::new();
    let mut dropped: HashSet<(runtime::event::NodeId, ActorId, MsgId)> = HashSet::new();
    let mut pending_timer_emit: Option<(u64, ActorId, runtime::event::NodeId)> = None;
    let mut pending_effect_observed: Option<(u64, runtime::event::NodeId, ActorId, MsgId)> = None;

    for ev in events {
        if ev.seq != expected_seq {
            problems.push(format!(
                "seq mismatch: expected {}, got {}",
                expected_seq, ev.seq
            ));
            expected_seq = ev.seq.saturating_add(1);
        } else {
            expected_seq = expected_seq.saturating_add(1);
        }

        match seed {
            None => seed = Some(ev.seed),
            Some(s) if s != ev.seed => problems.push(format!(
                "seed mismatch at seq {}: expected {}, got {}",
                ev.seq, s, ev.seed
            )),
            _ => {}
        }

        if let Some((deliver_seq, _, _, _)) = pending_effect_observed {
            if !matches!(ev.kind, EventKind::EffectObserved { .. }) {
                problems.push(format!(
                    "Deliver at seq {} not followed by EffectObserved; saw {:?} at seq {}",
                    deliver_seq, ev.kind, ev.seq
                ));
                pending_effect_observed = None;
            }
        }

        if let Some((timer_seq, timer_from, timer_id)) = pending_timer_emit {
            match &ev.kind {
                EventKind::Send { from, .. } | EventKind::NetSend { from, .. } => {
                    if *from != timer_from {
                        problems.push(format!(
                            "TimerFired at seq {} (timer_id={}) expected next send from actor {}, got actor {} at seq {}",
                            timer_seq, timer_id, timer_from, from, ev.seq
                        ));
                    }
                    pending_timer_emit = None;
                }
                _ => {
                    problems.push(format!(
                        "TimerFired at seq {} (timer_id={}) not followed by Send/NetSend; saw {:?} at seq {}",
                        timer_seq, timer_id, ev.kind, ev.seq
                    ));
                    pending_timer_emit = None;
                }
            }
        }

        match &ev.kind {
            EventKind::Spawn { actor, service, .. } => {
                match spawned.insert(*actor, service.clone()) {
                    None => {}
                    Some(prev) if prev == *service => {
                        problems.push(format!(
                            "duplicate Spawn at seq {} for actor {} and service `{}`",
                            ev.seq, actor, service
                        ));
                    }
                    Some(prev) => {
                        problems.push(format!(
                            "conflicting Spawn at seq {} for actor {}: `{}` vs `{}`",
                            ev.seq, actor, prev, service
                        ));
                    }
                }
            }
            EventKind::Send {
                from,
                to,
                msg_id,
                payload,
            } => {
                if !spawned.is_empty() {
                    if !spawned.contains_key(from) {
                        problems.push(format!(
                            "Send at seq {} from unknown actor {}",
                            ev.seq, from
                        ));
                    }
                    if !spawned.contains_key(to) {
                        problems.push(format!("Send at seq {} to unknown actor {}", ev.seq, to));
                    }
                }

                let key = (*to, *msg_id);
                produced.entry(key).or_default().push(payload.clone());
            }
            EventKind::NetRecv {
                from_node,
                to,
                msg_id,
                payload,
                ..
            } => {
                if !spawned.is_empty() && !spawned.contains_key(to) {
                    problems.push(format!("NetRecv at seq {} to unknown actor {}", ev.seq, to));
                }

                let key = (*to, *msg_id);
                if dropped.contains(&(*from_node, *to, *msg_id)) {
                    problems.push(format!(
                        "message dropped earlier but later NetRecv observed at seq {} for from_node={}, to={}, msg_id={}",
                        ev.seq, from_node, to, msg_id
                    ));
                }
                produced.entry(key).or_default().push(payload.clone());
            }
            EventKind::Deliver { node, to, msg_id } => {
                if !spawned.is_empty() && !spawned.contains_key(to) {
                    problems.push(format!("Deliver at seq {} to unknown actor {}", ev.seq, to));
                }

                let key = (*to, *msg_id);
                if let Some(queue) = produced.get_mut(&key) {
                    if queue.is_empty() {
                        problems.push(format!(
                            "Deliver at seq {} without prior Send/NetRecv for to={}, msg_id={}",
                            ev.seq, to, msg_id
                        ));
                    } else {
                        let payload = queue.remove(0);
                        verify_payload_lineage(
                            ev.seq,
                            *node,
                            *msg_id,
                            &payload,
                            &mut delivered_lineage,
                            &mut problems,
                        );
                    }
                    if queue.is_empty() {
                        produced.remove(&key);
                    }
                } else {
                    problems.push(format!(
                        "Deliver at seq {} without prior Send/NetRecv for to={}, msg_id={}",
                        ev.seq, to, msg_id
                    ));
                }

                pending_effect_observed = Some((ev.seq, *node, *to, *msg_id));
            }
            EventKind::NetSend { from, .. } => {
                if !spawned.is_empty() && !spawned.contains_key(from) {
                    problems.push(format!(
                        "NetSend at seq {} from unknown actor {}",
                        ev.seq, from
                    ));
                }
            }
            EventKind::Log { from, .. } => {
                if !spawned.is_empty() && !spawned.contains_key(from) {
                    problems.push(format!("Log at seq {} from unknown actor {}", ev.seq, from));
                }
            }
            EventKind::EffectObserved {
                node,
                actor,
                msg_id,
                declared,
                observed,
                ..
            } => {
                if !spawned.is_empty() && !spawned.contains_key(actor) {
                    problems.push(format!(
                        "EffectObserved at seq {} from unknown actor {}",
                        ev.seq, actor
                    ));
                }

                if let Some((deliver_seq, deliver_node, deliver_to, deliver_msg_id)) =
                    pending_effect_observed.take()
                {
                    if *node != deliver_node || *actor != deliver_to || *msg_id != deliver_msg_id {
                        problems.push(format!(
                            "EffectObserved at seq {} does not match preceding Deliver at seq {} (deliver node={}, to={}, msg_id={}; effect node={}, actor={}, msg_id={})",
                            ev.seq,
                            deliver_seq,
                            deliver_node,
                            deliver_to,
                            deliver_msg_id,
                            node,
                            actor,
                            msg_id
                        ));
                    }
                } else {
                    problems.push(format!(
                        "EffectObserved at seq {} without preceding Deliver",
                        ev.seq
                    ));
                }

                let declared_set: BTreeSet<EffectKind> = declared.iter().copied().collect();
                if declared_set.len() != declared.len() {
                    problems.push(format!(
                        "EffectObserved at seq {} has duplicate declared effects",
                        ev.seq
                    ));
                }
                let observed_set: BTreeSet<EffectKind> = observed.iter().copied().collect();
                if observed_set.len() != observed.len() {
                    problems.push(format!(
                        "EffectObserved at seq {} has duplicate observed effects",
                        ev.seq
                    ));
                }

                let unexpected: BTreeSet<EffectKind> =
                    observed_set.difference(&declared_set).copied().collect();
                if !unexpected.is_empty() {
                    problems.push(format!(
                        "EffectObserved at seq {} reports undeclared observed effects [{}] not in declared [{}]",
                        ev.seq,
                        format_effects(&unexpected),
                        format_effects(&declared_set)
                    ));
                }
            }
            EventKind::FaultInjected {
                from_node,
                to,
                msg_id,
                action,
                ..
            } => {
                if let FaultAction::Drop = action {
                    dropped.insert((*from_node, *to, *msg_id));
                }
            }
            EventKind::FaultPolicy { .. } => {}
            EventKind::TimerFired { from, timer_id, .. } => {
                pending_timer_emit = Some((ev.seq, *from, *timer_id));
            }
        }
    }

    if let Some((timer_seq, _, timer_id)) = pending_timer_emit {
        problems.push(format!(
            "TimerFired at seq {} (timer_id={}) reached end-of-trace without Send/NetSend",
            timer_seq, timer_id
        ));
    }
    if let Some((deliver_seq, _, _, _)) = pending_effect_observed {
        problems.push(format!(
            "Deliver at seq {} reached end-of-trace without EffectObserved",
            deliver_seq
        ));
    }

    VerifyReport {
        problems,
        pending_messages: produced.values().map(Vec::len).sum(),
    }
}

type ClusterKey = (runtime::event::NodeId, MsgId, runtime::event::NodeId);

#[derive(Debug, Clone)]
struct NetRecord {
    path: String,
    seq: u64,
    payload: serde_json::Value,
}

#[derive(Debug, Clone)]
struct DropRecord {
    path: String,
    seq: u64,
}

fn event_local_node(kind: &EventKind) -> Option<runtime::event::NodeId> {
    match kind {
        EventKind::Spawn { node, .. }
        | EventKind::Deliver { node, .. }
        | EventKind::TimerFired { node, .. }
        | EventKind::NetRecv { node, .. }
        | EventKind::NetSend { node, .. }
        | EventKind::Log { node, .. }
        | EventKind::EffectObserved { node, .. }
        | EventKind::FaultInjected { node, .. }
        | EventKind::FaultPolicy { node, .. } => Some(*node),
        EventKind::Send { .. } => None,
    }
}

fn verify_cluster(traces: &[ClusterTrace]) -> ClusterVerifyReport {
    let mut report = ClusterVerifyReport::default();
    let mut included_nodes = HashSet::<runtime::event::NodeId>::new();

    for trace in traces {
        let mut nodes = HashSet::new();
        for ev in &trace.events {
            if let Some(node) = event_local_node(&ev.kind) {
                nodes.insert(node);
            }
        }

        if nodes.is_empty() {
            report
                .problems
                .push(format!("trace `{}` has no node-scoped events", trace.path));
            continue;
        }
        if nodes.len() > 1 {
            report.problems.push(format!(
                "trace `{}` mixes multiple node ids: {:?}",
                trace.path, nodes
            ));
        }
        included_nodes.extend(nodes);
    }

    let mut sends: HashMap<ClusterKey, NetRecord> = HashMap::new();
    let mut recvs: HashMap<ClusterKey, NetRecord> = HashMap::new();
    let mut drops: HashMap<ClusterKey, DropRecord> = HashMap::new();

    for trace in traces {
        for ev in &trace.events {
            match &ev.kind {
                EventKind::NetSend {
                    node,
                    to_node,
                    msg_id,
                    payload,
                    ..
                } => {
                    let key = (*node, *msg_id, *to_node);
                    if let Some(prev) = sends.insert(
                        key,
                        NetRecord {
                            path: trace.path.clone(),
                            seq: ev.seq,
                            payload: payload.clone(),
                        },
                    ) {
                        report.problems.push(format!(
                            "duplicate NetSend key {}/{}/{} at {}:{} and {}:{}",
                            key.0, key.1, key.2, prev.path, prev.seq, trace.path, ev.seq
                        ));
                    }
                }
                EventKind::NetRecv {
                    node,
                    from_node,
                    msg_id,
                    payload,
                    ..
                } => {
                    let key = (*from_node, *msg_id, *node);
                    if let Some(prev) = recvs.insert(
                        key,
                        NetRecord {
                            path: trace.path.clone(),
                            seq: ev.seq,
                            payload: payload.clone(),
                        },
                    ) {
                        report.problems.push(format!(
                            "duplicate NetRecv key {}/{}/{} at {}:{} and {}:{}",
                            key.0, key.1, key.2, prev.path, prev.seq, trace.path, ev.seq
                        ));
                    }
                }
                EventKind::FaultInjected {
                    node,
                    from_node,
                    msg_id,
                    action,
                    ..
                } => {
                    if !matches!(action, FaultAction::Drop) {
                        continue;
                    }
                    let key = (*from_node, *msg_id, *node);
                    if let Some(prev) = drops.insert(
                        key,
                        DropRecord {
                            path: trace.path.clone(),
                            seq: ev.seq,
                        },
                    ) {
                        report.problems.push(format!(
                            "duplicate Drop fault key {}/{}/{} at {}:{} and {}:{}",
                            key.0, key.1, key.2, prev.path, prev.seq, trace.path, ev.seq
                        ));
                    }
                }
                _ => {}
            }
        }
    }

    for (key, recv) in &recvs {
        let from_included = included_nodes.contains(&key.0);
        if !from_included {
            report.external_inbound += 1;
            continue;
        }

        let Some(send) = sends.get(key) else {
            report.problems.push(format!(
                "NetRecv {}/{}/{} at {}:{} has no matching NetSend in provided traces",
                key.0, key.1, key.2, recv.path, recv.seq
            ));
            continue;
        };

        if send.payload != recv.payload {
            report.problems.push(format!(
                "payload mismatch for {}/{}/{}: NetSend at {}:{} differs from NetRecv at {}:{}",
                key.0, key.1, key.2, send.path, send.seq, recv.path, recv.seq
            ));
        } else {
            report.matched_recv += 1;
        }
    }

    for (key, drop) in &drops {
        let from_included = included_nodes.contains(&key.0);
        if !from_included {
            report.external_inbound += 1;
            continue;
        }

        if sends.contains_key(key) {
            report.matched_drop += 1;
        } else {
            report.problems.push(format!(
                "Drop fault {}/{}/{} at {}:{} has no matching NetSend in provided traces",
                key.0, key.1, key.2, drop.path, drop.seq
            ));
        }
    }

    for key in sends.keys() {
        let to_included = included_nodes.contains(&key.2);
        if !to_included {
            report.external_outbound += 1;
            continue;
        }

        let has_recv = recvs.contains_key(key);
        let has_drop = drops.contains_key(key);
        if has_recv && has_drop {
            report.problems.push(format!(
                "message {}/{}/{} has both NetRecv and Drop fault evidence",
                key.0, key.1, key.2
            ));
            continue;
        }
        if !has_recv && !has_drop {
            report.problems.push(format!(
                "NetSend {}/{}/{} has no matching NetRecv or Drop fault in provided traces",
                key.0, key.1, key.2
            ));
        }
    }

    let mut global_lineage: HashMap<LineageKey, (LineageRecord, String)> = HashMap::new();
    for trace in traces {
        let index = build_lineage_index(&trace.events);
        for (key, rec) in index {
            if let Some((prev, prev_path)) =
                global_lineage.insert(key, (rec.clone(), trace.path.clone()))
            {
                report.problems.push(format!(
                    "duplicate delivered lineage key {}/{} at {}:{} and {}:{}",
                    key.0, key.1, prev_path, prev.seq, trace.path, rec.seq
                ));
            }
        }
    }

    for (key, (rec, path)) in &global_lineage {
        if rec.provenance.hops == 0 {
            continue;
        }

        let parent = match lineage_parent_key(rec) {
            Ok(parent) => parent,
            Err(err) => {
                report.problems.push(format!(
                    "lineage record {}/{} at {}:{} has invalid parent reference: {}",
                    key.0, key.1, path, rec.seq, err
                ));
                continue;
            }
        };

        if let Some((parent_rec, parent_path)) = global_lineage.get(&parent) {
            report.resolved_lineage_parents += 1;
            let expected_hops = parent_rec.provenance.hops.saturating_add(1);
            if rec.provenance.hops != expected_hops {
                report.problems.push(format!(
                    "lineage record {}/{} at {}:{} has hops={} but parent {}/{} at {}:{} has hops={}",
                    key.0,
                    key.1,
                    path,
                    rec.seq,
                    rec.provenance.hops,
                    parent.0,
                    parent.1,
                    parent_path,
                    parent_rec.seq,
                    parent_rec.provenance.hops
                ));
            }
            if rec.provenance.origin_msg_id != parent_rec.provenance.origin_msg_id {
                report.problems.push(format!(
                    "lineage record {}/{} at {}:{} origin_msg_id={} does not match parent {}/{} origin_msg_id={}",
                    key.0,
                    key.1,
                    path,
                    rec.seq,
                    rec.provenance.origin_msg_id,
                    parent.0,
                    parent.1,
                    parent_rec.provenance.origin_msg_id
                ));
            }
            if rec.provenance.origin_node != parent_rec.provenance.origin_node {
                report.problems.push(format!(
                    "lineage record {}/{} at {}:{} origin_node={} does not match parent {}/{} origin_node={}",
                    key.0,
                    key.1,
                    path,
                    rec.seq,
                    rec.provenance.origin_node,
                    parent.0,
                    parent.1,
                    parent_rec.provenance.origin_node
                ));
            }
            if rec.provenance.origin_service != parent_rec.provenance.origin_service {
                report.problems.push(format!(
                    "lineage record {}/{} at {}:{} origin_service={} does not match parent {}/{} origin_service={}",
                    key.0,
                    key.1,
                    path,
                    rec.seq,
                    rec.provenance.origin_service,
                    parent.0,
                    parent.1,
                    parent_rec.provenance.origin_service
                ));
            }
        } else if included_nodes.contains(&parent.0) {
            report.problems.push(format!(
                "lineage record {}/{} at {}:{} references missing in-cluster parent {}/{}",
                key.0, key.1, path, rec.seq, parent.0, parent.1
            ));
        } else {
            report.external_lineage_parents += 1;
        }
    }

    report
}

fn main() -> Result<()> {
    match parse_command()? {
        Command::Summary { path } => {
            let events = read_events(&path)?;
            print_summary(&path, &events);
        }
        Command::Verify { path, report_json } => {
            let events = read_events(&path)?;
            print_summary(&path, &events);
            let report = verify_trace(&events);
            let diagnostics = build_verify_diagnostics(&path, &report);
            if let Some(report_path) = report_json.as_deref() {
                write_json_report(report_path, &diagnostics)?;
                println!("verify: report-json: {report_path}");
            }
            if report.problems.is_empty() {
                println!("verify: OK (pending_messages={})", report.pending_messages);
            } else {
                for p in &report.problems {
                    eprintln!("verify: ERROR: {p}");
                }
                bail!("verify failed: {} issue(s)", report.problems.len());
            }
        }
        Command::ClusterVerify { paths, report_json } => {
            let mut traces = Vec::new();
            let mut had_local_errors = false;
            let mut local_diagnostics = Vec::new();

            for path in &paths {
                let events = read_events(&path)?;
                print_summary(&path, &events);
                let report = verify_trace(&events);
                local_diagnostics.push(build_local_trace_diagnostics(path, &report));
                if report.problems.is_empty() {
                    println!(
                        "verify({path}): OK (pending_messages={})",
                        report.pending_messages
                    );
                } else {
                    had_local_errors = true;
                    for p in &report.problems {
                        eprintln!("verify({path}): ERROR: {p}");
                    }
                }
                traces.push(ClusterTrace {
                    path: path.clone(),
                    events,
                });
            }

            if had_local_errors {
                if let Some(report_path) = report_json.as_deref() {
                    let diagnostics = ClusterVerifyDiagnosticsReport {
                        mode: "cluster-verify",
                        ok: false,
                        traces: paths.clone(),
                        local: local_diagnostics,
                        cluster: None,
                    };
                    write_json_report(report_path, &diagnostics)?;
                    println!("cluster-verify: report-json: {report_path}");
                }
                bail!("cluster-verify aborted: one or more traces failed local verify");
            }

            let report = verify_cluster(&traces);
            let cluster_diagnostics = build_cluster_diagnostics(&report);
            if let Some(report_path) = report_json.as_deref() {
                let diagnostics = ClusterVerifyDiagnosticsReport {
                    mode: "cluster-verify",
                    ok: report.problems.is_empty(),
                    traces: paths.clone(),
                    local: local_diagnostics,
                    cluster: Some(cluster_diagnostics),
                };
                write_json_report(report_path, &diagnostics)?;
                println!("cluster-verify: report-json: {report_path}");
            }
            if report.problems.is_empty() {
                println!(
                    "cluster-verify: OK (matched_recv={} matched_drop={} resolved_lineage_parents={} external_lineage_parents={} external_inbound={} external_outbound={})",
                    report.matched_recv,
                    report.matched_drop,
                    report.resolved_lineage_parents,
                    report.external_lineage_parents,
                    report.external_inbound,
                    report.external_outbound
                );
            } else {
                for p in &report.problems {
                    eprintln!("cluster-verify: ERROR: {p}");
                }
                bail!("cluster-verify failed: {} issue(s)", report.problems.len());
            }
        }
        Command::LineageSummary { path } => {
            let events = read_events(&path)?;
            print_summary(&path, &events);
            print_lineage_summary(&path, &events);
        }
        Command::LineagePath { path, node, msg_id } => {
            let events = read_events(&path)?;
            print_lineage_path(&path, &events, node, msg_id)?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        build_lineage_index, build_problem_detail, build_verify_diagnostics, summarize_lineage,
        verify_cluster, verify_trace, ClusterTrace, VerifyReport,
    };
    use runtime::event::{EffectKind, EventKind, FaultAction, TraceEvent};
    use serde_json::json;

    fn parse_id(raw: &str) -> runtime::event::NodeId {
        raw.parse().expect("valid uuid")
    }

    fn event(seq: u64, kind: EventKind) -> TraceEvent {
        TraceEvent { seq, seed: 7, kind }
    }

    fn cluster_trace(path: &str, events: Vec<TraceEvent>) -> ClusterTrace {
        ClusterTrace {
            path: path.to_string(),
            events,
        }
    }

    fn net_send(
        seq: u64,
        node: runtime::event::NodeId,
        to_node: runtime::event::NodeId,
        from: runtime::event::ActorId,
        msg_id: runtime::event::MsgId,
        payload: serde_json::Value,
    ) -> TraceEvent {
        event(
            seq,
            EventKind::NetSend {
                node,
                to_node,
                from,
                msg_id,
                payload,
            },
        )
    }

    fn net_recv(
        seq: u64,
        node: runtime::event::NodeId,
        from_node: runtime::event::NodeId,
        to: runtime::event::ActorId,
        msg_id: runtime::event::MsgId,
        payload: serde_json::Value,
    ) -> TraceEvent {
        event(
            seq,
            EventKind::NetRecv {
                node,
                from_node,
                to,
                msg_id,
                payload,
            },
        )
    }

    fn drop_fault(
        seq: u64,
        node: runtime::event::NodeId,
        from_node: runtime::event::NodeId,
        to: runtime::event::ActorId,
        msg_id: runtime::event::MsgId,
    ) -> TraceEvent {
        event(
            seq,
            EventKind::FaultInjected {
                node,
                from_node,
                to,
                msg_id,
                action: FaultAction::Drop,
            },
        )
    }

    fn effect_observed(
        seq: u64,
        node: runtime::event::NodeId,
        actor: runtime::event::ActorId,
        msg_id: runtime::event::MsgId,
        declared: Vec<EffectKind>,
        observed: Vec<EffectKind>,
    ) -> TraceEvent {
        event(
            seq,
            EventKind::EffectObserved {
                node,
                actor,
                service: "svc".to_string(),
                msg_type: "x".to_string(),
                msg_id,
                declared,
                observed,
            },
        )
    }

    fn payload_with_provenance(
        from_node: runtime::event::NodeId,
        from_service: &str,
        origin_msg_id: runtime::event::MsgId,
        parent_node: runtime::event::NodeId,
        parent_msg_id: runtime::event::MsgId,
        hops: u64,
    ) -> serde_json::Value {
        json!({
            "type": "x",
            "from_node": from_node.to_string(),
            "from_service": from_service,
            "text": "payload",
            "provenance": {
                "origin_node": from_node.to_string(),
                "origin_service": from_service,
                "origin_msg_id": origin_msg_id.to_string(),
                "parent_node": parent_node.to_string(),
                "parent_msg_id": parent_msg_id.to_string(),
                "hops": hops
            }
        })
    }

    #[test]
    fn verify_accepts_well_formed_trace() {
        let node = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let a = parse_id("11111111-1111-1111-1111-111111111111");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let m = parse_id("00000000-0000-0000-0000-000000000001");

        let events = vec![
            event(
                0,
                EventKind::Spawn {
                    node,
                    actor: a,
                    service: "A".to_string(),
                },
            ),
            event(
                1,
                EventKind::Spawn {
                    node,
                    actor: b,
                    service: "B".to_string(),
                },
            ),
            event(
                2,
                EventKind::Send {
                    from: a,
                    to: b,
                    msg_id: m,
                    payload: payload_with_provenance(node, "A", m, node, m, 0),
                },
            ),
            event(
                3,
                EventKind::Deliver {
                    node,
                    to: b,
                    msg_id: m,
                },
            ),
            effect_observed(4, node, b, m, vec![], vec![]),
        ];

        let report = verify_trace(&events);
        assert!(report.problems.is_empty(), "{:?}", report.problems);
        assert_eq!(report.pending_messages, 0);
    }

    #[test]
    fn verify_rejects_orphan_deliver() {
        let node = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let m = parse_id("00000000-0000-0000-0000-000000000001");

        let events = vec![event(
            0,
            EventKind::Deliver {
                node,
                to: b,
                msg_id: m,
            },
        )];

        let report = verify_trace(&events);
        assert!(
            report
                .problems
                .iter()
                .any(|p| p.contains("without prior Send/NetRecv")),
            "{:?}",
            report.problems
        );
    }

    #[test]
    fn verify_rejects_drop_followed_by_netrecv() {
        let node = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let m = parse_id("00000000-0000-0000-0000-000000000001");

        let events = vec![
            event(
                0,
                EventKind::FaultInjected {
                    node,
                    from_node: node,
                    to: b,
                    msg_id: m,
                    action: FaultAction::Drop,
                },
            ),
            event(
                1,
                EventKind::NetRecv {
                    node,
                    from_node: node,
                    to: b,
                    msg_id: m,
                    payload: serde_json::json!({"type":"x"}),
                },
            ),
        ];

        let report = verify_trace(&events);
        assert!(
            report
                .problems
                .iter()
                .any(|p| p.contains("dropped earlier but later NetRecv observed")),
            "{:?}",
            report.problems
        );
    }

    #[test]
    fn verify_accepts_timer_followed_by_send() {
        let node = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let a = parse_id("11111111-1111-1111-1111-111111111111");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let t = parse_id("00000000-0000-0000-0000-000000000010");
        let m = parse_id("00000000-0000-0000-0000-000000000011");

        let events = vec![
            event(
                0,
                EventKind::TimerFired {
                    node,
                    from: a,
                    timer_id: t,
                },
            ),
            event(
                1,
                EventKind::Send {
                    from: a,
                    to: b,
                    msg_id: m,
                    payload: serde_json::json!({"type":"x"}),
                },
            ),
        ];

        let report = verify_trace(&events);
        assert!(report.problems.is_empty(), "{:?}", report.problems);
    }

    #[test]
    fn verify_rejects_timer_without_immediate_send() {
        let node = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let a = parse_id("11111111-1111-1111-1111-111111111111");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let t = parse_id("00000000-0000-0000-0000-000000000010");
        let m = parse_id("00000000-0000-0000-0000-000000000011");

        let events = vec![
            event(
                0,
                EventKind::TimerFired {
                    node,
                    from: a,
                    timer_id: t,
                },
            ),
            event(
                1,
                EventKind::Deliver {
                    node,
                    to: b,
                    msg_id: m,
                },
            ),
        ];

        let report = verify_trace(&events);
        assert!(
            report
                .problems
                .iter()
                .any(|p| p.contains("not followed by Send/NetSend")),
            "{:?}",
            report.problems
        );
    }

    #[test]
    fn verify_rejects_missing_provenance_on_deliver() {
        let node = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let a = parse_id("11111111-1111-1111-1111-111111111111");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let m = parse_id("00000000-0000-0000-0000-000000000001");

        let events = vec![
            event(
                0,
                EventKind::Spawn {
                    node,
                    actor: a,
                    service: "A".to_string(),
                },
            ),
            event(
                1,
                EventKind::Spawn {
                    node,
                    actor: b,
                    service: "B".to_string(),
                },
            ),
            event(
                2,
                EventKind::Send {
                    from: a,
                    to: b,
                    msg_id: m,
                    payload: json!({
                        "type": "x",
                        "from_node": node.to_string(),
                        "from_service": "A",
                        "text": "payload"
                    }),
                },
            ),
            event(
                3,
                EventKind::Deliver {
                    node,
                    to: b,
                    msg_id: m,
                },
            ),
        ];

        let report = verify_trace(&events);
        assert!(
            report
                .problems
                .iter()
                .any(|p| p.contains("payload missing provenance")),
            "{:?}",
            report.problems
        );
    }

    #[test]
    fn verify_rejects_invalid_provenance_hops() {
        let node = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let a = parse_id("11111111-1111-1111-1111-111111111111");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let m1 = parse_id("00000000-0000-0000-0000-000000000001");
        let m2 = parse_id("00000000-0000-0000-0000-000000000002");

        let events = vec![
            event(
                0,
                EventKind::Spawn {
                    node,
                    actor: a,
                    service: "A".to_string(),
                },
            ),
            event(
                1,
                EventKind::Spawn {
                    node,
                    actor: b,
                    service: "B".to_string(),
                },
            ),
            event(
                2,
                EventKind::Send {
                    from: a,
                    to: b,
                    msg_id: m1,
                    payload: payload_with_provenance(node, "A", m1, node, m1, 0),
                },
            ),
            event(
                3,
                EventKind::Deliver {
                    node,
                    to: b,
                    msg_id: m1,
                },
            ),
            event(
                4,
                EventKind::Send {
                    from: b,
                    to: a,
                    msg_id: m2,
                    payload: payload_with_provenance(node, "B", m1, node, m1, 3),
                },
            ),
            event(
                5,
                EventKind::Deliver {
                    node,
                    to: a,
                    msg_id: m2,
                },
            ),
        ];

        let report = verify_trace(&events);
        assert!(
            report
                .problems
                .iter()
                .any(|p| p.contains("has hops=3 but parent")),
            "{:?}",
            report.problems
        );
    }

    #[test]
    fn verify_rejects_missing_effect_observed_after_deliver() {
        let node = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let a = parse_id("11111111-1111-1111-1111-111111111111");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let m = parse_id("00000000-0000-0000-0000-000000000001");

        let events = vec![
            event(
                0,
                EventKind::Spawn {
                    node,
                    actor: a,
                    service: "A".to_string(),
                },
            ),
            event(
                1,
                EventKind::Spawn {
                    node,
                    actor: b,
                    service: "B".to_string(),
                },
            ),
            event(
                2,
                EventKind::Send {
                    from: a,
                    to: b,
                    msg_id: m,
                    payload: payload_with_provenance(node, "A", m, node, m, 0),
                },
            ),
            event(
                3,
                EventKind::Deliver {
                    node,
                    to: b,
                    msg_id: m,
                },
            ),
        ];

        let report = verify_trace(&events);
        assert!(
            report
                .problems
                .iter()
                .any(|p| p.contains("without EffectObserved")),
            "{:?}",
            report.problems
        );
    }

    #[test]
    fn verify_rejects_undeclared_observed_effects() {
        let node = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let a = parse_id("11111111-1111-1111-1111-111111111111");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let m = parse_id("00000000-0000-0000-0000-000000000001");

        let events = vec![
            event(
                0,
                EventKind::Spawn {
                    node,
                    actor: a,
                    service: "A".to_string(),
                },
            ),
            event(
                1,
                EventKind::Spawn {
                    node,
                    actor: b,
                    service: "B".to_string(),
                },
            ),
            event(
                2,
                EventKind::Send {
                    from: a,
                    to: b,
                    msg_id: m,
                    payload: payload_with_provenance(node, "A", m, node, m, 0),
                },
            ),
            event(
                3,
                EventKind::Deliver {
                    node,
                    to: b,
                    msg_id: m,
                },
            ),
            effect_observed(
                4,
                node,
                b,
                m,
                vec![EffectKind::Log],
                vec![EffectKind::SendRemote],
            ),
        ];

        let report = verify_trace(&events);
        assert!(
            report
                .problems
                .iter()
                .any(|p| p.contains("undeclared observed effects")),
            "{:?}",
            report.problems
        );
    }

    #[test]
    fn verify_accepts_cross_node_parent_reference_not_present_locally() {
        let node1 = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let node2 = parse_id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
        let actor = parse_id("22222222-2222-2222-2222-222222222222");
        let parent_msg = parse_id("00000000-0000-0000-0000-000000000001");
        let child_msg = parse_id("00000000-0000-0000-0000-000000000002");
        let origin_msg = parse_id("00000000-0000-0000-0000-000000000010");

        let inbound_payload = json!({
            "type": "x",
            "from_node": node2.to_string(),
            "from_service": "RemoteSvc",
            "text": "payload",
            "provenance": {
                "origin_node": node2.to_string(),
                "origin_service": "RemoteSvc",
                "origin_msg_id": origin_msg.to_string(),
                "parent_node": node1.to_string(),
                "parent_msg_id": parent_msg.to_string(),
                "hops": 2
            }
        });

        let events = vec![
            event(
                0,
                EventKind::Spawn {
                    node: node1,
                    actor,
                    service: "B".to_string(),
                },
            ),
            event(
                1,
                EventKind::NetSend {
                    node: node1,
                    to_node: node2,
                    from: actor,
                    msg_id: parent_msg,
                    payload: json!({"type":"x","text":"parent"}),
                },
            ),
            event(
                2,
                EventKind::NetRecv {
                    node: node1,
                    from_node: node2,
                    to: actor,
                    msg_id: child_msg,
                    payload: inbound_payload,
                },
            ),
            event(
                3,
                EventKind::Deliver {
                    node: node1,
                    to: actor,
                    msg_id: child_msg,
                },
            ),
            effect_observed(4, node1, actor, child_msg, vec![], vec![]),
        ];

        let report = verify_trace(&events);
        assert!(report.problems.is_empty(), "{:?}", report.problems);
    }

    #[test]
    fn verify_allows_same_parent_msg_id_when_parent_node_differs() {
        let node1 = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let node2 = parse_id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
        let actor = parse_id("22222222-2222-2222-2222-222222222222");
        let msg = parse_id("00000000-0000-0000-0000-000000000010");

        let inbound_payload = json!({
            "type": "x",
            "from_node": node2.to_string(),
            "from_service": "RemoteSvc",
            "text": "payload",
            "provenance": {
                "origin_node": node2.to_string(),
                "origin_service": "RemoteSvc",
                "origin_msg_id": msg.to_string(),
                "parent_node": node1.to_string(),
                "parent_msg_id": msg.to_string(),
                "hops": 2
            }
        });

        let events = vec![
            event(
                0,
                EventKind::Spawn {
                    node: node1,
                    actor,
                    service: "B".to_string(),
                },
            ),
            event(
                1,
                EventKind::NetRecv {
                    node: node1,
                    from_node: node2,
                    to: actor,
                    msg_id: msg,
                    payload: inbound_payload,
                },
            ),
            event(
                2,
                EventKind::Deliver {
                    node: node1,
                    to: actor,
                    msg_id: msg,
                },
            ),
            effect_observed(3, node1, actor, msg, vec![], vec![]),
        ];

        let report = verify_trace(&events);
        assert!(report.problems.is_empty(), "{:?}", report.problems);
    }

    #[test]
    fn lineage_summary_counts_resolved_parent_chain() {
        let node = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let a = parse_id("11111111-1111-1111-1111-111111111111");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let m1 = parse_id("00000000-0000-0000-0000-000000000001");
        let m2 = parse_id("00000000-0000-0000-0000-000000000002");

        let events = vec![
            event(
                0,
                EventKind::Spawn {
                    node,
                    actor: a,
                    service: "A".to_string(),
                },
            ),
            event(
                1,
                EventKind::Spawn {
                    node,
                    actor: b,
                    service: "B".to_string(),
                },
            ),
            event(
                2,
                EventKind::Send {
                    from: a,
                    to: b,
                    msg_id: m1,
                    payload: payload_with_provenance(node, "A", m1, node, m1, 0),
                },
            ),
            event(
                3,
                EventKind::Deliver {
                    node,
                    to: b,
                    msg_id: m1,
                },
            ),
            event(
                4,
                EventKind::Send {
                    from: b,
                    to: a,
                    msg_id: m2,
                    payload: payload_with_provenance(node, "B", m1, node, m1, 1),
                },
            ),
            event(
                5,
                EventKind::Deliver {
                    node,
                    to: a,
                    msg_id: m2,
                },
            ),
        ];

        let index = build_lineage_index(&events);
        let summary = summarize_lineage(&index);
        assert_eq!(summary.total, 2);
        assert_eq!(summary.roots, 1);
        assert_eq!(summary.resolved_parents, 1);
        assert_eq!(summary.unresolved_internal_parents, 0);
        assert_eq!(summary.unresolved_external_parents, 0);
    }

    #[test]
    fn lineage_summary_counts_external_parent_refs() {
        let node = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let remote = parse_id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let m = parse_id("00000000-0000-0000-0000-000000000010");
        let parent = parse_id("00000000-0000-0000-0000-000000000011");

        let events = vec![
            event(
                0,
                EventKind::Spawn {
                    node,
                    actor: b,
                    service: "B".to_string(),
                },
            ),
            event(
                1,
                EventKind::NetRecv {
                    node,
                    from_node: remote,
                    to: b,
                    msg_id: m,
                    payload: payload_with_provenance(
                        remote,
                        "RemoteSvc",
                        parent,
                        remote,
                        parent,
                        2,
                    ),
                },
            ),
            event(
                2,
                EventKind::Deliver {
                    node,
                    to: b,
                    msg_id: m,
                },
            ),
        ];

        let index = build_lineage_index(&events);
        let summary = summarize_lineage(&index);
        assert_eq!(summary.total, 1);
        assert_eq!(summary.unresolved_external_parents, 1);
    }

    #[test]
    fn cluster_verify_accepts_matching_send_and_recv() {
        let n1 = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let n2 = parse_id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
        let from = parse_id("11111111-1111-1111-1111-111111111111");
        let to = parse_id("22222222-2222-2222-2222-222222222222");
        let msg = parse_id("00000000-0000-0000-0000-000000000001");
        let payload = json!({"type":"x","from_node":n1.to_string(),"from_service":"A","text":"hello","provenance":{"origin_node":n1.to_string(),"origin_service":"A","origin_msg_id":msg.to_string(),"parent_node":n1.to_string(),"parent_msg_id":msg.to_string(),"hops":0}});

        let traces = vec![
            cluster_trace(
                "n1.trace",
                vec![net_send(0, n1, n2, from, msg, payload.clone())],
            ),
            cluster_trace(
                "n2.trace",
                vec![net_recv(0, n2, n1, to, msg, payload.clone())],
            ),
        ];

        let report = verify_cluster(&traces);
        assert!(report.problems.is_empty(), "{:?}", report.problems);
        assert_eq!(report.matched_recv, 1);
        assert_eq!(report.matched_drop, 0);
    }

    #[test]
    fn cluster_verify_accepts_drop_evidence() {
        let n1 = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let n2 = parse_id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
        let from = parse_id("11111111-1111-1111-1111-111111111111");
        let to = parse_id("22222222-2222-2222-2222-222222222222");
        let msg = parse_id("00000000-0000-0000-0000-000000000001");
        let payload = json!({"type":"x","from_node":n1.to_string(),"from_service":"A","text":"hello","provenance":{"origin_node":n1.to_string(),"origin_service":"A","origin_msg_id":msg.to_string(),"parent_node":n1.to_string(),"parent_msg_id":msg.to_string(),"hops":0}});

        let traces = vec![
            cluster_trace("n1.trace", vec![net_send(0, n1, n2, from, msg, payload)]),
            cluster_trace("n2.trace", vec![drop_fault(0, n2, n1, to, msg)]),
        ];

        let report = verify_cluster(&traces);
        assert!(report.problems.is_empty(), "{:?}", report.problems);
        assert_eq!(report.matched_recv, 0);
        assert_eq!(report.matched_drop, 1);
    }

    #[test]
    fn cluster_verify_rejects_missing_inbound_evidence() {
        let n1 = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let n2 = parse_id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
        let from = parse_id("11111111-1111-1111-1111-111111111111");
        let msg = parse_id("00000000-0000-0000-0000-000000000001");
        let payload = json!({"type":"x","from_node":n1.to_string(),"from_service":"A","text":"hello","provenance":{"origin_node":n1.to_string(),"origin_service":"A","origin_msg_id":msg.to_string(),"parent_node":n1.to_string(),"parent_msg_id":msg.to_string(),"hops":0}});

        let traces = vec![
            cluster_trace("n1.trace", vec![net_send(0, n1, n2, from, msg, payload)]),
            cluster_trace(
                "n2.trace",
                vec![event(
                    0,
                    EventKind::Spawn {
                        node: n2,
                        actor: parse_id("33333333-3333-3333-3333-333333333333"),
                        service: "B".to_string(),
                    },
                )],
            ),
        ];

        let report = verify_cluster(&traces);
        assert!(
            report
                .problems
                .iter()
                .any(|p| p.contains("no matching NetRecv or Drop fault")),
            "{:?}",
            report.problems
        );
    }

    #[test]
    fn cluster_verify_rejects_payload_mismatch() {
        let n1 = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let n2 = parse_id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
        let from = parse_id("11111111-1111-1111-1111-111111111111");
        let to = parse_id("22222222-2222-2222-2222-222222222222");
        let msg = parse_id("00000000-0000-0000-0000-000000000001");

        let traces = vec![
            cluster_trace(
                "n1.trace",
                vec![net_send(
                    0,
                    n1,
                    n2,
                    from,
                    msg,
                    json!({"type":"x","text":"hello"}),
                )],
            ),
            cluster_trace(
                "n2.trace",
                vec![net_recv(
                    0,
                    n2,
                    n1,
                    to,
                    msg,
                    json!({"type":"x","text":"tampered"}),
                )],
            ),
        ];

        let report = verify_cluster(&traces);
        assert!(
            report
                .problems
                .iter()
                .any(|p| p.contains("payload mismatch")),
            "{:?}",
            report.problems
        );
    }

    #[test]
    fn cluster_verify_accepts_cross_node_lineage_parent_resolution() {
        let n1 = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let n2 = parse_id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
        let a = parse_id("11111111-1111-1111-1111-111111111111");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let parent_msg = parse_id("00000000-0000-0000-0000-000000000001");
        let child_msg = parse_id("00000000-0000-0000-0000-000000000002");

        let parent_payload = payload_with_provenance(n1, "Gateway", parent_msg, n1, parent_msg, 0);
        let child_payload = json!({
            "type": "x",
            "from_node": n2.to_string(),
            "from_service": "Echo",
            "text": "payload",
            "provenance": {
                "origin_node": n1.to_string(),
                "origin_service": "Gateway",
                "origin_msg_id": parent_msg.to_string(),
                "parent_node": n1.to_string(),
                "parent_msg_id": parent_msg.to_string(),
                "hops": 1
            }
        });

        let traces = vec![
            cluster_trace(
                "n1.trace",
                vec![
                    event(
                        0,
                        EventKind::Spawn {
                            node: n1,
                            actor: a,
                            service: "Gateway".to_string(),
                        },
                    ),
                    event(
                        1,
                        EventKind::Send {
                            from: a,
                            to: a,
                            msg_id: parent_msg,
                            payload: parent_payload,
                        },
                    ),
                    event(
                        2,
                        EventKind::Deliver {
                            node: n1,
                            to: a,
                            msg_id: parent_msg,
                        },
                    ),
                    net_recv(3, n1, n2, a, child_msg, child_payload.clone()),
                    event(
                        4,
                        EventKind::Deliver {
                            node: n1,
                            to: a,
                            msg_id: child_msg,
                        },
                    ),
                ],
            ),
            cluster_trace(
                "n2.trace",
                vec![
                    event(
                        0,
                        EventKind::Spawn {
                            node: n2,
                            actor: b,
                            service: "Echo".to_string(),
                        },
                    ),
                    net_send(1, n2, n1, b, child_msg, child_payload),
                ],
            ),
        ];

        let report = verify_cluster(&traces);
        assert!(report.problems.is_empty(), "{:?}", report.problems);
        assert_eq!(report.matched_recv, 1);
        assert_eq!(report.resolved_lineage_parents, 1);
    }

    #[test]
    fn cluster_verify_rejects_missing_in_cluster_lineage_parent() {
        let n1 = parse_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        let n2 = parse_id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
        let a = parse_id("11111111-1111-1111-1111-111111111111");
        let b = parse_id("22222222-2222-2222-2222-222222222222");
        let missing_parent_msg = parse_id("00000000-0000-0000-0000-000000000001");
        let child_msg = parse_id("00000000-0000-0000-0000-000000000002");

        let child_payload = json!({
            "type": "x",
            "from_node": n2.to_string(),
            "from_service": "Echo",
            "text": "payload",
            "provenance": {
                "origin_node": n1.to_string(),
                "origin_service": "Gateway",
                "origin_msg_id": missing_parent_msg.to_string(),
                "parent_node": n1.to_string(),
                "parent_msg_id": missing_parent_msg.to_string(),
                "hops": 1
            }
        });

        let traces = vec![
            cluster_trace(
                "n1.trace",
                vec![
                    event(
                        0,
                        EventKind::Spawn {
                            node: n1,
                            actor: a,
                            service: "Gateway".to_string(),
                        },
                    ),
                    net_recv(1, n1, n2, a, child_msg, child_payload.clone()),
                    event(
                        2,
                        EventKind::Deliver {
                            node: n1,
                            to: a,
                            msg_id: child_msg,
                        },
                    ),
                ],
            ),
            cluster_trace(
                "n2.trace",
                vec![
                    event(
                        0,
                        EventKind::Spawn {
                            node: n2,
                            actor: b,
                            service: "Echo".to_string(),
                        },
                    ),
                    net_send(1, n2, n1, b, child_msg, child_payload),
                ],
            ),
        ];

        let report = verify_cluster(&traces);
        assert!(
            report
                .problems
                .iter()
                .any(|p| p.contains("missing in-cluster parent")),
            "{:?}",
            report.problems
        );
    }

    #[test]
    fn problem_detail_extracts_invariant_context() {
        let msg = "Deliver at seq 42 without prior Send/NetRecv for to=22222222-2222-2222-2222-222222222222, msg_id=00000000-0000-0000-0000-000000000010";
        let detail = build_problem_detail(msg);
        assert_eq!(detail.code, "deliver_without_source");
        assert_eq!(detail.seq, Some(42));
        assert_eq!(
            detail.msg_id.as_deref(),
            Some("00000000-0000-0000-0000-000000000010")
        );
        assert_eq!(
            detail.actor.as_deref(),
            Some("22222222-2222-2222-2222-222222222222")
        );
    }

    #[test]
    fn verify_diagnostics_includes_first_issue() {
        let report = VerifyReport {
            problems: vec![
                "seq mismatch: expected 1, got 2".to_string(),
                "seed mismatch at seq 3: expected 7, got 8".to_string(),
            ],
            pending_messages: 5,
        };

        let diagnostics = build_verify_diagnostics("trace.jsonl", &report);
        assert!(!diagnostics.ok);
        assert_eq!(diagnostics.issue_count, 2);
        assert_eq!(diagnostics.pending_messages, 5);
        assert_eq!(
            diagnostics.first_issue.as_ref().map(|p| p.code),
            Some("trace_seq_mismatch")
        );
    }
}
