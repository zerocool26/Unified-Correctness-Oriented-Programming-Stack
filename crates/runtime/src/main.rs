mod actor;
mod event;
mod net;
mod scheduler;
mod trace;

use actor::{Actor, ActorContext, ActorSystem, Target};
use anyhow::{Context, Result};
use event::{EventKind, FaultAction, TraceEvent};
use lang::{parse_module, ActionDecl, RemoteTarget};
use net::WireEnvelope;
use scheduler::{choose_next_deterministic, PendingDelivery};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::time::Duration;
use trace::{TraceReader, TraceWriter};
use uuid::Uuid;

#[derive(Clone, Copy)]
enum Mode {
    Record,
    Replay,
}

#[derive(Clone, Copy, Debug)]
struct FaultConfig {
    drop_every: Option<u64>,
    delay_steps: u64,
    reorder_window: usize,
}

impl Default for FaultConfig {
    fn default() -> Self {
        Self {
            drop_every: None,
            delay_steps: 0,
            reorder_window: 1,
        }
    }
}

struct Config {
    mode: Mode,
    trace_path: String,
    program_path: String,
    node_id: Uuid,
    listen: Option<String>,
    peers: HashMap<Uuid, String>,
    bootstrap_hello: bool,
    bootstrap_burst: u64,
    steps: u64,
    idle_sleep_ms: u64,
    fault: FaultConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RuntimeMessage {
    #[serde(rename = "type")]
    msg_type: String,
    from_node: String,
    from_service: String,
    text: String,
}

#[derive(Debug, Clone)]
struct Program {
    services: Vec<String>,
    service_initial_state: HashMap<String, HashMap<String, i64>>,
    handlers: HashMap<(String, String), Vec<ActionDecl>>,
}

fn next_deterministic_msg_id(node_id: Uuid, counter: &mut u64) -> Uuid {
    let id = Uuid::from_u128(node_id.as_u128().wrapping_add(*counter as u128));
    *counter = counter.saturating_add(1);
    id
}

fn print_usage() {
    eprintln!("usage: runtime [options]");
    eprintln!("  --program <path>            Service language program path");
    eprintln!("  --trace <path>              Trace file path (default: trace.jsonl)");
    eprintln!("  --replay                    Replay from trace instead of recording");
    eprintln!("  --node-id <uuid>            Fixed node id for distributed runs");
    eprintln!("  --listen <host:port>        Listen for wire messages");
    eprintln!("  --peer <uuid=host:port>     Peer mapping (repeatable)");
    eprintln!("  --bootstrap-hello           Emit start messages for hello flow");
    eprintln!("  --bootstrap-burst <n>       Number of start messages (default: 1)");
    eprintln!("  --steps <n>                 Max runtime scheduling steps (default: 40)");
    eprintln!("  --idle-sleep-ms <n>         Sleep n ms on idle steps (record mode only)");
    eprintln!("  --fault-drop-every <n>      Drop every n-th inbound wire message");
    eprintln!("  --fault-delay-steps <n>     Delay inbound wire messages by n runtime steps");
    eprintln!("  --fault-reorder-window <n>  Reverse inbound arrivals in chunks of n");
}

fn parse_peer_spec(spec: &str) -> Result<(Uuid, String)> {
    let (node, addr) = spec
        .split_once('=')
        .with_context(|| format!("invalid peer format `{spec}`, expected <uuid=host:port>"))?;
    let node = Uuid::parse_str(node).with_context(|| format!("invalid peer node id `{node}`"))?;
    Ok((node, addr.to_string()))
}

fn parse_config(args: &[String]) -> Result<Config> {
    let mut mode = Mode::Record;
    let mut trace_path = "trace.jsonl".to_string();
    let mut program_path = "programs/distributed_services.uco".to_string();
    let mut node_id = Uuid::new_v4();
    let mut listen = None;
    let mut peers = HashMap::new();
    let mut bootstrap_hello = false;
    let mut bootstrap_burst: u64 = 1;
    let mut steps: u64 = 40;
    let mut idle_sleep_ms: u64 = 0;
    let mut fault = FaultConfig::default();

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--help" | "-h" => {
                print_usage();
                std::process::exit(0);
            }
            "--replay" => mode = Mode::Replay,
            "--program" => {
                i += 1;
                let value = args
                    .get(i)
                    .context("missing value for --program")?
                    .to_string();
                program_path = value;
            }
            "--trace" => {
                i += 1;
                let value = args
                    .get(i)
                    .context("missing value for --trace")?
                    .to_string();
                trace_path = value;
            }
            "--node-id" => {
                i += 1;
                let value = args.get(i).context("missing value for --node-id")?;
                node_id = Uuid::parse_str(value)
                    .with_context(|| format!("invalid --node-id value `{value}`"))?;
            }
            "--listen" => {
                i += 1;
                let value = args
                    .get(i)
                    .context("missing value for --listen")?
                    .to_string();
                listen = Some(value);
            }
            "--peer" => {
                i += 1;
                let value = args.get(i).context("missing value for --peer")?;
                let (peer_id, addr) = parse_peer_spec(value)?;
                peers.insert(peer_id, addr);
            }
            "--bootstrap-hello" => bootstrap_hello = true,
            "--bootstrap-burst" => {
                i += 1;
                let value = args.get(i).context("missing value for --bootstrap-burst")?;
                bootstrap_burst = value
                    .parse::<u64>()
                    .with_context(|| format!("invalid --bootstrap-burst value `{value}`"))?;
                if bootstrap_burst == 0 {
                    anyhow::bail!("--bootstrap-burst must be >= 1");
                }
            }
            "--steps" => {
                i += 1;
                let value = args.get(i).context("missing value for --steps")?;
                steps = value
                    .parse::<u64>()
                    .with_context(|| format!("invalid --steps value `{value}`"))?;
            }
            "--idle-sleep-ms" => {
                i += 1;
                let value = args.get(i).context("missing value for --idle-sleep-ms")?;
                idle_sleep_ms = value
                    .parse::<u64>()
                    .with_context(|| format!("invalid --idle-sleep-ms value `{value}`"))?;
            }
            "--fault-drop-every" => {
                i += 1;
                let value = args
                    .get(i)
                    .context("missing value for --fault-drop-every")?;
                let parsed = value
                    .parse::<u64>()
                    .with_context(|| format!("invalid --fault-drop-every value `{value}`"))?;
                fault.drop_every = if parsed == 0 { None } else { Some(parsed) };
            }
            "--fault-delay-steps" => {
                i += 1;
                let value = args
                    .get(i)
                    .context("missing value for --fault-delay-steps")?;
                fault.delay_steps = value
                    .parse::<u64>()
                    .with_context(|| format!("invalid --fault-delay-steps value `{value}`"))?;
            }
            "--fault-reorder-window" => {
                i += 1;
                let value = args
                    .get(i)
                    .context("missing value for --fault-reorder-window")?;
                let parsed = value
                    .parse::<usize>()
                    .with_context(|| format!("invalid --fault-reorder-window value `{value}`"))?;
                if parsed == 0 {
                    anyhow::bail!("--fault-reorder-window must be >= 1");
                }
                fault.reorder_window = parsed;
            }
            other => anyhow::bail!("unknown argument: {other}"),
        }
        i += 1;
    }

    Ok(Config {
        mode,
        trace_path,
        program_path,
        node_id,
        listen,
        peers,
        bootstrap_hello,
        bootstrap_burst,
        steps,
        idle_sleep_ms,
        fault,
    })
}

fn load_program(path: &str) -> Result<Program> {
    let src = fs::read_to_string(path).with_context(|| format!("read program file `{path}`"))?;
    let module = parse_module(&src).with_context(|| format!("parse program file `{path}`"))?;

    let mut services = Vec::new();
    let mut seen = HashSet::<String>::new();
    let mut service_initial_state = HashMap::<String, HashMap<String, i64>>::new();
    let mut handlers = HashMap::<(String, String), Vec<ActionDecl>>::new();

    for service in module.services {
        if seen.contains(&service.name) {
            anyhow::bail!("duplicate service `{}` in program", service.name);
        }
        seen.insert(service.name.clone());
        services.push(service.name.clone());

        let mut state = HashMap::new();
        for decl in service.states {
            if state.insert(decl.name.clone(), decl.initial).is_some() {
                anyhow::bail!(
                    "duplicate state `{}` in service `{}`",
                    decl.name,
                    service.name
                );
            }
        }
        service_initial_state.insert(service.name.clone(), state);

        for handler in service.handlers {
            let key = (service.name.clone(), handler.on.clone());
            handlers.entry(key).or_default().extend(handler.actions);
        }
    }

    let service_names: HashSet<String> = services.iter().cloned().collect();
    for ((service_name, msg_type), actions) in &handlers {
        let state = service_initial_state
            .get(service_name)
            .with_context(|| format!("internal error: missing state for `{service_name}`"))?;
        for action in actions {
            validate_action(action, service_name, msg_type, state, &service_names)?;
        }
    }

    Ok(Program {
        services,
        service_initial_state,
        handlers,
    })
}

fn validate_action(
    action: &ActionDecl,
    service_name: &str,
    msg_type: &str,
    state: &HashMap<String, i64>,
    service_names: &HashSet<String>,
) -> Result<()> {
    match action {
        ActionDecl::Log { .. } => {}
        ActionDecl::SetState { key, .. }
        | ActionDecl::IncState { key, .. }
        | ActionDecl::IfStateEq { key, .. } => {
            if !state.contains_key(key) {
                anyhow::bail!(
                    "service `{service_name}` handler `on {msg_type}` references undeclared state `{key}`"
                );
            }
        }
        ActionDecl::SendLocal {
            service: target_service,
            ..
        }
        | ActionDecl::SendRemote {
            service: target_service,
            ..
        } => {
            if !service_names.contains(target_service) {
                anyhow::bail!(
                    "service `{service_name}` handler `on {msg_type}` sends to unknown service `{target_service}`"
                );
            }
        }
    }

    if let ActionDecl::IfStateEq { then_action, .. } = action {
        validate_action(then_action, service_name, msg_type, state, service_names)?;
    }

    if let ActionDecl::SendRemote {
        target: RemoteTarget::Node(raw),
        ..
    } = action
    {
        Uuid::parse_str(raw).with_context(|| {
            format!(
                "service `{service_name}` handler `on {msg_type}` has invalid node target `{raw}`"
            )
        })?;
    }

    Ok(())
}

fn actor_id_for_service(service: &str) -> Uuid {
    Uuid::new_v5(&Uuid::NAMESPACE_OID, service.as_bytes())
}

fn system_actor_id() -> Uuid {
    actor_id_for_service("System")
}

fn build_actor_system(program: &Program) -> (ActorSystem, HashMap<String, Uuid>) {
    let mut sys = ActorSystem::new();
    let mut service_to_actor = HashMap::new();

    for service in &program.services {
        let actor_id = actor_id_for_service(service);
        service_to_actor.insert(service.clone(), actor_id);
        let initial_state = program
            .service_initial_state
            .get(service)
            .cloned()
            .expect("validated program should include state map for every service");
        sys.actors.insert(
            actor_id,
            Actor {
                id: actor_id,
                service: service.clone(),
                state: initial_state,
                inbox: Default::default(),
            },
        );
    }

    (sys, service_to_actor)
}

fn encode_msg(msg: &RuntimeMessage) -> Value {
    serde_json::to_value(msg).expect("runtime message should always serialize")
}

fn decode_msg(value: Value) -> Result<RuntimeMessage> {
    serde_json::from_value(value).context("decode runtime message payload")
}

fn render_template(
    template: &str,
    self_node: Uuid,
    self_service: &str,
    incoming: &RuntimeMessage,
    state: &HashMap<String, i64>,
) -> String {
    let mut out = template.to_string();
    out = out.replace("$self_node", &self_node.to_string());
    out = out.replace("$self_service", self_service);
    out = out.replace("$from_node", &incoming.from_node);
    out = out.replace("$from_service", &incoming.from_service);
    out = out.replace("$text", &incoming.text);
    out = out.replace("$type", &incoming.msg_type);

    let mut keys: Vec<&String> = state.keys().collect();
    keys.sort_unstable();
    for key in keys {
        let token = format!("$state.{key}");
        if let Some(value) = state.get(key) {
            out = out.replace(&token, &value.to_string());
        }
    }

    out
}

fn sorted_peer_ids(peers: &HashMap<Uuid, String>) -> Vec<Uuid> {
    let mut ids: Vec<Uuid> = peers.keys().copied().collect();
    ids.sort_unstable();
    ids
}

fn execute_actions(
    program: &Program,
    service: &str,
    incoming: &RuntimeMessage,
    peers: &HashMap<Uuid, String>,
    state: &mut HashMap<String, i64>,
    ctx: &mut ActorContext,
) -> Result<()> {
    let key = (service.to_string(), incoming.msg_type.clone());
    let Some(actions) = program.handlers.get(&key) else {
        return Ok(());
    };

    for action in actions {
        execute_action(action, service, incoming, peers, state, ctx)?;
    }

    Ok(())
}

fn execute_action(
    action: &ActionDecl,
    service: &str,
    incoming: &RuntimeMessage,
    peers: &HashMap<Uuid, String>,
    state: &mut HashMap<String, i64>,
    ctx: &mut ActorContext,
) -> Result<()> {
    match action {
        ActionDecl::Log { template } => {
            let msg = render_template(template, ctx.self_node, service, incoming, state);
            println!("[{}] {}: {}", ctx.self_node, service, msg);
        }
        ActionDecl::SetState { key, value } => {
            let slot = state.get_mut(key).with_context(|| {
                format!("service `{service}` attempted set on unknown state `{key}`")
            })?;
            *slot = *value;
        }
        ActionDecl::IncState { key, by } => {
            let slot = state.get_mut(key).with_context(|| {
                format!("service `{service}` attempted inc on unknown state `{key}`")
            })?;
            *slot = slot
                .checked_add(*by)
                .with_context(|| format!("service `{service}` state overflow for `{key}`"))?;
        }
        ActionDecl::SendLocal {
            service: target_service,
            message,
            template,
        } => {
            let text = render_template(template, ctx.self_node, service, incoming, state);
            let outbound = RuntimeMessage {
                msg_type: message.clone(),
                from_node: ctx.self_node.to_string(),
                from_service: service.to_string(),
                text,
            };
            ctx.send_local_service(target_service.clone(), encode_msg(&outbound));
        }
        ActionDecl::SendRemote {
            target,
            service: target_service,
            message,
            template,
        } => {
            let text = render_template(template, ctx.self_node, service, incoming, state);
            let outbound = RuntimeMessage {
                msg_type: message.clone(),
                from_node: ctx.self_node.to_string(),
                from_service: service.to_string(),
                text,
            };
            let payload = encode_msg(&outbound);

            match target {
                RemoteTarget::Peers => {
                    let peer_ids = sorted_peer_ids(peers);
                    if peer_ids.is_empty() {
                        ctx.send_local_service(target_service.clone(), payload.clone());
                    } else {
                        for peer in peer_ids {
                            if peer == ctx.self_node {
                                ctx.send_local_service(target_service.clone(), payload.clone());
                            } else {
                                ctx.send_remote_service(
                                    peer,
                                    target_service.clone(),
                                    payload.clone(),
                                );
                            }
                        }
                    }
                }
                RemoteTarget::Sender => {
                    let Ok(sender_node) = Uuid::parse_str(&incoming.from_node) else {
                        eprintln!(
                            "[{}] {}: invalid sender node `{}`",
                            ctx.self_node, service, incoming.from_node
                        );
                        return Ok(());
                    };
                    if sender_node == ctx.self_node {
                        ctx.send_local_service(target_service.clone(), payload);
                    } else {
                        ctx.send_remote_service(sender_node, target_service.clone(), payload);
                    }
                }
                RemoteTarget::Node(raw) => {
                    let Ok(node) = Uuid::parse_str(raw) else {
                        eprintln!(
                            "[{}] {}: invalid remote node `{}`",
                            ctx.self_node, service, raw
                        );
                        return Ok(());
                    };
                    if node == ctx.self_node {
                        ctx.send_local_service(target_service.clone(), payload);
                    } else {
                        ctx.send_remote_service(node, target_service.clone(), payload);
                    }
                }
            }
        }
        ActionDecl::IfStateEq {
            key,
            value,
            then_action,
        } => {
            let current = state.get(key).with_context(|| {
                format!("service `{service}` attempted if on unknown state `{key}`")
            })?;
            if *current == *value {
                execute_action(then_action, service, incoming, peers, state, ctx)?;
            }
        }
    }
    Ok(())
}

fn record_event(
    writer: &mut Option<TraceWriter>,
    seq: &mut u64,
    seed: u64,
    kind: EventKind,
) -> Result<()> {
    let ev = TraceEvent {
        seq: *seq,
        seed,
        kind,
    };
    *seq += 1;

    writer
        .as_mut()
        .context("internal error: record mode without trace writer")?
        .write(&ev)?;

    Ok(())
}

#[derive(Debug)]
struct StagedInbound {
    env: WireEnvelope,
    release_step: u64,
}

struct FaultInjector {
    cfg: FaultConfig,
    seen_inbound: u64,
    reorder_buf: Vec<StagedInbound>,
    pending: VecDeque<StagedInbound>,
}

impl FaultInjector {
    fn new(cfg: FaultConfig) -> Self {
        Self {
            cfg,
            seen_inbound: 0,
            reorder_buf: Vec::new(),
            pending: VecDeque::new(),
        }
    }

    fn ingest(
        &mut self,
        env: WireEnvelope,
        current_step: u64,
        node_id: Uuid,
        seq: &mut u64,
        seed: u64,
        writer: &mut Option<TraceWriter>,
    ) -> Result<()> {
        self.seen_inbound += 1;
        if let Some(drop_every) = self.cfg.drop_every {
            if drop_every > 0 && self.seen_inbound % drop_every == 0 {
                record_event(
                    writer,
                    seq,
                    seed,
                    EventKind::FaultInjected {
                        node: node_id,
                        from_node: env.from_node,
                        to: env.to_actor,
                        msg_id: env.msg_id,
                        action: FaultAction::Drop,
                    },
                )?;
                return Ok(());
            }
        }

        let staged = StagedInbound {
            release_step: current_step.saturating_add(self.cfg.delay_steps),
            env,
        };

        if self.cfg.delay_steps > 0 {
            record_event(
                writer,
                seq,
                seed,
                EventKind::FaultInjected {
                    node: node_id,
                    from_node: staged.env.from_node,
                    to: staged.env.to_actor,
                    msg_id: staged.env.msg_id,
                    action: FaultAction::Delay {
                        steps: self.cfg.delay_steps,
                    },
                },
            )?;
        }

        if self.cfg.reorder_window <= 1 {
            self.pending.push_back(staged);
            return Ok(());
        }

        self.reorder_buf.push(staged);
        while self.reorder_buf.len() >= self.cfg.reorder_window {
            self.flush_chunk(node_id, seq, seed, writer)?;
        }
        Ok(())
    }

    fn flush_chunk(
        &mut self,
        node_id: Uuid,
        seq: &mut u64,
        seed: u64,
        writer: &mut Option<TraceWriter>,
    ) -> Result<()> {
        if self.reorder_buf.is_empty() {
            return Ok(());
        }

        let take = self.cfg.reorder_window.min(self.reorder_buf.len());
        let mut chunk: Vec<StagedInbound> = self.reorder_buf.drain(0..take).collect();

        if chunk.len() > 1 {
            for staged in &chunk {
                record_event(
                    writer,
                    seq,
                    seed,
                    EventKind::FaultInjected {
                        node: node_id,
                        from_node: staged.env.from_node,
                        to: staged.env.to_actor,
                        msg_id: staged.env.msg_id,
                        action: FaultAction::Reorder {
                            window: self.cfg.reorder_window as u64,
                        },
                    },
                )?;
            }
            chunk.reverse();
        }

        for staged in chunk {
            self.pending.push_back(staged);
        }
        Ok(())
    }

    fn flush_remainder(
        &mut self,
        node_id: Uuid,
        seq: &mut u64,
        seed: u64,
        writer: &mut Option<TraceWriter>,
    ) -> Result<()> {
        if self.cfg.reorder_window <= 1 {
            return Ok(());
        }
        if self.reorder_buf.is_empty() {
            return Ok(());
        }
        self.flush_chunk(node_id, seq, seed, writer)
    }

    fn release_due(&mut self, current_step: u64) -> Vec<WireEnvelope> {
        let mut out = Vec::new();
        while let Some(front) = self.pending.front() {
            if front.release_step > current_step {
                break;
            }
            let staged = self.pending.pop_front().expect("front existed");
            out.push(staged.env);
        }
        out
    }
}

fn drain_network(
    rx: &Receiver<WireEnvelope>,
    sys: &mut ActorSystem,
    node_id: Uuid,
    current_step: u64,
    seq: &mut u64,
    seed: u64,
    writer: &mut Option<TraceWriter>,
    injector: &mut FaultInjector,
) -> Result<()> {
    loop {
        let env = match rx.try_recv() {
            Ok(env) => env,
            Err(TryRecvError::Empty) => break,
            Err(TryRecvError::Disconnected) => break,
        };

        if env.to_node != node_id {
            continue;
        }

        injector.ingest(env, current_step, node_id, seq, seed, writer)?;
    }

    injector.flush_remainder(node_id, seq, seed, writer)?;

    for env in injector.release_due(current_step) {
        record_event(
            writer,
            seq,
            seed,
            EventKind::NetRecv {
                node: env.to_node,
                from_node: env.from_node,
                to: env.to_actor,
                msg_id: env.msg_id,
                payload: env.payload.clone(),
            },
        )?;

        match sys.actors.get_mut(&env.to_actor) {
            Some(actor) => actor.inbox.push_back((env.msg_id, env.payload)),
            None => eprintln!(
                "[{}] dropped inbound message for unknown actor {}",
                node_id, env.to_actor
            ),
        }
    }

    Ok(())
}

fn pending_inbox_messages(sys: &ActorSystem) -> usize {
    sys.actors.values().map(|a| a.inbox.len()).sum()
}

struct ReplayCursor {
    reader: TraceReader,
    buffered: Option<TraceEvent>,
}

impl ReplayCursor {
    fn open(path: &str) -> Result<Self> {
        Ok(Self {
            reader: TraceReader::open(path)?,
            buffered: None,
        })
    }

    fn next(&mut self) -> Result<Option<TraceEvent>> {
        if let Some(ev) = self.buffered.take() {
            return Ok(Some(ev));
        }
        self.reader.next()
    }

    fn unread(&mut self, ev: TraceEvent) {
        debug_assert!(
            self.buffered.is_none(),
            "replay cursor buffer already occupied"
        );
        self.buffered = Some(ev);
    }
}

fn next_replay_delivery(
    replay: &mut ReplayCursor,
    sys: &mut ActorSystem,
    node_id: Uuid,
) -> Result<Option<PendingDelivery>> {
    loop {
        let Some(ev) = replay.next()? else {
            return Ok(None);
        };

        match ev.kind {
            EventKind::NetRecv {
                node,
                to,
                msg_id,
                payload,
                ..
            } => {
                if node == node_id {
                    if let Some(actor) = sys.actors.get_mut(&to) {
                        actor.inbox.push_back((msg_id, payload));
                    } else {
                        eprintln!(
                            "[{}] replay dropped NetRecv for unknown actor {}",
                            node_id, to
                        );
                    }
                }
            }
            EventKind::Deliver { node, to, msg_id } => {
                if node == node_id {
                    return Ok(Some(PendingDelivery { node, to, msg_id }));
                }
            }
            EventKind::FaultInjected { .. } => {}
            _ => {}
        }
    }
}

fn verify_replay_emits(
    replay: &mut ReplayCursor,
    node_id: Uuid,
    expected: &[EventKind],
) -> Result<()> {
    for (idx, exp) in expected.iter().enumerate() {
        let Some(actual) = replay.next()? else {
            anyhow::bail!(
                "[{}] replay trace ended while expecting emitted event {}: {:?}",
                node_id,
                idx,
                exp
            );
        };
        if actual.kind != *exp {
            anyhow::bail!(
                "[{}] replay emitted event mismatch at index {}: expected {:?}, got {:?}",
                node_id,
                idx,
                exp,
                actual.kind
            );
        }
    }

    if let Some(ev) = replay.next()? {
        match ev.kind {
            EventKind::Send { .. } | EventKind::NetSend { .. } => {
                anyhow::bail!(
                    "[{}] replay observed unexpected additional emitted event: {:?}",
                    node_id,
                    ev.kind
                );
            }
            _ => replay.unread(ev),
        }
    }

    Ok(())
}

fn enqueue_bootstrap(
    sys: &mut ActorSystem,
    service_to_actor: &HashMap<String, Uuid>,
    entry_service: &str,
    cfg: &Config,
    msg_counter: &mut u64,
    writer: &mut Option<TraceWriter>,
    seq: &mut u64,
    seed: u64,
) -> Result<()> {
    let entry_actor = service_to_actor
        .get(entry_service)
        .copied()
        .with_context(|| format!("entry service `{entry_service}` not found"))?;

    let count = if cfg.bootstrap_hello {
        cfg.bootstrap_burst
    } else {
        1
    };

    for idx in 0..count {
        let msg = RuntimeMessage {
            msg_type: "start".to_string(),
            from_node: cfg.node_id.to_string(),
            from_service: "System".to_string(),
            text: format!("bootstrap #{}", idx + 1),
        };
        let payload = encode_msg(&msg);
        let msg_id = next_deterministic_msg_id(cfg.node_id, msg_counter);
        sys.actors
            .get_mut(&entry_actor)
            .context("entry actor id missing from actor system")?
            .inbox
            .push_back((msg_id, payload.clone()));

        if writer.is_some() {
            record_event(
                writer,
                seq,
                seed,
                EventKind::Send {
                    from: system_actor_id(),
                    to: entry_actor,
                    msg_id,
                    payload,
                },
            )?;
        }
    }

    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let cfg = parse_config(&args)?;
    let seed: u64 = 12345;
    let program = load_program(&cfg.program_path)?;

    let (mut sys, service_to_actor) = build_actor_system(&program);
    let entry_service = if service_to_actor.contains_key("Gateway") {
        "Gateway".to_string()
    } else {
        program
            .services
            .first()
            .cloned()
            .context("program has no services")?
    };

    let mut seq: u64 = 0;
    let mut msg_counter: u64 = 1;
    let mut writer = match cfg.mode {
        Mode::Record => Some(TraceWriter::create(&cfg.trace_path)?),
        Mode::Replay => None,
    };
    let mut replay = match cfg.mode {
        Mode::Replay => Some(ReplayCursor::open(&cfg.trace_path)?),
        Mode::Record => None,
    };
    let mut injector = FaultInjector::new(cfg.fault);

    let (net_tx, net_rx) = mpsc::channel::<WireEnvelope>();
    let _listener_handle = match (cfg.mode, cfg.listen.clone()) {
        (Mode::Record, Some(addr)) => Some(net::spawn_listener(addr, net_tx)?),
        _ => None,
    };

    if let Mode::Record = cfg.mode {
        record_event(
            &mut writer,
            &mut seq,
            seed,
            EventKind::Spawn {
                node: cfg.node_id,
                actor: system_actor_id(),
                service: "System".to_string(),
            },
        )?;
        for service in &program.services {
            let actor = service_to_actor
                .get(service)
                .copied()
                .with_context(|| format!("missing actor mapping for service `{service}`"))?;
            record_event(
                &mut writer,
                &mut seq,
                seed,
                EventKind::Spawn {
                    node: cfg.node_id,
                    actor,
                    service: service.clone(),
                },
            )?;
        }
    }

    enqueue_bootstrap(
        &mut sys,
        &service_to_actor,
        &entry_service,
        &cfg,
        &mut msg_counter,
        &mut writer,
        &mut seq,
        seed,
    )?;

    let mut replay_exhausted = false;
    for step in 0..cfg.steps {
        if let Mode::Record = cfg.mode {
            drain_network(
                &net_rx,
                &mut sys,
                cfg.node_id,
                step,
                &mut seq,
                seed,
                &mut writer,
                &mut injector,
            )?;
        }

        let mut pending = Vec::new();
        for (aid, actor) in &sys.actors {
            if let Some((msg_id, _)) = actor.inbox.front() {
                pending.push(PendingDelivery {
                    node: cfg.node_id,
                    to: *aid,
                    msg_id: *msg_id,
                });
            }
        }

        let next = match cfg.mode {
            Mode::Record => choose_next_deterministic(pending),
            Mode::Replay => {
                let replay = replay
                    .as_mut()
                    .context("internal error: replay mode without replay cursor")?;
                next_replay_delivery(replay, &mut sys, cfg.node_id)?
            }
        };

        let Some(d) = next else {
            match cfg.mode {
                Mode::Record => {
                    if cfg.idle_sleep_ms > 0 {
                        std::thread::sleep(Duration::from_millis(cfg.idle_sleep_ms));
                    }
                }
                Mode::Replay => {
                    replay_exhausted = true;
                    let pending = pending_inbox_messages(&sys);
                    if pending > 0 {
                        anyhow::bail!(
                            "[{}] replay trace exhausted with {} undelivered inbox message(s)",
                            cfg.node_id,
                            pending
                        );
                    }
                    break;
                }
            }
            continue;
        };

        if let Mode::Record = cfg.mode {
            record_event(
                &mut writer,
                &mut seq,
                seed,
                EventKind::Deliver {
                    node: d.node,
                    to: d.to,
                    msg_id: d.msg_id,
                },
            )?;
        }

        let (actor_id, actor_service, msg_id, payload) = {
            let actor = sys
                .actors
                .get_mut(&d.to)
                .with_context(|| format!("unknown actor id {}", d.to))?;
            let (msg_id, payload) = actor
                .inbox
                .pop_front()
                .with_context(|| format!("empty inbox for actor {}", actor.id))?;
            (actor.id, actor.service.clone(), msg_id, payload)
        };

        if matches!(cfg.mode, Mode::Replay) && msg_id != d.msg_id {
            anyhow::bail!(
                "[{}] replay msg_id mismatch for actor {} (trace={}, runtime={})",
                cfg.node_id,
                d.to,
                d.msg_id,
                msg_id
            );
        }

        let incoming = decode_msg(payload)
            .with_context(|| format!("decode inbound message for service `{}`", actor_service))?;

        let mut ctx = ActorContext::new(cfg.node_id);
        {
            let actor = sys
                .actors
                .get_mut(&actor_id)
                .with_context(|| format!("unknown actor id {}", actor_id))?;
            execute_actions(
                &program,
                &actor_service,
                &incoming,
                &cfg.peers,
                &mut actor.state,
                &mut ctx,
            )
            .with_context(|| format!("execute service `{}`", actor_service))?;
        }

        let mut replay_expected: Vec<EventKind> = Vec::new();
        for out in ctx.outbox {
            match out.target {
                Target::LocalService(service_name) => {
                    let Some(to_actor_id) = service_to_actor.get(&service_name).copied() else {
                        eprintln!(
                            "[{}] unknown local target service `{}`",
                            cfg.node_id, service_name
                        );
                        continue;
                    };

                    let msg_id = next_deterministic_msg_id(cfg.node_id, &mut msg_counter);
                    let to_actor = sys
                        .actors
                        .get_mut(&to_actor_id)
                        .context("actor missing for known service mapping")?;
                    to_actor.inbox.push_back((msg_id, out.payload.clone()));

                    let ev = EventKind::Send {
                        from: actor_id,
                        to: to_actor_id,
                        msg_id,
                        payload: out.payload,
                    };

                    match cfg.mode {
                        Mode::Record => {
                            record_event(&mut writer, &mut seq, seed, ev)?;
                        }
                        Mode::Replay => replay_expected.push(ev),
                    }
                }
                Target::RemoteService {
                    node,
                    service: service_name,
                } => {
                    let Some(to_actor_id) = service_to_actor.get(&service_name).copied() else {
                        eprintln!(
                            "[{}] unknown remote target service `{}`",
                            cfg.node_id, service_name
                        );
                        continue;
                    };

                    let msg_id = next_deterministic_msg_id(cfg.node_id, &mut msg_counter);
                    let envelope = WireEnvelope {
                        from_node: cfg.node_id,
                        to_node: node,
                        to_actor: to_actor_id,
                        msg_id,
                        payload: out.payload.clone(),
                    };

                    let ev = EventKind::NetSend {
                        node: cfg.node_id,
                        to_node: node,
                        from: actor_id,
                        msg_id,
                        payload: out.payload,
                    };

                    match cfg.mode {
                        Mode::Record => {
                            if let Some(addr) = cfg.peers.get(&node) {
                                if let Err(err) = net::send_envelope(addr, &envelope) {
                                    eprintln!(
                                        "[{}] send to peer {} ({}) failed: {}",
                                        cfg.node_id, node, addr, err
                                    );
                                }
                            } else {
                                eprintln!(
                                    "[{}] no peer address configured for node {}",
                                    cfg.node_id, node
                                );
                            }

                            record_event(&mut writer, &mut seq, seed, ev)?;
                        }
                        Mode::Replay => replay_expected.push(ev),
                    }
                }
            }
        }

        if let Mode::Replay = cfg.mode {
            let replay = replay
                .as_mut()
                .context("internal error: replay mode without replay cursor")?;
            verify_replay_emits(replay, cfg.node_id, &replay_expected)?;
        }
    }

    if matches!(cfg.mode, Mode::Replay) && !replay_exhausted {
        let replay = replay
            .as_mut()
            .context("internal error: replay mode without replay cursor")?;
        if let Some(next) = next_replay_delivery(replay, &mut sys, cfg.node_id)? {
            anyhow::bail!(
                "[{}] replay stopped early after {} steps (next trace delivery msg_id={} actor={})",
                cfg.node_id,
                cfg.steps,
                next.msg_id,
                next.to
            );
        }
        let pending = pending_inbox_messages(&sys);
        if pending > 0 {
            anyhow::bail!(
                "[{}] replay trace exhausted with {} undelivered inbox message(s)",
                cfg.node_id,
                pending
            );
        }
    }

    if let Some(w) = writer.as_mut() {
        w.flush()?;
        println!("[{}] trace written to {}", cfg.node_id, cfg.trace_path);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::actor::Target;

    fn test_message(msg_type: &str, text: &str) -> RuntimeMessage {
        RuntimeMessage {
            msg_type: msg_type.to_string(),
            from_node: "00000000-0000-0000-0000-000000000000".to_string(),
            from_service: "System".to_string(),
            text: text.to_string(),
        }
    }

    fn test_program(actions: Vec<ActionDecl>) -> Program {
        let mut handlers = HashMap::new();
        handlers.insert(("Gateway".to_string(), "start".to_string()), actions);
        Program {
            services: vec!["Gateway".to_string()],
            service_initial_state: HashMap::new(),
            handlers,
        }
    }

    #[test]
    fn executes_state_and_conditional_send() {
        let program = test_program(vec![
            ActionDecl::SetState {
                key: "count".to_string(),
                value: 0,
            },
            ActionDecl::IncState {
                key: "count".to_string(),
                by: 1,
            },
            ActionDecl::IfStateEq {
                key: "count".to_string(),
                value: 1,
                then_action: Box::new(ActionDecl::SendLocal {
                    service: "Gateway".to_string(),
                    message: "echo".to_string(),
                    template: "count=$state.count".to_string(),
                }),
            },
        ]);

        let mut state = HashMap::from([(String::from("count"), 42_i64)]);
        let mut ctx = ActorContext::new(Uuid::nil());
        execute_actions(
            &program,
            "Gateway",
            &test_message("start", "boot"),
            &HashMap::new(),
            &mut state,
            &mut ctx,
        )
        .expect("execute_actions should succeed");

        assert_eq!(state.get("count"), Some(&1));
        assert_eq!(ctx.outbox.len(), 1);
        match &ctx.outbox[0].target {
            Target::LocalService(svc) => assert_eq!(svc, "Gateway"),
            other => panic!("unexpected target: {other:?}"),
        }

        let payload = decode_msg(ctx.outbox[0].payload.clone()).expect("payload should decode");
        assert_eq!(payload.msg_type, "echo");
        assert_eq!(payload.text, "count=1");
    }

    #[test]
    fn skips_conditional_when_state_does_not_match() {
        let program = test_program(vec![ActionDecl::IfStateEq {
            key: "count".to_string(),
            value: 2,
            then_action: Box::new(ActionDecl::SendLocal {
                service: "Gateway".to_string(),
                message: "echo".to_string(),
                template: "count=$state.count".to_string(),
            }),
        }]);

        let mut state = HashMap::from([(String::from("count"), 1_i64)]);
        let mut ctx = ActorContext::new(Uuid::nil());
        execute_actions(
            &program,
            "Gateway",
            &test_message("start", "boot"),
            &HashMap::new(),
            &mut state,
            &mut ctx,
        )
        .expect("execute_actions should succeed");

        assert!(ctx.outbox.is_empty());
        assert_eq!(state.get("count"), Some(&1));
    }
}
