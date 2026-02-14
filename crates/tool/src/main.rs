use anyhow::{bail, Result};
use runtime::event::{ActorId, EventKind, FaultAction, MsgId, TraceEvent};
use runtime::trace::TraceReader;
use std::collections::{BTreeMap, HashMap, HashSet};

enum Command {
    Summary { path: String },
    Verify { path: String },
}

fn parse_command() -> Result<Command> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [path] => Ok(Command::Summary { path: path.clone() }),
        [cmd, path] if cmd == "summary" => Ok(Command::Summary { path: path.clone() }),
        [cmd, path] if cmd == "verify" => Ok(Command::Verify { path: path.clone() }),
        _ => bail!(
            "usage:\n  cargo run -p tool -- <trace.jsonl>\n  cargo run -p tool -- summary <trace.jsonl>\n  cargo run -p tool -- verify <trace.jsonl>"
        ),
    }
}

fn event_kind_name(kind: &EventKind) -> &'static str {
    match kind {
        EventKind::Spawn { .. } => "Spawn",
        EventKind::Send { .. } => "Send",
        EventKind::Deliver { .. } => "Deliver",
        EventKind::TimerFired { .. } => "TimerFired",
        EventKind::NetRecv { .. } => "NetRecv",
        EventKind::NetSend { .. } => "NetSend",
        EventKind::FaultInjected { .. } => "FaultInjected",
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

fn verify_trace(events: &[TraceEvent]) -> VerifyReport {
    let mut problems = Vec::new();
    let mut seed: Option<u64> = None;
    let mut expected_seq: u64 = 0;

    let mut spawned: HashMap<ActorId, String> = HashMap::new();
    let mut produced: HashMap<(ActorId, MsgId), u64> = HashMap::new();
    let mut dropped: HashSet<(runtime::event::NodeId, ActorId, MsgId)> = HashSet::new();

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
                from, to, msg_id, ..
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
                *produced.entry(key).or_insert(0) += 1;
            }
            EventKind::NetRecv {
                from_node,
                to,
                msg_id,
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
                *produced.entry(key).or_insert(0) += 1;
            }
            EventKind::Deliver { to, msg_id, .. } => {
                if !spawned.is_empty() && !spawned.contains_key(to) {
                    problems.push(format!("Deliver at seq {} to unknown actor {}", ev.seq, to));
                }

                let key = (*to, *msg_id);
                if let Some(count) = produced.get_mut(&key) {
                    *count = count.saturating_sub(1);
                    if *count == 0 {
                        produced.remove(&key);
                    }
                } else {
                    problems.push(format!(
                        "Deliver at seq {} without prior Send/NetRecv for to={}, msg_id={}",
                        ev.seq, to, msg_id
                    ));
                }
            }
            EventKind::NetSend { from, .. } => {
                if !spawned.is_empty() && !spawned.contains_key(from) {
                    problems.push(format!(
                        "NetSend at seq {} from unknown actor {}",
                        ev.seq, from
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
            EventKind::TimerFired { .. } => {}
        }
    }

    VerifyReport {
        problems,
        pending_messages: produced.values().sum::<u64>() as usize,
    }
}

fn main() -> Result<()> {
    match parse_command()? {
        Command::Summary { path } => {
            let events = read_events(&path)?;
            print_summary(&path, &events);
        }
        Command::Verify { path } => {
            let events = read_events(&path)?;
            print_summary(&path, &events);
            let report = verify_trace(&events);
            if report.problems.is_empty() {
                println!("verify: OK (pending_messages={})", report.pending_messages);
            } else {
                for p in &report.problems {
                    eprintln!("verify: ERROR: {p}");
                }
                bail!("verify failed: {} issue(s)", report.problems.len());
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::verify_trace;
    use runtime::event::{EventKind, FaultAction, TraceEvent};

    fn parse_id(raw: &str) -> runtime::event::NodeId {
        raw.parse().expect("valid uuid")
    }

    fn event(seq: u64, kind: EventKind) -> TraceEvent {
        TraceEvent { seq, seed: 7, kind }
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
                    payload: serde_json::json!({"type":"x"}),
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
}
