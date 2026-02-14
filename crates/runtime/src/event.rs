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
