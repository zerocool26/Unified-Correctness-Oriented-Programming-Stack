#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Module {
    pub services: Vec<ServiceDecl>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceDecl {
    pub name: String,
    pub states: Vec<StateDecl>,
    pub handlers: Vec<HandlerDecl>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateDecl {
    pub name: String,
    pub initial: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HandlerDecl {
    pub on: String,
    pub actions: Vec<ActionDecl>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ActionDecl {
    Log {
        template: String,
    },
    SetState {
        key: String,
        value: i64,
    },
    IncState {
        key: String,
        by: i64,
    },
    SendLocal {
        service: String,
        message: String,
        template: String,
    },
    SendRemote {
        target: RemoteTarget,
        service: String,
        message: String,
        template: String,
    },
    IfStateEq {
        key: String,
        value: i64,
        then_action: Box<ActionDecl>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteTarget {
    Peers,
    Sender,
    Node(String),
}
