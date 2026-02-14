use crate::event::{ActorId, MsgId, NodeId};
use serde_json::Value;
use std::collections::{HashMap, VecDeque};

#[derive(Debug, Clone)]
pub enum Target {
    LocalService(String),
    RemoteService { node: NodeId, service: String },
}

#[derive(Debug, Clone)]
pub struct Outgoing {
    pub target: Target,
    pub payload: Value,
    pub delay_steps: u64,
}

#[derive(Debug, Clone)]
pub struct LogEmission {
    pub service: String,
    pub text: String,
}

pub struct Actor {
    pub id: ActorId,
    pub service: String,
    pub state: HashMap<String, i64>,
    pub inbox: VecDeque<(MsgId, Value)>,
}

pub struct ActorContext {
    pub self_node: NodeId,
    pub outbox: Vec<Outgoing>,
    pub logs: Vec<LogEmission>,
}

impl ActorContext {
    pub fn new(self_node: NodeId) -> Self {
        Self {
            self_node,
            outbox: vec![],
            logs: vec![],
        }
    }

    pub fn log(&mut self, service: impl Into<String>, text: impl Into<String>) {
        self.logs.push(LogEmission {
            service: service.into(),
            text: text.into(),
        });
    }

    pub fn send_local_service(&mut self, service: impl Into<String>, payload: Value) {
        self.send_local_service_after(0, service, payload);
    }

    pub fn send_local_service_after(
        &mut self,
        delay_steps: u64,
        service: impl Into<String>,
        payload: Value,
    ) {
        self.outbox.push(Outgoing {
            target: Target::LocalService(service.into()),
            payload,
            delay_steps,
        });
    }

    pub fn send_remote_service(
        &mut self,
        node: NodeId,
        service: impl Into<String>,
        payload: Value,
    ) {
        self.send_remote_service_after(0, node, service, payload);
    }

    pub fn send_remote_service_after(
        &mut self,
        delay_steps: u64,
        node: NodeId,
        service: impl Into<String>,
        payload: Value,
    ) {
        self.outbox.push(Outgoing {
            target: Target::RemoteService {
                node,
                service: service.into(),
            },
            payload,
            delay_steps,
        });
    }
}

pub struct ActorSystem {
    pub actors: HashMap<ActorId, Actor>,
}

impl ActorSystem {
    pub fn new() -> Self {
        Self {
            actors: HashMap::new(),
        }
    }
}
