mod actor;
mod event;
mod net;
mod scheduler;
mod trace;

use actor::{Actor, ActorContext, ActorSystem, Target};
use anyhow::{Context, Result};
use event::{EffectKind as RuntimeEffectKind, EventKind, FaultAction, TraceEvent};
use lang::{parse_module, ActionDecl, HandlerEffect, RemoteTarget};
use net::WireEnvelope;
use scheduler::{choose_next_deterministic, PendingDelivery};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FaultPolicy {
    drop_every: Option<u64>,
    delay_steps: u64,
    reorder_window: usize,
}

impl Default for FaultPolicy {
    fn default() -> Self {
        Self {
            drop_every: None,
            delay_steps: 0,
            reorder_window: 1,
        }
    }
}

#[derive(Clone, Debug)]
struct FaultPhase {
    start_step: u64,
    end_step: Option<u64>,
    policy: FaultPolicy,
}

impl FaultPhase {
    fn is_active(&self, step: u64) -> bool {
        if step < self.start_step {
            return false;
        }
        match self.end_step {
            Some(end) => step <= end,
            None => true,
        }
    }
}

#[derive(Clone, Debug)]
struct FaultConfig {
    drop_every: Option<u64>,
    delay_steps: u64,
    reorder_window: usize,
    phases: Vec<FaultPhase>,
}

impl FaultConfig {
    fn base_policy(&self) -> FaultPolicy {
        FaultPolicy {
            drop_every: self.drop_every,
            delay_steps: self.delay_steps,
            reorder_window: self.reorder_window,
        }
    }

    fn policy_for_step(&self, step: u64) -> FaultPolicy {
        let mut policy = self.base_policy();
        for phase in &self.phases {
            if phase.is_active(step) {
                policy = phase.policy;
            }
        }
        policy
    }

    fn sort_and_validate_phases(&mut self) -> Result<()> {
        self.phases.sort_by_key(|p| p.start_step);

        let mut prev_end: Option<u64> = None;
        for (idx, phase) in self.phases.iter().enumerate() {
            if let Some(end) = phase.end_step {
                if end < phase.start_step {
                    anyhow::bail!(
                        "fault phase #{idx} has end_step < start_step (start={} end={})",
                        phase.start_step,
                        end
                    );
                }
            }
            if let Some(end) = prev_end {
                if phase.start_step <= end {
                    anyhow::bail!(
                        "fault phases overlap at step {} (previous ended at {})",
                        phase.start_step,
                        end
                    );
                }
            }
            if prev_end.is_none() && idx > 0 {
                anyhow::bail!("fault phase with open-ended range must be last");
            }
            prev_end = phase.end_step;
        }

        Ok(())
    }
}

impl Default for FaultConfig {
    fn default() -> Self {
        Self {
            drop_every: None,
            delay_steps: 0,
            reorder_window: 1,
            phases: Vec::new(),
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
    startup_wait_ms: u64,
    fault: FaultConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Provenance {
    origin_node: String,
    origin_service: String,
    origin_msg_id: String,
    parent_node: String,
    parent_msg_id: String,
    hops: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RuntimeMessage {
    #[serde(rename = "type")]
    msg_type: String,
    from_node: String,
    from_service: String,
    text: String,
    #[serde(default)]
    provenance: Option<Provenance>,
}

#[derive(Debug, Clone)]
struct Program {
    services: Vec<String>,
    service_initial_state: HashMap<String, HashMap<String, i64>>,
    handlers: HashMap<(String, String), HandlerPlan>,
}

#[derive(Debug, Clone)]
struct HandlerPlan {
    actions: Vec<ActionDecl>,
    declared_effects: Vec<HandlerEffect>,
}

fn next_deterministic_msg_id(node_id: Uuid, counter: &mut u64) -> Uuid {
    let id = Uuid::from_u128(node_id.as_u128().wrapping_add(*counter as u128));
    *counter = counter.saturating_add(1);
    id
}

fn next_deterministic_timer_id(node_id: Uuid, counter: &mut u64) -> Uuid {
    let timer_offset = 1_u128 << 96;
    let id = Uuid::from_u128(
        node_id
            .as_u128()
            .wrapping_add(timer_offset)
            .wrapping_add(*counter as u128),
    );
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
    eprintln!("  --startup-wait-ms <n>       Wait n ms before scheduling loop (record mode only)");
    eprintln!("  --fault-drop-every <n>      Drop every n-th inbound wire message");
    eprintln!("  --fault-delay-steps <n>     Delay inbound wire messages by n runtime steps");
    eprintln!("  --fault-reorder-window <n>  Reverse inbound arrivals in chunks of n");
    eprintln!("  --fault-phase <s:e:d:l:r>   Override faults for steps [s..e] (e may be *), drop=d, delay=l, reorder=r");
}

fn parse_peer_spec(spec: &str) -> Result<(Uuid, String)> {
    let (node, addr) = spec
        .split_once('=')
        .with_context(|| format!("invalid peer format `{spec}`, expected <uuid=host:port>"))?;
    let node = Uuid::parse_str(node).with_context(|| format!("invalid peer node id `{node}`"))?;
    Ok((node, addr.to_string()))
}

fn parse_fault_phase_spec(spec: &str) -> Result<FaultPhase> {
    let parts: Vec<&str> = spec.split(':').collect();
    if parts.len() != 5 {
        anyhow::bail!(
            "invalid --fault-phase `{spec}`; expected <start:end:drop_every:delay_steps:reorder_window>"
        );
    }

    let start_step = parts[0]
        .parse::<u64>()
        .with_context(|| format!("invalid --fault-phase start step `{}`", parts[0]))?;

    let end_step = if parts[1] == "*" {
        None
    } else {
        Some(
            parts[1]
                .parse::<u64>()
                .with_context(|| format!("invalid --fault-phase end step `{}`", parts[1]))?,
        )
    };

    let drop_every_raw = parts[2]
        .parse::<u64>()
        .with_context(|| format!("invalid --fault-phase drop_every `{}`", parts[2]))?;
    let drop_every = if drop_every_raw == 0 {
        None
    } else {
        Some(drop_every_raw)
    };

    let delay_steps = parts[3]
        .parse::<u64>()
        .with_context(|| format!("invalid --fault-phase delay_steps `{}`", parts[3]))?;

    let reorder_window = parts[4]
        .parse::<usize>()
        .with_context(|| format!("invalid --fault-phase reorder_window `{}`", parts[4]))?;
    if reorder_window == 0 {
        anyhow::bail!("--fault-phase reorder_window must be >= 1");
    }

    Ok(FaultPhase {
        start_step,
        end_step,
        policy: FaultPolicy {
            drop_every,
            delay_steps,
            reorder_window,
        },
    })
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
    let mut startup_wait_ms: u64 = 0;
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
            "--startup-wait-ms" => {
                i += 1;
                let value = args.get(i).context("missing value for --startup-wait-ms")?;
                startup_wait_ms = value
                    .parse::<u64>()
                    .with_context(|| format!("invalid --startup-wait-ms value `{value}`"))?;
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
            "--fault-phase" => {
                i += 1;
                let value = args.get(i).context("missing value for --fault-phase")?;
                let phase = parse_fault_phase_spec(value)?;
                fault.phases.push(phase);
            }
            other => anyhow::bail!("unknown argument: {other}"),
        }
        i += 1;
    }

    fault.sort_and_validate_phases()?;

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
        startup_wait_ms,
        fault,
    })
}

fn load_program(path: &str) -> Result<Program> {
    let src = fs::read_to_string(path).with_context(|| format!("read program file `{path}`"))?;
    let module = parse_module(&src).with_context(|| format!("parse program file `{path}`"))?;

    let mut services = Vec::new();
    let mut seen = HashSet::<String>::new();
    let mut service_initial_state = HashMap::<String, HashMap<String, i64>>::new();
    let mut handlers = HashMap::<(String, String), HandlerPlan>::new();

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
            let plan = handlers.entry(key).or_insert_with(|| HandlerPlan {
                actions: Vec::new(),
                declared_effects: Vec::new(),
            });
            if !plan.declared_effects.is_empty() {
                anyhow::bail!(
                    "service `{}` handler `on {}` declares effects more than once",
                    service.name,
                    handler.on
                );
            }
            plan.declared_effects = handler.effects;
            plan.actions.extend(handler.actions);
        }
    }

    let service_names: HashSet<String> = services.iter().cloned().collect();
    for ((service_name, msg_type), plan) in &handlers {
        let state = service_initial_state
            .get(service_name)
            .with_context(|| format!("internal error: missing state for `{service_name}`"))?;
        for action in &plan.actions {
            validate_action(action, service_name, msg_type, state, &service_names)?;
        }

        let inferred = infer_effects(&plan.actions);
        let declared_set: BTreeSet<HandlerEffect> = plan.declared_effects.iter().copied().collect();
        if inferred != declared_set {
            anyhow::bail!(
                "service `{service_name}` handler `on {msg_type}` effect contract mismatch: declared [{}], inferred [{}]",
                format_effects(&declared_set),
                format_effects(&inferred)
            );
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
        | ActionDecl::TimerLocal {
            service: target_service,
            ..
        }
        | ActionDecl::TimerRemote {
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

    if let ActionDecl::TimerLocal { steps, .. } | ActionDecl::TimerRemote { steps, .. } = action {
        if *steps == 0 {
            anyhow::bail!(
                "service `{service_name}` handler `on {msg_type}` has timer with zero steps"
            );
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

    if let ActionDecl::TimerRemote {
        target: RemoteTarget::Node(raw),
        ..
    } = action
    {
        Uuid::parse_str(raw).with_context(|| {
            format!(
                "service `{service_name}` handler `on {msg_type}` has invalid timer node target `{raw}`"
            )
        })?;
    }

    Ok(())
}

fn infer_effects(actions: &[ActionDecl]) -> BTreeSet<HandlerEffect> {
    let mut out = BTreeSet::new();
    for action in actions {
        infer_action_effects(action, &mut out);
    }
    out
}

fn infer_action_effects(action: &ActionDecl, out: &mut BTreeSet<HandlerEffect>) {
    match action {
        ActionDecl::Log { .. } => {
            out.insert(HandlerEffect::Log);
        }
        ActionDecl::SetState { .. } | ActionDecl::IncState { .. } => {
            out.insert(HandlerEffect::StateWrite);
        }
        ActionDecl::TimerLocal { .. } => {
            out.insert(HandlerEffect::TimerLocal);
        }
        ActionDecl::TimerRemote { .. } => {
            out.insert(HandlerEffect::TimerRemote);
        }
        ActionDecl::SendLocal { .. } => {
            out.insert(HandlerEffect::SendLocal);
        }
        ActionDecl::SendRemote { .. } => {
            out.insert(HandlerEffect::SendRemote);
        }
        ActionDecl::IfStateEq { then_action, .. } => {
            out.insert(HandlerEffect::StateRead);
            infer_action_effects(then_action, out);
        }
    }
}

fn format_effects(effects: &BTreeSet<HandlerEffect>) -> String {
    effects
        .iter()
        .map(|e| match e {
            HandlerEffect::Log => "log",
            HandlerEffect::StateRead => "state_read",
            HandlerEffect::StateWrite => "state_write",
            HandlerEffect::SendLocal => "send_local",
            HandlerEffect::SendRemote => "send_remote",
            HandlerEffect::TimerLocal => "timer_local",
            HandlerEffect::TimerRemote => "timer_remote",
        })
        .collect::<Vec<_>>()
        .join(", ")
}

fn to_runtime_effect(effect: HandlerEffect) -> RuntimeEffectKind {
    match effect {
        HandlerEffect::Log => RuntimeEffectKind::Log,
        HandlerEffect::StateRead => RuntimeEffectKind::StateRead,
        HandlerEffect::StateWrite => RuntimeEffectKind::StateWrite,
        HandlerEffect::SendLocal => RuntimeEffectKind::SendLocal,
        HandlerEffect::SendRemote => RuntimeEffectKind::SendRemote,
        HandlerEffect::TimerLocal => RuntimeEffectKind::TimerLocal,
        HandlerEffect::TimerRemote => RuntimeEffectKind::TimerRemote,
    }
}

fn effect_vec(effects: &BTreeSet<HandlerEffect>) -> Vec<RuntimeEffectKind> {
    effects.iter().copied().map(to_runtime_effect).collect()
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

fn next_outbound_provenance(incoming: &RuntimeMessage, incoming_msg_id: Uuid) -> Provenance {
    if let Some(prev) = incoming.provenance.as_ref() {
        return Provenance {
            origin_node: prev.origin_node.clone(),
            origin_service: prev.origin_service.clone(),
            origin_msg_id: prev.origin_msg_id.clone(),
            parent_node: incoming.from_node.clone(),
            parent_msg_id: incoming_msg_id.to_string(),
            hops: prev.hops.saturating_add(1),
        };
    }

    Provenance {
        origin_node: incoming.from_node.clone(),
        origin_service: incoming.from_service.clone(),
        origin_msg_id: incoming_msg_id.to_string(),
        parent_node: incoming.from_node.clone(),
        parent_msg_id: incoming_msg_id.to_string(),
        hops: 1,
    }
}

fn build_outbound_message(
    msg_type: &str,
    text: String,
    self_node: Uuid,
    service: &str,
    incoming: &RuntimeMessage,
    incoming_msg_id: Uuid,
) -> RuntimeMessage {
    RuntimeMessage {
        msg_type: msg_type.to_string(),
        from_node: self_node.to_string(),
        from_service: service.to_string(),
        text,
        provenance: Some(next_outbound_provenance(incoming, incoming_msg_id)),
    }
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
    let (
        prov_origin_node,
        prov_origin_service,
        prov_origin_msg,
        prov_parent_node,
        prov_parent_msg,
        prov_hops,
    ) = if let Some(prov) = incoming.provenance.as_ref() {
        (
            prov.origin_node.as_str(),
            prov.origin_service.as_str(),
            prov.origin_msg_id.as_str(),
            prov.parent_node.as_str(),
            prov.parent_msg_id.as_str(),
            prov.hops.to_string(),
        )
    } else {
        ("", "", "", "", "", String::new())
    };
    out = out.replace("$prov.origin_node", prov_origin_node);
    out = out.replace("$prov.origin_service", prov_origin_service);
    out = out.replace("$prov.origin_msg", prov_origin_msg);
    out = out.replace("$prov.parent_node", prov_parent_node);
    out = out.replace("$prov.parent_msg", prov_parent_msg);
    out = out.replace("$prov.hops", &prov_hops);

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

fn dispatch_outgoing(
    cfg: &Config,
    sys: &mut ActorSystem,
    service_to_actor: &HashMap<String, Uuid>,
    from_actor: Uuid,
    target: Target,
    payload: Value,
    msg_counter: &mut u64,
    mode: Mode,
) -> Result<EventKind> {
    match target {
        Target::LocalService(service_name) => {
            let to_actor_id = service_to_actor
                .get(&service_name)
                .copied()
                .with_context(|| format!("unknown local target service `{service_name}`"))?;
            let msg_id = next_deterministic_msg_id(cfg.node_id, msg_counter);
            let to_actor = sys
                .actors
                .get_mut(&to_actor_id)
                .context("actor missing for known service mapping")?;
            to_actor.inbox.push_back((msg_id, payload.clone()));

            Ok(EventKind::Send {
                from: from_actor,
                to: to_actor_id,
                msg_id,
                payload,
            })
        }
        Target::RemoteService {
            node,
            service: service_name,
        } => {
            let to_actor_id = service_to_actor
                .get(&service_name)
                .copied()
                .with_context(|| format!("unknown remote target service `{service_name}`"))?;
            let msg_id = next_deterministic_msg_id(cfg.node_id, msg_counter);
            let envelope = WireEnvelope {
                from_node: cfg.node_id,
                to_node: node,
                to_actor: to_actor_id,
                msg_id,
                payload: payload.clone(),
            };

            if matches!(mode, Mode::Record) {
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
            }

            Ok(EventKind::NetSend {
                node: cfg.node_id,
                to_node: node,
                from: from_actor,
                msg_id,
                payload,
            })
        }
    }
}

fn execute_actions(
    program: &Program,
    service: &str,
    incoming_msg_id: Uuid,
    incoming: &RuntimeMessage,
    peers: &HashMap<Uuid, String>,
    state: &mut HashMap<String, i64>,
    ctx: &mut ActorContext,
) -> Result<ExecutedEffects> {
    let key = (service.to_string(), incoming.msg_type.clone());
    let Some(plan) = program.handlers.get(&key) else {
        return Ok(ExecutedEffects::default());
    };

    let declared = plan.declared_effects.iter().copied().collect();
    let mut observed = BTreeSet::new();

    for action in &plan.actions {
        execute_action(
            action,
            service,
            incoming_msg_id,
            incoming,
            peers,
            state,
            ctx,
            &mut observed,
        )?;
    }

    Ok(ExecutedEffects { declared, observed })
}

#[derive(Debug, Default)]
struct ExecutedEffects {
    declared: BTreeSet<HandlerEffect>,
    observed: BTreeSet<HandlerEffect>,
}

fn execute_action(
    action: &ActionDecl,
    service: &str,
    incoming_msg_id: Uuid,
    incoming: &RuntimeMessage,
    peers: &HashMap<Uuid, String>,
    state: &mut HashMap<String, i64>,
    ctx: &mut ActorContext,
    observed_effects: &mut BTreeSet<HandlerEffect>,
) -> Result<()> {
    match action {
        ActionDecl::Log { template } => {
            observed_effects.insert(HandlerEffect::Log);
            let msg = render_template(template, ctx.self_node, service, incoming, state);
            ctx.log(service.to_string(), msg);
        }
        ActionDecl::SetState { key, value } => {
            observed_effects.insert(HandlerEffect::StateWrite);
            let slot = state.get_mut(key).with_context(|| {
                format!("service `{service}` attempted set on unknown state `{key}`")
            })?;
            *slot = *value;
        }
        ActionDecl::IncState { key, by } => {
            observed_effects.insert(HandlerEffect::StateWrite);
            let slot = state.get_mut(key).with_context(|| {
                format!("service `{service}` attempted inc on unknown state `{key}`")
            })?;
            *slot = slot
                .checked_add(*by)
                .with_context(|| format!("service `{service}` state overflow for `{key}`"))?;
        }
        ActionDecl::TimerLocal {
            steps,
            service: target_service,
            message,
            template,
        } => {
            observed_effects.insert(HandlerEffect::TimerLocal);
            let text = render_template(template, ctx.self_node, service, incoming, state);
            let outbound = build_outbound_message(
                message,
                text,
                ctx.self_node,
                service,
                incoming,
                incoming_msg_id,
            );
            ctx.send_local_service_after(*steps, target_service.clone(), encode_msg(&outbound));
        }
        ActionDecl::TimerRemote {
            steps,
            target,
            service: target_service,
            message,
            template,
        } => {
            observed_effects.insert(HandlerEffect::TimerRemote);
            let text = render_template(template, ctx.self_node, service, incoming, state);
            let outbound = build_outbound_message(
                message,
                text,
                ctx.self_node,
                service,
                incoming,
                incoming_msg_id,
            );
            let payload = encode_msg(&outbound);

            match target {
                RemoteTarget::Peers => {
                    let peer_ids = sorted_peer_ids(peers);
                    if peer_ids.is_empty() {
                        ctx.send_local_service_after(
                            *steps,
                            target_service.clone(),
                            payload.clone(),
                        );
                    } else {
                        for peer in peer_ids {
                            if peer == ctx.self_node {
                                ctx.send_local_service_after(
                                    *steps,
                                    target_service.clone(),
                                    payload.clone(),
                                );
                            } else {
                                ctx.send_remote_service_after(
                                    *steps,
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
                        ctx.send_local_service_after(*steps, target_service.clone(), payload);
                    } else {
                        ctx.send_remote_service_after(
                            *steps,
                            sender_node,
                            target_service.clone(),
                            payload,
                        );
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
                        ctx.send_local_service_after(*steps, target_service.clone(), payload);
                    } else {
                        ctx.send_remote_service_after(
                            *steps,
                            node,
                            target_service.clone(),
                            payload,
                        );
                    }
                }
            }
        }
        ActionDecl::SendLocal {
            service: target_service,
            message,
            template,
        } => {
            observed_effects.insert(HandlerEffect::SendLocal);
            let text = render_template(template, ctx.self_node, service, incoming, state);
            let outbound = build_outbound_message(
                message,
                text,
                ctx.self_node,
                service,
                incoming,
                incoming_msg_id,
            );
            ctx.send_local_service(target_service.clone(), encode_msg(&outbound));
        }
        ActionDecl::SendRemote {
            target,
            service: target_service,
            message,
            template,
        } => {
            observed_effects.insert(HandlerEffect::SendRemote);
            let text = render_template(template, ctx.self_node, service, incoming, state);
            let outbound = build_outbound_message(
                message,
                text,
                ctx.self_node,
                service,
                incoming,
                incoming_msg_id,
            );
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
            observed_effects.insert(HandlerEffect::StateRead);
            let current = state.get(key).with_context(|| {
                format!("service `{service}` attempted if on unknown state `{key}`")
            })?;
            if *current == *value {
                execute_action(
                    then_action,
                    service,
                    incoming_msg_id,
                    incoming,
                    peers,
                    state,
                    ctx,
                    observed_effects,
                )?;
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

#[derive(Debug)]
struct PendingTimer {
    due_step: u64,
    timer_id: Uuid,
    from_actor: Uuid,
    target: Target,
    payload: Value,
}

struct FaultInjector {
    cfg: FaultConfig,
    seen_inbound: u64,
    active_policy: FaultPolicy,
    policy_initialized: bool,
    reorder_buf: Vec<StagedInbound>,
    pending: VecDeque<StagedInbound>,
}

impl FaultInjector {
    fn new(cfg: FaultConfig) -> Self {
        Self {
            active_policy: cfg.policy_for_step(0),
            cfg,
            seen_inbound: 0,
            policy_initialized: false,
            reorder_buf: Vec::new(),
            pending: VecDeque::new(),
        }
    }

    fn record_policy_event(
        &self,
        step: u64,
        node_id: Uuid,
        seq: &mut u64,
        seed: u64,
        writer: &mut Option<TraceWriter>,
    ) -> Result<()> {
        record_event(
            writer,
            seq,
            seed,
            EventKind::FaultPolicy {
                node: node_id,
                step,
                drop_every: self.active_policy.drop_every,
                delay_steps: self.active_policy.delay_steps,
                reorder_window: self.active_policy.reorder_window as u64,
            },
        )
    }

    fn sync_policy(
        &mut self,
        current_step: u64,
        node_id: Uuid,
        seq: &mut u64,
        seed: u64,
        writer: &mut Option<TraceWriter>,
    ) -> Result<()> {
        if !self.policy_initialized {
            self.active_policy = self.cfg.policy_for_step(current_step);
            self.record_policy_event(current_step, node_id, seq, seed, writer)?;
            self.policy_initialized = true;
            return Ok(());
        }

        let next_policy = self.cfg.policy_for_step(current_step);
        if next_policy == self.active_policy {
            return Ok(());
        }
        self.flush_remainder_with_window(
            node_id,
            seq,
            seed,
            writer,
            self.active_policy.reorder_window,
        )?;
        self.active_policy = next_policy;
        self.record_policy_event(current_step, node_id, seq, seed, writer)?;
        Ok(())
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
        self.sync_policy(current_step, node_id, seq, seed, writer)?;

        self.seen_inbound += 1;
        if let Some(drop_every) = self.active_policy.drop_every {
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
            release_step: current_step.saturating_add(self.active_policy.delay_steps),
            env,
        };

        if self.active_policy.delay_steps > 0 {
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
                        steps: self.active_policy.delay_steps,
                    },
                },
            )?;
        }

        if self.active_policy.reorder_window <= 1 {
            self.pending.push_back(staged);
            return Ok(());
        }

        self.reorder_buf.push(staged);
        while self.reorder_buf.len() >= self.active_policy.reorder_window {
            self.flush_chunk(
                node_id,
                seq,
                seed,
                writer,
                self.active_policy.reorder_window,
            )?;
        }
        Ok(())
    }

    fn flush_chunk(
        &mut self,
        node_id: Uuid,
        seq: &mut u64,
        seed: u64,
        writer: &mut Option<TraceWriter>,
        reorder_window: usize,
    ) -> Result<()> {
        if self.reorder_buf.is_empty() {
            return Ok(());
        }

        let take = reorder_window.min(self.reorder_buf.len());
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
                            window: reorder_window as u64,
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
        self.flush_remainder_with_window(
            node_id,
            seq,
            seed,
            writer,
            self.active_policy.reorder_window,
        )
    }

    fn flush_remainder_with_window(
        &mut self,
        node_id: Uuid,
        seq: &mut u64,
        seed: u64,
        writer: &mut Option<TraceWriter>,
        reorder_window: usize,
    ) -> Result<()> {
        if reorder_window <= 1 {
            return Ok(());
        }
        if self.reorder_buf.is_empty() {
            return Ok(());
        }
        self.flush_chunk(node_id, seq, seed, writer, reorder_window)
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
    injector.sync_policy(current_step, node_id, seq, seed, writer)?;

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
    cfg: &Config,
    service_to_actor: &HashMap<String, Uuid>,
    msg_counter: &mut u64,
    pending_timers: &mut Vec<PendingTimer>,
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
                inject_replay_netrecv(sys, cfg.node_id, node, to, msg_id, payload);
            }
            EventKind::Deliver { node, to, msg_id } => {
                if node == cfg.node_id {
                    return Ok(Some(PendingDelivery { node, to, msg_id }));
                }
            }
            EventKind::FaultInjected { .. } | EventKind::FaultPolicy { .. } => {}
            EventKind::TimerFired {
                node,
                from,
                timer_id,
            } => {
                replay_fire_timer(
                    replay,
                    sys,
                    cfg,
                    service_to_actor,
                    msg_counter,
                    pending_timers,
                    node,
                    from,
                    timer_id,
                )?;
            }
            EventKind::Send { .. }
            | EventKind::NetSend { .. }
            | EventKind::Spawn { .. }
            | EventKind::Log { .. }
            | EventKind::EffectObserved { .. } => {
                anyhow::bail!(
                    "[{}] replay encountered unexpected emitted event while awaiting delivery: {:?}",
                    cfg.node_id,
                    ev.kind
                );
            }
        }
    }
}

fn inject_replay_netrecv(
    sys: &mut ActorSystem,
    node_id: Uuid,
    node: Uuid,
    to: Uuid,
    msg_id: Uuid,
    payload: serde_json::Value,
) {
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

fn drain_replay_inbound(
    replay: &mut ReplayCursor,
    sys: &mut ActorSystem,
    node_id: Uuid,
) -> Result<()> {
    loop {
        let Some(ev) = replay.next()? else {
            return Ok(());
        };

        match ev.kind {
            EventKind::NetRecv {
                node,
                to,
                msg_id,
                payload,
                ..
            } => {
                inject_replay_netrecv(sys, node_id, node, to, msg_id, payload);
            }
            EventKind::FaultInjected { .. } | EventKind::FaultPolicy { .. } => {}
            _ => {
                replay.unread(ev);
                return Ok(());
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn replay_fire_timer(
    replay: &mut ReplayCursor,
    sys: &mut ActorSystem,
    cfg: &Config,
    service_to_actor: &HashMap<String, Uuid>,
    msg_counter: &mut u64,
    pending_timers: &mut Vec<PendingTimer>,
    node: Uuid,
    from: Uuid,
    timer_id: Uuid,
) -> Result<()> {
    if node != cfg.node_id {
        return Ok(());
    }

    let timer_idx = pending_timers
        .iter()
        .position(|t| t.timer_id == timer_id && t.from_actor == from)
        .with_context(|| {
            format!(
                "[{}] replay TimerFired referenced unknown pending timer {}",
                cfg.node_id, timer_id
            )
        })?;
    let timer = pending_timers.swap_remove(timer_idx);

    let emit_ev = dispatch_outgoing(
        cfg,
        sys,
        service_to_actor,
        timer.from_actor,
        timer.target,
        timer.payload,
        msg_counter,
        cfg.mode,
    )?;

    let actual = replay.next()?.with_context(|| {
        format!(
            "[{}] replay trace ended after TimerFired {} while expecting emitted event {:?}",
            cfg.node_id, timer_id, emit_ev
        )
    })?;
    if actual.kind != emit_ev {
        anyhow::bail!(
            "[{}] replay timer emission mismatch for timer {}: expected {:?}, got {:?}",
            cfg.node_id,
            timer_id,
            emit_ev,
            actual.kind
        );
    }

    Ok(())
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
            EventKind::Send { .. }
            | EventKind::NetSend { .. }
            | EventKind::Log { .. }
            | EventKind::EffectObserved { .. } => {
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
) -> Result<Vec<EventKind>> {
    let entry_actor = service_to_actor
        .get(entry_service)
        .copied()
        .with_context(|| format!("entry service `{entry_service}` not found"))?;

    let count = if cfg.bootstrap_hello {
        cfg.bootstrap_burst
    } else {
        1
    };
    let mut out = Vec::new();

    for idx in 0..count {
        let msg_id = next_deterministic_msg_id(cfg.node_id, msg_counter);
        let msg = RuntimeMessage {
            msg_type: "start".to_string(),
            from_node: cfg.node_id.to_string(),
            from_service: "System".to_string(),
            text: format!("bootstrap #{}", idx + 1),
            provenance: Some(Provenance {
                origin_node: cfg.node_id.to_string(),
                origin_service: "System".to_string(),
                origin_msg_id: msg_id.to_string(),
                parent_node: cfg.node_id.to_string(),
                parent_msg_id: msg_id.to_string(),
                hops: 0,
            }),
        };
        let payload = encode_msg(&msg);
        sys.actors
            .get_mut(&entry_actor)
            .context("entry actor id missing from actor system")?
            .inbox
            .push_back((msg_id, payload.clone()));

        let ev = EventKind::Send {
            from: system_actor_id(),
            to: entry_actor,
            msg_id,
            payload,
        };
        out.push(ev.clone());

        if writer.is_some() {
            record_event(writer, seq, seed, ev)?;
        }
    }

    Ok(out)
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
    let mut timer_counter: u64 = 1;
    let mut pending_timers: Vec<PendingTimer> = Vec::new();
    let mut writer = match cfg.mode {
        Mode::Record => Some(TraceWriter::create(&cfg.trace_path)?),
        Mode::Replay => None,
    };
    let mut replay = match cfg.mode {
        Mode::Replay => Some(ReplayCursor::open(&cfg.trace_path)?),
        Mode::Record => None,
    };
    let mut injector = FaultInjector::new(cfg.fault.clone());

    let (net_tx, net_rx) = mpsc::channel::<WireEnvelope>();
    let _listener_handle = match (cfg.mode, cfg.listen.clone()) {
        (Mode::Record, Some(addr)) => Some(net::spawn_listener(addr, net_tx)?),
        _ => None,
    };

    let mut startup_expected = vec![EventKind::Spawn {
        node: cfg.node_id,
        actor: system_actor_id(),
        service: "System".to_string(),
    }];
    for service in &program.services {
        let actor = service_to_actor
            .get(service)
            .copied()
            .with_context(|| format!("missing actor mapping for service `{service}`"))?;
        startup_expected.push(EventKind::Spawn {
            node: cfg.node_id,
            actor,
            service: service.clone(),
        });
    }

    if let Mode::Record = cfg.mode {
        for ev in &startup_expected {
            record_event(&mut writer, &mut seq, seed, ev.clone())?;
        }
    }

    let bootstrap_events = enqueue_bootstrap(
        &mut sys,
        &service_to_actor,
        &entry_service,
        &cfg,
        &mut msg_counter,
        &mut writer,
        &mut seq,
        seed,
    )?;
    startup_expected.extend(bootstrap_events);

    if let Mode::Replay = cfg.mode {
        let replay = replay
            .as_mut()
            .context("internal error: replay mode without replay cursor")?;
        verify_replay_emits(replay, cfg.node_id, &startup_expected)?;
    }

    if matches!(cfg.mode, Mode::Record) && cfg.startup_wait_ms > 0 {
        std::thread::sleep(Duration::from_millis(cfg.startup_wait_ms));
    }

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
        if let Mode::Replay = cfg.mode {
            let replay = replay
                .as_mut()
                .context("internal error: replay mode without replay cursor")?;
            drain_replay_inbound(replay, &mut sys, cfg.node_id)?;
        }

        if let Mode::Record = cfg.mode {
            let mut remaining_timers = Vec::with_capacity(pending_timers.len());
            let mut due_timers = Vec::new();
            for timer in pending_timers.drain(..) {
                if timer.due_step <= step {
                    due_timers.push(timer);
                } else {
                    remaining_timers.push(timer);
                }
            }
            pending_timers = remaining_timers;
            due_timers.sort_by_key(|t| t.timer_id);

            for timer in due_timers {
                let timer_ev = EventKind::TimerFired {
                    node: cfg.node_id,
                    from: timer.from_actor,
                    timer_id: timer.timer_id,
                };
                record_event(&mut writer, &mut seq, seed, timer_ev)?;

                let emit_ev = dispatch_outgoing(
                    &cfg,
                    &mut sys,
                    &service_to_actor,
                    timer.from_actor,
                    timer.target,
                    timer.payload,
                    &mut msg_counter,
                    cfg.mode,
                )?;

                record_event(&mut writer, &mut seq, seed, emit_ev)?;
            }
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
                next_replay_delivery(
                    replay,
                    &mut sys,
                    &cfg,
                    &service_to_actor,
                    &mut msg_counter,
                    &mut pending_timers,
                )?
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
        let effects = {
            let actor = sys
                .actors
                .get_mut(&actor_id)
                .with_context(|| format!("unknown actor id {}", actor_id))?;
            execute_actions(
                &program,
                &actor_service,
                msg_id,
                &incoming,
                &cfg.peers,
                &mut actor.state,
                &mut ctx,
            )
            .with_context(|| format!("execute service `{}`", actor_service))?
        };

        let mut replay_expected: Vec<EventKind> = Vec::new();
        let effects_ev = EventKind::EffectObserved {
            node: cfg.node_id,
            actor: actor_id,
            service: actor_service.clone(),
            msg_type: incoming.msg_type.clone(),
            msg_id,
            declared: effect_vec(&effects.declared),
            observed: effect_vec(&effects.observed),
        };
        match cfg.mode {
            Mode::Record => record_event(&mut writer, &mut seq, seed, effects_ev)?,
            Mode::Replay => replay_expected.push(effects_ev),
        }

        for log in ctx.logs {
            println!("[{}] {}: {}", cfg.node_id, log.service, log.text);
            let ev = EventKind::Log {
                node: cfg.node_id,
                from: actor_id,
                service: log.service,
                text: log.text,
            };
            match cfg.mode {
                Mode::Record => record_event(&mut writer, &mut seq, seed, ev)?,
                Mode::Replay => replay_expected.push(ev),
            }
        }

        for out in ctx.outbox {
            if out.delay_steps > 0 {
                let timer_id = next_deterministic_timer_id(cfg.node_id, &mut timer_counter);
                pending_timers.push(PendingTimer {
                    due_step: step.saturating_add(out.delay_steps),
                    timer_id,
                    from_actor: actor_id,
                    target: out.target,
                    payload: out.payload,
                });
                continue;
            }

            let ev = dispatch_outgoing(
                &cfg,
                &mut sys,
                &service_to_actor,
                actor_id,
                out.target,
                out.payload,
                &mut msg_counter,
                cfg.mode,
            )?;

            match cfg.mode {
                Mode::Record => record_event(&mut writer, &mut seq, seed, ev)?,
                Mode::Replay => replay_expected.push(ev),
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
        if let Some(next) = replay.next()? {
            anyhow::bail!(
                "[{}] replay stopped early after {} steps (next trace event: {:?})",
                cfg.node_id,
                cfg.steps,
                next.kind
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
    use std::collections::VecDeque;
    use std::path::Path;

    fn test_message(msg_type: &str, text: &str) -> RuntimeMessage {
        RuntimeMessage {
            msg_type: msg_type.to_string(),
            from_node: "00000000-0000-0000-0000-000000000000".to_string(),
            from_service: "System".to_string(),
            text: text.to_string(),
            provenance: None,
        }
    }

    fn test_program(actions: Vec<ActionDecl>) -> Program {
        let mut handlers = HashMap::new();
        let declared: Vec<HandlerEffect> = infer_effects(&actions).into_iter().collect();
        handlers.insert(
            ("Gateway".to_string(), "start".to_string()),
            HandlerPlan {
                actions,
                declared_effects: declared,
            },
        );
        Program {
            services: vec!["Gateway".to_string()],
            service_initial_state: HashMap::new(),
            handlers,
        }
    }

    fn write_trace(path: &Path, events: &[EventKind]) {
        let mut writer = TraceWriter::create(path).expect("create temp trace");
        for (idx, kind) in events.iter().cloned().enumerate() {
            writer
                .write(&TraceEvent {
                    seq: idx as u64,
                    seed: 12345,
                    kind,
                })
                .expect("write trace event");
        }
        writer.flush().expect("flush trace");
    }

    fn replay_test_config(node_id: Uuid) -> Config {
        Config {
            mode: Mode::Replay,
            trace_path: String::new(),
            program_path: "programs/distributed_services.uco".to_string(),
            node_id,
            listen: None,
            peers: HashMap::new(),
            bootstrap_hello: false,
            bootstrap_burst: 1,
            steps: 10,
            idle_sleep_ms: 0,
            startup_wait_ms: 0,
            fault: FaultConfig::default(),
        }
    }

    #[test]
    fn parses_fault_phase_spec_with_open_end() {
        let phase = parse_fault_phase_spec("10:*:3:2:4").expect("phase should parse");
        assert_eq!(phase.start_step, 10);
        assert_eq!(phase.end_step, None);
        assert_eq!(
            phase.policy,
            FaultPolicy {
                drop_every: Some(3),
                delay_steps: 2,
                reorder_window: 4,
            }
        );
    }

    #[test]
    fn fault_config_policy_prefers_active_phase() {
        let mut cfg = FaultConfig {
            drop_every: None,
            delay_steps: 0,
            reorder_window: 1,
            phases: vec![
                FaultPhase {
                    start_step: 5,
                    end_step: Some(9),
                    policy: FaultPolicy {
                        drop_every: Some(2),
                        delay_steps: 1,
                        reorder_window: 2,
                    },
                },
                FaultPhase {
                    start_step: 10,
                    end_step: None,
                    policy: FaultPolicy {
                        drop_every: Some(4),
                        delay_steps: 3,
                        reorder_window: 3,
                    },
                },
            ],
        };
        cfg.sort_and_validate_phases()
            .expect("non-overlapping phases should validate");

        assert_eq!(cfg.policy_for_step(0).drop_every, None);
        assert_eq!(cfg.policy_for_step(6).drop_every, Some(2));
        assert_eq!(cfg.policy_for_step(10).drop_every, Some(4));
        assert_eq!(cfg.policy_for_step(99).delay_steps, 3);
    }

    #[test]
    fn fault_config_rejects_overlapping_phases() {
        let mut cfg = FaultConfig {
            drop_every: None,
            delay_steps: 0,
            reorder_window: 1,
            phases: vec![
                FaultPhase {
                    start_step: 0,
                    end_step: Some(5),
                    policy: FaultPolicy {
                        drop_every: Some(2),
                        delay_steps: 1,
                        reorder_window: 2,
                    },
                },
                FaultPhase {
                    start_step: 5,
                    end_step: Some(10),
                    policy: FaultPolicy {
                        drop_every: Some(3),
                        delay_steps: 1,
                        reorder_window: 2,
                    },
                },
            ],
        };

        let err = cfg
            .sort_and_validate_phases()
            .expect_err("overlap should fail validation");
        let err_text = format!("{err:#}");
        assert!(err_text.contains("overlap"), "unexpected error: {err_text}");
    }

    #[test]
    fn replay_delivery_handles_timerfired_before_deliver() {
        let node = Uuid::parse_str("00000000-0000-0000-0000-000000000501").expect("valid node");
        let gateway = Uuid::parse_str("965e1b02-03eb-56fe-b20e-3a4852a7eb2c").expect("valid actor");
        let timer_id =
            Uuid::parse_str("00000001-0000-0000-0000-000000000501").expect("valid timer");

        let payload = encode_msg(&RuntimeMessage {
            msg_type: "hello".to_string(),
            from_node: node.to_string(),
            from_service: "Gateway".to_string(),
            text: "timer hello".to_string(),
            provenance: None,
        });

        let mut counter_for_expected = 1;
        let expected_msg_id = next_deterministic_msg_id(node, &mut counter_for_expected);

        let tmp =
            std::env::temp_dir().join(format!("uco-replay-timer-{}.trace.jsonl", Uuid::new_v4()));
        write_trace(
            &tmp,
            &[
                EventKind::TimerFired {
                    node,
                    from: gateway,
                    timer_id,
                },
                EventKind::Send {
                    from: gateway,
                    to: gateway,
                    msg_id: expected_msg_id,
                    payload: payload.clone(),
                },
                EventKind::Deliver {
                    node,
                    to: gateway,
                    msg_id: expected_msg_id,
                },
            ],
        );

        let mut replay = ReplayCursor::open(tmp.to_str().expect("temp path should be utf8"))
            .expect("open replay cursor");
        let mut sys = ActorSystem::new();
        sys.actors.insert(
            gateway,
            Actor {
                id: gateway,
                service: "Gateway".to_string(),
                state: HashMap::new(),
                inbox: VecDeque::new(),
            },
        );
        let service_to_actor = HashMap::from([(String::from("Gateway"), gateway)]);
        let mut pending_timers = vec![PendingTimer {
            due_step: 0,
            timer_id,
            from_actor: gateway,
            target: Target::LocalService("Gateway".to_string()),
            payload,
        }];
        let mut msg_counter = 1;
        let cfg = replay_test_config(node);

        let next = next_replay_delivery(
            &mut replay,
            &mut sys,
            &cfg,
            &service_to_actor,
            &mut msg_counter,
            &mut pending_timers,
        )
        .expect("replay should progress")
        .expect("expected delivery");

        assert_eq!(next.node, node);
        assert_eq!(next.to, gateway);
        assert_eq!(next.msg_id, expected_msg_id);
        assert!(pending_timers.is_empty());
        assert_eq!(msg_counter, 2);

        let actor = sys.actors.get(&gateway).expect("gateway exists");
        let (front_msg_id, _) = actor.inbox.front().expect("timer emission enqueued");
        assert_eq!(*front_msg_id, expected_msg_id);

        let none = next_replay_delivery(
            &mut replay,
            &mut sys,
            &cfg,
            &service_to_actor,
            &mut msg_counter,
            &mut pending_timers,
        )
        .expect("second replay call should succeed");
        assert!(none.is_none());

        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn drain_replay_inbound_stops_before_non_inbound_event() {
        let node = Uuid::parse_str("00000000-0000-0000-0000-000000000601").expect("valid node");
        let from_node =
            Uuid::parse_str("00000000-0000-0000-0000-000000000602").expect("valid node");
        let gateway = Uuid::parse_str("965e1b02-03eb-56fe-b20e-3a4852a7eb2c").expect("valid actor");
        let msg_id = Uuid::parse_str("00000000-0000-0000-0000-000000000777").expect("valid msg");
        let timer_id =
            Uuid::parse_str("00000001-0000-0000-0000-000000000601").expect("valid timer");
        let payload = encode_msg(&test_message("hello", "net"));

        let tmp =
            std::env::temp_dir().join(format!("uco-replay-inbound-{}.trace.jsonl", Uuid::new_v4()));
        write_trace(
            &tmp,
            &[
                EventKind::NetRecv {
                    node,
                    from_node,
                    to: gateway,
                    msg_id,
                    payload: payload.clone(),
                },
                EventKind::TimerFired {
                    node,
                    from: gateway,
                    timer_id,
                },
            ],
        );

        let mut replay = ReplayCursor::open(tmp.to_str().expect("temp path should be utf8"))
            .expect("open replay cursor");
        let mut sys = ActorSystem::new();
        sys.actors.insert(
            gateway,
            Actor {
                id: gateway,
                service: "Gateway".to_string(),
                state: HashMap::new(),
                inbox: VecDeque::new(),
            },
        );

        drain_replay_inbound(&mut replay, &mut sys, node).expect("drain inbound should succeed");

        let actor = sys.actors.get(&gateway).expect("gateway exists");
        let (front_msg_id, _) = actor.inbox.front().expect("netrecv should be enqueued");
        assert_eq!(*front_msg_id, msg_id);

        let next = replay
            .next()
            .expect("read next replay event")
            .expect("timer event expected");
        assert_eq!(
            next.kind,
            EventKind::TimerFired {
                node,
                from: gateway,
                timer_id
            }
        );

        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn replay_delivery_handles_multiple_timerfirings_before_deliveries() {
        let node = Uuid::parse_str("00000000-0000-0000-0000-000000000611").expect("valid node");
        let gateway = Uuid::parse_str("965e1b02-03eb-56fe-b20e-3a4852a7eb2c").expect("valid actor");
        let timer1 = Uuid::parse_str("00000001-0000-0000-0000-000000000611").expect("valid timer");
        let timer2 = Uuid::parse_str("00000001-0000-0000-0000-000000000612").expect("valid timer");
        let payload1 = encode_msg(&test_message("hello", "timer-1"));
        let payload2 = encode_msg(&test_message("hello", "timer-2"));

        let mut counter_for_expected = 1;
        let msg1 = next_deterministic_msg_id(node, &mut counter_for_expected);
        let msg2 = next_deterministic_msg_id(node, &mut counter_for_expected);

        let tmp = std::env::temp_dir().join(format!(
            "uco-replay-multi-timer-{}.trace.jsonl",
            Uuid::new_v4()
        ));
        write_trace(
            &tmp,
            &[
                EventKind::TimerFired {
                    node,
                    from: gateway,
                    timer_id: timer1,
                },
                EventKind::Send {
                    from: gateway,
                    to: gateway,
                    msg_id: msg1,
                    payload: payload1.clone(),
                },
                EventKind::TimerFired {
                    node,
                    from: gateway,
                    timer_id: timer2,
                },
                EventKind::Send {
                    from: gateway,
                    to: gateway,
                    msg_id: msg2,
                    payload: payload2.clone(),
                },
                EventKind::Deliver {
                    node,
                    to: gateway,
                    msg_id: msg1,
                },
                EventKind::Deliver {
                    node,
                    to: gateway,
                    msg_id: msg2,
                },
            ],
        );

        let mut replay = ReplayCursor::open(tmp.to_str().expect("temp path should be utf8"))
            .expect("open replay cursor");
        let mut sys = ActorSystem::new();
        sys.actors.insert(
            gateway,
            Actor {
                id: gateway,
                service: "Gateway".to_string(),
                state: HashMap::new(),
                inbox: VecDeque::new(),
            },
        );
        let service_to_actor = HashMap::from([(String::from("Gateway"), gateway)]);
        let mut pending_timers = vec![
            PendingTimer {
                due_step: 0,
                timer_id: timer1,
                from_actor: gateway,
                target: Target::LocalService("Gateway".to_string()),
                payload: payload1,
            },
            PendingTimer {
                due_step: 0,
                timer_id: timer2,
                from_actor: gateway,
                target: Target::LocalService("Gateway".to_string()),
                payload: payload2,
            },
        ];
        let mut msg_counter = 1;
        let cfg = replay_test_config(node);

        let first = next_replay_delivery(
            &mut replay,
            &mut sys,
            &cfg,
            &service_to_actor,
            &mut msg_counter,
            &mut pending_timers,
        )
        .expect("first replay delivery")
        .expect("first delivery present");
        assert_eq!(first.msg_id, msg1);

        let second = next_replay_delivery(
            &mut replay,
            &mut sys,
            &cfg,
            &service_to_actor,
            &mut msg_counter,
            &mut pending_timers,
        )
        .expect("second replay delivery")
        .expect("second delivery present");
        assert_eq!(second.msg_id, msg2);

        let actor = sys.actors.get(&gateway).expect("gateway exists");
        assert_eq!(actor.inbox.len(), 2);
        let ids: Vec<Uuid> = actor.inbox.iter().map(|(id, _)| *id).collect();
        assert_eq!(ids, vec![msg1, msg2]);
        assert!(pending_timers.is_empty());
        assert_eq!(msg_counter, 3);

        let none = next_replay_delivery(
            &mut replay,
            &mut sys,
            &cfg,
            &service_to_actor,
            &mut msg_counter,
            &mut pending_timers,
        )
        .expect("replay should complete");
        assert!(none.is_none());

        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn replay_delivery_rejects_unknown_timer_id() {
        let node = Uuid::parse_str("00000000-0000-0000-0000-000000000621").expect("valid node");
        let gateway = Uuid::parse_str("965e1b02-03eb-56fe-b20e-3a4852a7eb2c").expect("valid actor");
        let missing_timer =
            Uuid::parse_str("00000001-0000-0000-0000-000000000621").expect("valid timer");
        let tmp = std::env::temp_dir().join(format!(
            "uco-replay-missing-timer-{}.trace.jsonl",
            Uuid::new_v4()
        ));
        write_trace(
            &tmp,
            &[EventKind::TimerFired {
                node,
                from: gateway,
                timer_id: missing_timer,
            }],
        );

        let mut replay = ReplayCursor::open(tmp.to_str().expect("temp path should be utf8"))
            .expect("open replay cursor");
        let mut sys = ActorSystem::new();
        sys.actors.insert(
            gateway,
            Actor {
                id: gateway,
                service: "Gateway".to_string(),
                state: HashMap::new(),
                inbox: VecDeque::new(),
            },
        );
        let service_to_actor = HashMap::from([(String::from("Gateway"), gateway)]);
        let mut pending_timers = Vec::new();
        let mut msg_counter = 1;
        let cfg = replay_test_config(node);

        let err = next_replay_delivery(
            &mut replay,
            &mut sys,
            &cfg,
            &service_to_actor,
            &mut msg_counter,
            &mut pending_timers,
        )
        .expect_err("unknown timer should fail");
        let err_text = format!("{err:#}");
        assert!(
            err_text.contains("unknown pending timer"),
            "unexpected error: {err_text}"
        );

        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn replay_delivery_handles_mixed_netrecv_and_multi_timer_delayed_ordering() {
        let node = Uuid::parse_str("00000000-0000-0000-0000-000000000631").expect("valid node");
        let from1 = Uuid::parse_str("00000000-0000-0000-0000-000000000701").expect("valid node");
        let from2 = Uuid::parse_str("00000000-0000-0000-0000-000000000702").expect("valid node");
        let gateway = Uuid::parse_str("965e1b02-03eb-56fe-b20e-3a4852a7eb2c").expect("valid actor");
        let timer1 = Uuid::parse_str("00000001-0000-0000-0000-000000000631").expect("valid timer");
        let timer2 = Uuid::parse_str("00000001-0000-0000-0000-000000000632").expect("valid timer");
        let net_msg1 = Uuid::parse_str("00000000-0000-0000-0000-000000000711").expect("valid msg");
        let net_msg2 = Uuid::parse_str("00000000-0000-0000-0000-000000000712").expect("valid msg");
        let net_payload1 = encode_msg(&test_message("hello", "net-1"));
        let net_payload2 = encode_msg(&test_message("hello", "net-2"));
        let timer_payload1 = encode_msg(&test_message("hello", "timer-1"));
        let timer_payload2 = encode_msg(&test_message("hello", "timer-2"));

        let mut counter_for_expected = 1;
        let timer_msg1 = next_deterministic_msg_id(node, &mut counter_for_expected);
        let timer_msg2 = next_deterministic_msg_id(node, &mut counter_for_expected);

        let tmp = std::env::temp_dir().join(format!(
            "uco-replay-interleave-{}.trace.jsonl",
            Uuid::new_v4()
        ));
        write_trace(
            &tmp,
            &[
                EventKind::NetRecv {
                    node,
                    from_node: from1,
                    to: gateway,
                    msg_id: net_msg1,
                    payload: net_payload1.clone(),
                },
                EventKind::TimerFired {
                    node,
                    from: gateway,
                    timer_id: timer1,
                },
                EventKind::Send {
                    from: gateway,
                    to: gateway,
                    msg_id: timer_msg1,
                    payload: timer_payload1.clone(),
                },
                EventKind::NetRecv {
                    node,
                    from_node: from2,
                    to: gateway,
                    msg_id: net_msg2,
                    payload: net_payload2.clone(),
                },
                EventKind::TimerFired {
                    node,
                    from: gateway,
                    timer_id: timer2,
                },
                EventKind::Send {
                    from: gateway,
                    to: gateway,
                    msg_id: timer_msg2,
                    payload: timer_payload2.clone(),
                },
                EventKind::Deliver {
                    node,
                    to: gateway,
                    msg_id: timer_msg1,
                },
                EventKind::Deliver {
                    node,
                    to: gateway,
                    msg_id: net_msg1,
                },
                EventKind::Deliver {
                    node,
                    to: gateway,
                    msg_id: timer_msg2,
                },
                EventKind::Deliver {
                    node,
                    to: gateway,
                    msg_id: net_msg2,
                },
            ],
        );

        let mut replay = ReplayCursor::open(tmp.to_str().expect("temp path should be utf8"))
            .expect("open replay cursor");
        let mut sys = ActorSystem::new();
        sys.actors.insert(
            gateway,
            Actor {
                id: gateway,
                service: "Gateway".to_string(),
                state: HashMap::new(),
                inbox: VecDeque::new(),
            },
        );
        let service_to_actor = HashMap::from([(String::from("Gateway"), gateway)]);
        let mut pending_timers = vec![
            PendingTimer {
                due_step: 0,
                timer_id: timer1,
                from_actor: gateway,
                target: Target::LocalService("Gateway".to_string()),
                payload: timer_payload1,
            },
            PendingTimer {
                due_step: 0,
                timer_id: timer2,
                from_actor: gateway,
                target: Target::LocalService("Gateway".to_string()),
                payload: timer_payload2,
            },
        ];
        let mut msg_counter = 1;
        let cfg = replay_test_config(node);

        let first = next_replay_delivery(
            &mut replay,
            &mut sys,
            &cfg,
            &service_to_actor,
            &mut msg_counter,
            &mut pending_timers,
        )
        .expect("first replay delivery")
        .expect("first delivery present");
        let second = next_replay_delivery(
            &mut replay,
            &mut sys,
            &cfg,
            &service_to_actor,
            &mut msg_counter,
            &mut pending_timers,
        )
        .expect("second replay delivery")
        .expect("second delivery present");
        let third = next_replay_delivery(
            &mut replay,
            &mut sys,
            &cfg,
            &service_to_actor,
            &mut msg_counter,
            &mut pending_timers,
        )
        .expect("third replay delivery")
        .expect("third delivery present");
        let fourth = next_replay_delivery(
            &mut replay,
            &mut sys,
            &cfg,
            &service_to_actor,
            &mut msg_counter,
            &mut pending_timers,
        )
        .expect("fourth replay delivery")
        .expect("fourth delivery present");

        assert_eq!(first.msg_id, timer_msg1);
        assert_eq!(second.msg_id, net_msg1);
        assert_eq!(third.msg_id, timer_msg2);
        assert_eq!(fourth.msg_id, net_msg2);

        let actor = sys.actors.get(&gateway).expect("gateway exists");
        let ids: Vec<Uuid> = actor.inbox.iter().map(|(id, _)| *id).collect();
        assert_eq!(ids, vec![net_msg1, timer_msg1, net_msg2, timer_msg2]);
        assert!(pending_timers.is_empty());
        assert_eq!(msg_counter, 3);

        let none = next_replay_delivery(
            &mut replay,
            &mut sys,
            &cfg,
            &service_to_actor,
            &mut msg_counter,
            &mut pending_timers,
        )
        .expect("replay should complete");
        assert!(none.is_none());

        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn replay_delivery_rejects_timerfired_not_followed_by_send() {
        let node = Uuid::parse_str("00000000-0000-0000-0000-000000000641").expect("valid node");
        let from = Uuid::parse_str("00000000-0000-0000-0000-000000000741").expect("valid node");
        let gateway = Uuid::parse_str("965e1b02-03eb-56fe-b20e-3a4852a7eb2c").expect("valid actor");
        let timer = Uuid::parse_str("00000001-0000-0000-0000-000000000641").expect("valid timer");
        let net_msg = Uuid::parse_str("00000000-0000-0000-0000-000000000742").expect("valid msg");
        let timer_payload = encode_msg(&test_message("hello", "timer"));
        let net_payload = encode_msg(&test_message("hello", "net"));

        let tmp = std::env::temp_dir().join(format!(
            "uco-replay-timer-adj-{}.trace.jsonl",
            Uuid::new_v4()
        ));
        write_trace(
            &tmp,
            &[
                EventKind::TimerFired {
                    node,
                    from: gateway,
                    timer_id: timer,
                },
                EventKind::NetRecv {
                    node,
                    from_node: from,
                    to: gateway,
                    msg_id: net_msg,
                    payload: net_payload,
                },
            ],
        );

        let mut replay = ReplayCursor::open(tmp.to_str().expect("temp path should be utf8"))
            .expect("open replay cursor");
        let mut sys = ActorSystem::new();
        sys.actors.insert(
            gateway,
            Actor {
                id: gateway,
                service: "Gateway".to_string(),
                state: HashMap::new(),
                inbox: VecDeque::new(),
            },
        );
        let service_to_actor = HashMap::from([(String::from("Gateway"), gateway)]);
        let mut pending_timers = vec![PendingTimer {
            due_step: 0,
            timer_id: timer,
            from_actor: gateway,
            target: Target::LocalService("Gateway".to_string()),
            payload: timer_payload,
        }];
        let mut msg_counter = 1;
        let cfg = replay_test_config(node);

        let err = next_replay_delivery(
            &mut replay,
            &mut sys,
            &cfg,
            &service_to_actor,
            &mut msg_counter,
            &mut pending_timers,
        )
        .expect_err("TimerFired without immediate Send should fail");
        let err_text = format!("{err:#}");
        assert!(
            err_text.contains("timer emission mismatch"),
            "unexpected error: {err_text}"
        );

        let _ = std::fs::remove_file(&tmp);
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
            Uuid::nil(),
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
            Uuid::nil(),
            &test_message("start", "boot"),
            &HashMap::new(),
            &mut state,
            &mut ctx,
        )
        .expect("execute_actions should succeed");

        assert!(ctx.outbox.is_empty());
        assert_eq!(state.get("count"), Some(&1));
    }

    #[test]
    fn schedules_timer_local_message() {
        let program = test_program(vec![ActionDecl::TimerLocal {
            steps: 2,
            service: "Gateway".to_string(),
            message: "tick".to_string(),
            template: "t=$text".to_string(),
        }]);

        let mut state = HashMap::new();
        let mut ctx = ActorContext::new(Uuid::nil());
        execute_actions(
            &program,
            "Gateway",
            Uuid::nil(),
            &test_message("start", "boot"),
            &HashMap::new(),
            &mut state,
            &mut ctx,
        )
        .expect("execute_actions should succeed");

        assert_eq!(ctx.outbox.len(), 1);
        assert_eq!(ctx.outbox[0].delay_steps, 2);
        match &ctx.outbox[0].target {
            Target::LocalService(svc) => assert_eq!(svc, "Gateway"),
            other => panic!("unexpected target: {other:?}"),
        }
        let payload = decode_msg(ctx.outbox[0].payload.clone()).expect("payload should decode");
        assert_eq!(payload.msg_type, "tick");
        assert_eq!(payload.text, "t=boot");
    }

    #[test]
    fn schedules_timer_remote_message() {
        let program = test_program(vec![ActionDecl::TimerRemote {
            steps: 3,
            target: RemoteTarget::Peers,
            service: "Echo".to_string(),
            message: "hello".to_string(),
            template: "delayed-$text".to_string(),
        }]);

        let mut state = HashMap::new();
        let mut ctx = ActorContext::new(Uuid::nil());
        execute_actions(
            &program,
            "Gateway",
            Uuid::nil(),
            &test_message("start", "boot"),
            &HashMap::new(),
            &mut state,
            &mut ctx,
        )
        .expect("execute_actions should succeed");

        assert_eq!(ctx.outbox.len(), 1);
        assert_eq!(ctx.outbox[0].delay_steps, 3);
        match &ctx.outbox[0].target {
            Target::LocalService(svc) => assert_eq!(svc, "Echo"),
            other => panic!("unexpected target: {other:?}"),
        }
        let payload = decode_msg(ctx.outbox[0].payload.clone()).expect("payload should decode");
        assert_eq!(payload.msg_type, "hello");
        assert_eq!(payload.text, "delayed-boot");
    }

    #[test]
    fn propagates_provenance_across_outbound_messages() {
        let program = test_program(vec![ActionDecl::SendLocal {
            service: "Gateway".to_string(),
            message: "echo".to_string(),
            template: "hop=$prov.hops".to_string(),
        }]);
        let incoming_id =
            Uuid::parse_str("00000000-0000-0000-0000-000000000123").expect("valid uuid");
        let mut state = HashMap::new();
        let mut ctx = ActorContext::new(Uuid::nil());
        let incoming = RuntimeMessage {
            msg_type: "start".to_string(),
            from_node: "00000000-0000-0000-0000-000000000001".to_string(),
            from_service: "System".to_string(),
            text: "boot".to_string(),
            provenance: Some(Provenance {
                origin_node: "00000000-0000-0000-0000-000000000001".to_string(),
                origin_service: "System".to_string(),
                origin_msg_id: "00000000-0000-0000-0000-000000000050".to_string(),
                parent_node: "00000000-0000-0000-0000-000000000001".to_string(),
                parent_msg_id: "00000000-0000-0000-0000-000000000099".to_string(),
                hops: 4,
            }),
        };

        execute_actions(
            &program,
            "Gateway",
            incoming_id,
            &incoming,
            &HashMap::new(),
            &mut state,
            &mut ctx,
        )
        .expect("execute_actions should succeed");

        let payload = decode_msg(ctx.outbox[0].payload.clone()).expect("payload should decode");
        let prov = payload
            .provenance
            .expect("outbound provenance should exist");
        assert_eq!(prov.origin_msg_id, "00000000-0000-0000-0000-000000000050");
        assert_eq!(prov.parent_msg_id, incoming_id.to_string());
        assert_eq!(prov.hops, 5);
    }

    #[test]
    fn renders_provenance_template_tokens() {
        let state = HashMap::new();
        let incoming = RuntimeMessage {
            msg_type: "start".to_string(),
            from_node: "00000000-0000-0000-0000-000000000001".to_string(),
            from_service: "System".to_string(),
            text: "boot".to_string(),
            provenance: Some(Provenance {
                origin_node: "00000000-0000-0000-0000-000000000010".to_string(),
                origin_service: "Gateway".to_string(),
                origin_msg_id: "00000000-0000-0000-0000-000000000011".to_string(),
                parent_node: "00000000-0000-0000-0000-000000000010".to_string(),
                parent_msg_id: "00000000-0000-0000-0000-000000000012".to_string(),
                hops: 2,
            }),
        };

        let rendered = render_template(
            "origin=$prov.origin_service/$prov.origin_msg parent=$prov.parent_node/$prov.parent_msg hops=$prov.hops",
            Uuid::nil(),
            "Gateway",
            &incoming,
            &state,
        );
        assert!(rendered.contains("origin=Gateway/00000000-0000-0000-0000-000000000011"));
        assert!(rendered.contains(
            "parent=00000000-0000-0000-0000-000000000010/00000000-0000-0000-0000-000000000012"
        ));
        assert!(rendered.contains("hops=2"));
    }

    #[test]
    fn load_program_rejects_missing_effects_declaration() {
        let path = std::env::temp_dir().join(format!("uco-missing-effects-{}.uco", Uuid::new_v4()));
        let src = r#"
service Gateway
  on start
    log "hello"
"#;
        std::fs::write(&path, src).expect("write temp program");

        let res = load_program(path.to_str().expect("temp path should be utf8"));
        let _ = std::fs::remove_file(&path);

        let err = res.expect_err("load_program should reject missing effects");
        let msg = format!("{err:#}");
        assert!(
            msg.contains("missing required effects declaration"),
            "unexpected error: {msg}"
        );
    }
}
