pub mod ast;
pub mod parser;

pub use ast::{
    ActionDecl, HandlerDecl, HandlerEffect, Module, RemoteTarget, ServiceDecl, StateDecl,
};
pub use parser::{parse_module, ParseError};
