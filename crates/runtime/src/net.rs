use crate::event::{ActorId, MsgId, NodeId};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc::Sender;
use std::thread;
use std::time::Duration;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WireEnvelope {
    pub from_node: NodeId,
    pub to_node: NodeId,
    pub to_actor: ActorId,
    pub msg_id: MsgId,
    pub payload: Value,
}

pub fn spawn_listener(
    bind_addr: String,
    tx: Sender<WireEnvelope>,
) -> Result<thread::JoinHandle<()>> {
    let listener =
        TcpListener::bind(&bind_addr).with_context(|| format!("bind listener on {bind_addr}"))?;

    let handle = thread::spawn(move || {
        for stream in listener.incoming() {
            let stream = match stream {
                Ok(s) => s,
                Err(err) => {
                    eprintln!("listener accept error: {err}");
                    continue;
                }
            };

            let tx = tx.clone();
            thread::spawn(move || {
                if let Err(err) = read_stream(stream, tx) {
                    eprintln!("read stream error: {err}");
                }
            });
        }
    });

    Ok(handle)
}

fn read_stream(stream: TcpStream, tx: Sender<WireEnvelope>) -> Result<()> {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    loop {
        line.clear();
        let n = reader.read_line(&mut line).context("read envelope line")?;
        if n == 0 {
            break;
        }

        let env: WireEnvelope = serde_json::from_str(&line).context("deserialize wire envelope")?;
        if tx.send(env).is_err() {
            break;
        }
    }
    Ok(())
}

pub fn send_envelope(addr: &str, env: &WireEnvelope) -> Result<()> {
    let mut stream = connect_with_retry(addr, 40, Duration::from_millis(100))?;
    serde_json::to_writer(&mut stream, env).context("serialize wire envelope")?;
    stream.write_all(b"\n").context("write envelope newline")?;
    stream.flush().context("flush envelope")?;
    Ok(())
}

fn connect_with_retry(addr: &str, attempts: usize, delay: Duration) -> Result<TcpStream> {
    let mut last_err = None;
    for _ in 0..attempts {
        match TcpStream::connect(addr) {
            Ok(stream) => return Ok(stream),
            Err(err) => {
                last_err = Some(err);
                thread::sleep(delay);
            }
        }
    }

    let msg = match last_err {
        Some(err) => format!("connect to {addr} failed after {attempts} attempts: {err}"),
        None => format!("connect to {addr} failed"),
    };
    anyhow::bail!(msg);
}
