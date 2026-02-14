use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub type NodeId = Uuid;
pub type ActorId = Uuid;
pub type MsgId = Uuid;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum FaultAction {
    Drop,
    Delay { steps: u64 },
    Reorder { window: u64 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum EffectKind {
    Log,
    StateRead,
    StateWrite,
    SendLocal,
    SendRemote,
    TimerLocal,
    TimerRemote,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum EventKind {
    Spawn {
        node: NodeId,
        actor: ActorId,
        service: String,
    },
    Send {
        from: ActorId,
        to: ActorId,
        msg_id: MsgId,
        payload: serde_json::Value,
    },
    Deliver {
        node: NodeId,
        to: ActorId,
        msg_id: MsgId,
    },
    TimerFired {
        node: NodeId,
        from: ActorId,
        timer_id: Uuid,
    },
    NetRecv {
        node: NodeId,
        from_node: NodeId,
        to: ActorId,
        msg_id: MsgId,
        payload: serde_json::Value,
    },
    NetSend {
        node: NodeId,
        to_node: NodeId,
        from: ActorId,
        msg_id: MsgId,
        payload: serde_json::Value,
    },
    Log {
        node: NodeId,
        from: ActorId,
        service: String,
        text: String,
    },
    EffectObserved {
        node: NodeId,
        actor: ActorId,
        service: String,
        msg_type: String,
        msg_id: MsgId,
        declared: Vec<EffectKind>,
        observed: Vec<EffectKind>,
    },
    FaultInjected {
        node: NodeId,
        from_node: NodeId,
        to: ActorId,
        msg_id: MsgId,
        action: FaultAction,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TraceEvent {
    /// Monotonic event sequence number produced by the runtime.
    pub seq: u64,
    /// Fixed at process start for deterministic tie-breaking and replay identity.
    pub seed: u64,
    pub kind: EventKind,
}
