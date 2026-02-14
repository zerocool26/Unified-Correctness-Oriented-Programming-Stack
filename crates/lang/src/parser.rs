use crate::ast::{
    ActionDecl, HandlerDecl, HandlerEffect, Module, RemoteTarget, ServiceDecl, StateDecl,
};
use std::fmt::{Display, Formatter};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    pub line: usize,
    pub message: String,
}

impl Display for ParseError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "line {}: {}", self.line, self.message)
    }
}

impl std::error::Error for ParseError {}

pub fn parse_module(src: &str) -> Result<Module, ParseError> {
    let mut services: Vec<ServiceDecl> = Vec::new();
    let mut current_service: Option<ServiceDecl> = None;
    let mut current_handler: Option<HandlerDecl> = None;

    for (idx, raw_line) in src.lines().enumerate() {
        let line_no = idx + 1;
        let line = raw_line.trim();

        if line.is_empty() || line.starts_with("//") || line.starts_with('#') {
            continue;
        }

        if line.starts_with("service ") {
            flush_handler(&mut current_service, &mut current_handler, line_no)?;
            flush_service(&mut services, &mut current_service);

            let toks = tokenize(line, line_no)?;
            if toks.len() != 2 {
                return Err(ParseError {
                    line: line_no,
                    message: "service declaration must be: service <Name>".into(),
                });
            }

            current_service = Some(ServiceDecl {
                name: toks[1].clone(),
                states: Vec::new(),
                handlers: Vec::new(),
            });
            continue;
        }

        if line.starts_with("state ") {
            ensure_service(&current_service, line_no)?;
            if current_handler.is_some() {
                return Err(ParseError {
                    line: line_no,
                    message: "state declarations must appear before handlers in a service".into(),
                });
            }
            let state = parse_state_decl(line, line_no)?;
            current_service
                .as_mut()
                .expect("service existence checked")
                .states
                .push(state);
            continue;
        }

        if line.starts_with("on ") {
            ensure_service(&current_service, line_no)?;
            flush_handler(&mut current_service, &mut current_handler, line_no)?;

            let toks = tokenize(line, line_no)?;
            if toks.len() != 2 {
                return Err(ParseError {
                    line: line_no,
                    message: "handler declaration must be: on <MessageType>".into(),
                });
            }
            current_handler = Some(HandlerDecl {
                on: toks[1].clone(),
                effects: Vec::new(),
                actions: Vec::new(),
            });
            continue;
        }

        ensure_handler(&current_service, &current_handler, line_no)?;
        if line.starts_with("effects ") {
            let handler = current_handler.as_mut().expect("handler existence checked");
            if !handler.effects.is_empty() {
                return Err(ParseError {
                    line: line_no,
                    message: "duplicate effects declaration in handler".into(),
                });
            }
            if !handler.actions.is_empty() {
                return Err(ParseError {
                    line: line_no,
                    message: "effects declaration must appear before actions in a handler".into(),
                });
            }
            handler.effects = parse_effects_decl(line, line_no)?;
            continue;
        }
        let action = parse_action(line, line_no, 0)?;
        current_handler
            .as_mut()
            .expect("handler existence checked")
            .actions
            .push(action);
    }

    flush_handler(
        &mut current_service,
        &mut current_handler,
        src.lines().count() + 1,
    )?;
    flush_service(&mut services, &mut current_service);

    if services.is_empty() {
        return Err(ParseError {
            line: 1,
            message: "program must declare at least one service".into(),
        });
    }

    Ok(Module { services })
}

fn ensure_service(current_service: &Option<ServiceDecl>, line: usize) -> Result<(), ParseError> {
    if current_service.is_none() {
        return Err(ParseError {
            line,
            message: "found handler/action outside of any service".into(),
        });
    }
    Ok(())
}

fn ensure_handler(
    current_service: &Option<ServiceDecl>,
    current_handler: &Option<HandlerDecl>,
    line: usize,
) -> Result<(), ParseError> {
    ensure_service(current_service, line)?;
    if current_handler.is_none() {
        return Err(ParseError {
            line,
            message: "found action outside of any handler".into(),
        });
    }
    Ok(())
}

fn flush_handler(
    current_service: &mut Option<ServiceDecl>,
    current_handler: &mut Option<HandlerDecl>,
    line: usize,
) -> Result<(), ParseError> {
    if let Some(h) = current_handler.take() {
        if h.actions.is_empty() {
            return Err(ParseError {
                line,
                message: format!("handler `on {}` has no actions", h.on),
            });
        }
        if h.effects.is_empty() {
            return Err(ParseError {
                line,
                message: format!("handler `on {}` missing required effects declaration", h.on),
            });
        }
        current_service
            .as_mut()
            .expect("service exists when handler exists")
            .handlers
            .push(h);
    }
    Ok(())
}

fn flush_service(services: &mut Vec<ServiceDecl>, current_service: &mut Option<ServiceDecl>) {
    if let Some(s) = current_service.take() {
        services.push(s);
    }
}

fn parse_state_decl(line: &str, line_no: usize) -> Result<StateDecl, ParseError> {
    let toks = tokenize(line, line_no)?;
    if toks.len() != 4 || toks[2] != "=" {
        return Err(ParseError {
            line: line_no,
            message: "state declaration must be: state <name> = <int>".into(),
        });
    }

    let initial = toks[3].parse::<i64>().map_err(|_| ParseError {
        line: line_no,
        message: format!("invalid state initial value `{}`", toks[3]),
    })?;
    Ok(StateDecl {
        name: toks[1].clone(),
        initial,
    })
}

fn parse_effects_decl(line: &str, line_no: usize) -> Result<Vec<HandlerEffect>, ParseError> {
    let toks = tokenize(line, line_no)?;
    if toks.len() < 2 {
        return Err(ParseError {
            line: line_no,
            message: "effects declaration must be: effects <effect...>".into(),
        });
    }

    let mut out = Vec::new();
    for raw in &toks[1..] {
        for part in raw.split(',') {
            let name = part.trim();
            if name.is_empty() {
                continue;
            }
            let effect = match name {
                "log" => HandlerEffect::Log,
                "state_read" => HandlerEffect::StateRead,
                "state_write" => HandlerEffect::StateWrite,
                "send_local" => HandlerEffect::SendLocal,
                "send_remote" => HandlerEffect::SendRemote,
                "timer_local" => HandlerEffect::TimerLocal,
                "timer_remote" => HandlerEffect::TimerRemote,
                _ => {
                    return Err(ParseError {
                        line: line_no,
                        message: format!(
                            "unknown effect `{name}`; expected log, state_read, state_write, send_local, send_remote, timer_local, timer_remote"
                        ),
                    });
                }
            };
            if !out.contains(&effect) {
                out.push(effect);
            }
        }
    }

    if out.is_empty() {
        return Err(ParseError {
            line: line_no,
            message: "effects declaration must include at least one effect".into(),
        });
    }

    Ok(out)
}

fn parse_action(line: &str, line_no: usize, depth: usize) -> Result<ActionDecl, ParseError> {
    if depth > 8 {
        return Err(ParseError {
            line: line_no,
            message: "nested `if` depth exceeds limit".into(),
        });
    }
    let toks = tokenize(line, line_no)?;
    parse_action_tokens(&toks, line_no, depth)
}

fn parse_action_tokens(
    toks: &[String],
    line_no: usize,
    depth: usize,
) -> Result<ActionDecl, ParseError> {
    if toks.is_empty() {
        return Err(ParseError {
            line: line_no,
            message: "empty action".into(),
        });
    }

    match toks[0].as_str() {
        "log" => parse_log(toks, line_no),
        "set" => parse_set_state(toks, line_no),
        "inc" => parse_inc_state(toks, line_no),
        "timer" => parse_timer_local(toks, line_no),
        "send" => parse_send(toks, line_no),
        "if" => parse_if_state_eq(toks, line_no, depth),
        other => Err(ParseError {
            line: line_no,
            message: format!("unknown action `{other}`"),
        }),
    }
}

fn parse_log(toks: &[String], line_no: usize) -> Result<ActionDecl, ParseError> {
    if toks.len() < 2 {
        return Err(ParseError {
            line: line_no,
            message: "log action must be: log <template>".into(),
        });
    }
    Ok(ActionDecl::Log {
        template: toks[1..].join(" "),
    })
}

fn parse_set_state(toks: &[String], line_no: usize) -> Result<ActionDecl, ParseError> {
    if toks.len() != 3 {
        return Err(ParseError {
            line: line_no,
            message: "set action must be: set <state> <int>".into(),
        });
    }
    let value = toks[2].parse::<i64>().map_err(|_| ParseError {
        line: line_no,
        message: format!("invalid integer value `{}`", toks[2]),
    })?;
    Ok(ActionDecl::SetState {
        key: toks[1].clone(),
        value,
    })
}

fn parse_inc_state(toks: &[String], line_no: usize) -> Result<ActionDecl, ParseError> {
    if toks.len() < 2 || toks.len() > 3 {
        return Err(ParseError {
            line: line_no,
            message: "inc action must be: inc <state> [by]".into(),
        });
    }
    let by = if toks.len() == 3 {
        toks[2].parse::<i64>().map_err(|_| ParseError {
            line: line_no,
            message: format!("invalid integer value `{}`", toks[2]),
        })?
    } else {
        1
    };
    Ok(ActionDecl::IncState {
        key: toks[1].clone(),
        by,
    })
}

fn parse_if_state_eq(
    toks: &[String],
    line_no: usize,
    depth: usize,
) -> Result<ActionDecl, ParseError> {
    if toks.len() < 5 {
        return Err(ParseError {
            line: line_no,
            message: "if action must be: if <state> == <int> <action...>".into(),
        });
    }
    if toks[2] != "==" {
        return Err(ParseError {
            line: line_no,
            message: "if currently supports only `==` comparison".into(),
        });
    }
    let value = toks[3].parse::<i64>().map_err(|_| ParseError {
        line: line_no,
        message: format!("invalid integer value `{}`", toks[3]),
    })?;
    let nested = parse_action_tokens(&toks[4..], line_no, depth + 1)?;
    Ok(ActionDecl::IfStateEq {
        key: toks[1].clone(),
        value,
        then_action: Box::new(nested),
    })
}

fn parse_timer_local(toks: &[String], line_no: usize) -> Result<ActionDecl, ParseError> {
    if toks.len() < 5 {
        return Err(ParseError {
            line: line_no,
            message: "timer action must be: timer <steps> [local|remote ...] <Service> <Message> <template>".into(),
        });
    }

    let steps = toks[1].parse::<u64>().map_err(|_| ParseError {
        line: line_no,
        message: format!("invalid timer step value `{}`", toks[1]),
    })?;
    if steps == 0 {
        return Err(ParseError {
            line: line_no,
            message: "timer steps must be >= 1".into(),
        });
    }

    match toks[2].as_str() {
        "remote" => {
            if toks.len() < 7 {
                return Err(ParseError {
                    line: line_no,
                    message: "remote timer must be: timer <steps> remote <peers|sender|node:...> <Service> <Message> <template>".into(),
                });
            }
            let target = parse_remote_target(&toks[3], line_no)?;
            Ok(ActionDecl::TimerRemote {
                steps,
                target,
                service: toks[4].clone(),
                message: toks[5].clone(),
                template: toks[6..].join(" "),
            })
        }
        "local" => {
            if toks.len() < 6 {
                return Err(ParseError {
                    line: line_no,
                    message:
                        "local timer must be: timer <steps> local <Service> <Message> <template>"
                            .into(),
                });
            }
            Ok(ActionDecl::TimerLocal {
                steps,
                service: toks[3].clone(),
                message: toks[4].clone(),
                template: toks[5..].join(" "),
            })
        }
        _ => Ok(ActionDecl::TimerLocal {
            steps,
            service: toks[2].clone(),
            message: toks[3].clone(),
            template: toks[4..].join(" "),
        }),
    }
}

fn parse_send(toks: &[String], line_no: usize) -> Result<ActionDecl, ParseError> {
    if toks.len() < 5 {
        return Err(ParseError {
            line: line_no,
            message: "send action is incomplete".into(),
        });
    }

    match toks[1].as_str() {
        "local" => {
            let service = toks[2].clone();
            let message = toks[3].clone();
            let template = toks[4..].join(" ");
            Ok(ActionDecl::SendLocal {
                service,
                message,
                template,
            })
        }
        "remote" => {
            if toks.len() < 6 {
                return Err(ParseError {
                    line: line_no,
                    message: "remote send must be: send remote <peers|sender|node:...> <Service> <Message> <template>".into(),
                });
            }
            let target = parse_remote_target(&toks[2], line_no)?;
            let service = toks[3].clone();
            let message = toks[4].clone();
            let template = toks[5..].join(" ");
            Ok(ActionDecl::SendRemote {
                target,
                service,
                message,
                template,
            })
        }
        scope => Err(ParseError {
            line: line_no,
            message: format!("unknown send scope `{scope}`; expected `local` or `remote`"),
        }),
    }
}

fn parse_remote_target(raw: &str, line_no: usize) -> Result<RemoteTarget, ParseError> {
    match raw {
        "peers" => Ok(RemoteTarget::Peers),
        "sender" => Ok(RemoteTarget::Sender),
        _ if raw.starts_with("node:") && raw.len() > "node:".len() => {
            Ok(RemoteTarget::Node(raw["node:".len()..].to_string()))
        }
        _ => Err(ParseError {
            line: line_no,
            message: format!(
                "invalid remote target `{raw}`; expected peers, sender, or node:<uuid>"
            ),
        }),
    }
}

fn tokenize(line: &str, line_no: usize) -> Result<Vec<String>, ParseError> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut chars = line.chars().peekable();
    let mut in_quotes = false;

    while let Some(ch) = chars.next() {
        if in_quotes {
            match ch {
                '"' => in_quotes = false,
                '\\' => {
                    let Some(next) = chars.next() else {
                        return Err(ParseError {
                            line: line_no,
                            message: "unterminated escape sequence".into(),
                        });
                    };
                    cur.push(next);
                }
                _ => cur.push(ch),
            }
            continue;
        }

        match ch {
            '"' => in_quotes = true,
            c if c.is_whitespace() => {
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
            }
            _ => cur.push(ch),
        }
    }

    if in_quotes {
        return Err(ParseError {
            line: line_no,
            message: "unterminated quoted string".into(),
        });
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::parse_module;
    use crate::ast::{ActionDecl, HandlerEffect, RemoteTarget};

    #[test]
    fn parses_service_handlers_and_actions() {
        let src = r#"
        service Gateway
        state sent = 0
        on start
          effects state_write state_read log send_remote timer_local timer_remote
          inc sent
          if sent == 1 log "first send"
          send remote peers Echo hello "hello from $self_node"
          timer 2 Gateway tick "tick-$state.sent"
          timer 3 remote peers Echo hello "later-$state.sent"
        on echo_reply
          effects log
          log "got $text"

        service Echo
        on hello
          effects send_remote
          send remote sender Gateway echo_reply "echo($text)"
        "#;

        let module = parse_module(src).expect("parse should succeed");
        assert_eq!(module.services.len(), 2);
        let gateway = &module.services[0];
        assert_eq!(gateway.name, "Gateway");
        assert_eq!(gateway.states.len(), 1);
        assert_eq!(gateway.handlers.len(), 2);
        assert_eq!(
            gateway.handlers[0].effects,
            vec![
                HandlerEffect::StateWrite,
                HandlerEffect::StateRead,
                HandlerEffect::Log,
                HandlerEffect::SendRemote,
                HandlerEffect::TimerLocal,
                HandlerEffect::TimerRemote
            ]
        );

        match &gateway.handlers[0].actions[2] {
            ActionDecl::SendRemote {
                target,
                service,
                message,
                ..
            } => {
                assert_eq!(*target, RemoteTarget::Peers);
                assert_eq!(service, "Echo");
                assert_eq!(message, "hello");
            }
            other => panic!("unexpected action: {other:?}"),
        }

        match &gateway.handlers[0].actions[3] {
            ActionDecl::TimerLocal {
                steps,
                service,
                message,
                ..
            } => {
                assert_eq!(*steps, 2);
                assert_eq!(service, "Gateway");
                assert_eq!(message, "tick");
            }
            other => panic!("unexpected action: {other:?}"),
        }

        match &gateway.handlers[0].actions[4] {
            ActionDecl::TimerRemote {
                steps,
                target,
                service,
                message,
                ..
            } => {
                assert_eq!(*steps, 3);
                assert_eq!(*target, RemoteTarget::Peers);
                assert_eq!(service, "Echo");
                assert_eq!(message, "hello");
            }
            other => panic!("unexpected action: {other:?}"),
        }
    }

    #[test]
    fn rejects_handler_missing_effects_declaration() {
        let src = r#"
        service Gateway
        on start
          log "x"
        "#;

        let err = parse_module(src).expect_err("parse should fail");
        assert!(
            err.message.contains("missing required effects declaration"),
            "unexpected error: {err}"
        );
    }
}
