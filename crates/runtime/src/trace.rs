use crate::event::TraceEvent;
use anyhow::{Context, Result};
use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::Path;

pub struct TraceWriter {
    w: BufWriter<File>,
}

impl TraceWriter {
    pub fn create(path: impl AsRef<Path>) -> Result<Self> {
        let f = File::create(path).context("create trace file")?;
        Ok(Self {
            w: BufWriter::new(f),
        })
    }

    pub fn write(&mut self, ev: &TraceEvent) -> Result<()> {
        serde_json::to_writer(&mut self.w, ev).context("serialize trace event")?;
        self.w.write_all(b"\n").context("write trace newline")?;
        Ok(())
    }

    pub fn flush(&mut self) -> Result<()> {
        self.w.flush().context("flush trace writer")
    }
}

pub struct TraceReader {
    r: BufReader<File>,
    next_line: String,
}

impl TraceReader {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let f = File::open(path).context("open trace file")?;
        Ok(Self {
            r: BufReader::new(f),
            next_line: String::new(),
        })
    }

    pub fn next(&mut self) -> Result<Option<TraceEvent>> {
        self.next_line.clear();
        let n = self
            .r
            .read_line(&mut self.next_line)
            .context("read trace line")?;
        if n == 0 {
            return Ok(None);
        }

        let ev = serde_json::from_str(&self.next_line).context("parse trace json")?;
        Ok(Some(ev))
    }
}
