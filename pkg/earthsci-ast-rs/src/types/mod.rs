//! Core type definitions for the ESM format
//!
//! This module provides Rust types that correspond to the ESM JSON Schema.
//!
//! The types are grouped by concern:
//! - [`document`]: top-level file structure, metadata, references, tables
//! - [`expression`]: expression AST nodes and their child-visit machinery
//! - [`analysis`]: inline model tests, parameter sweeps, and plot definitions
//! - [`model`]: models, variables, parameter updates, and equations
//! - [`events`]: discrete and continuous events
//! - [`components`]: reaction systems, data sources, operators, and coupling

mod analysis;
mod components;
mod document;
mod events;
mod expression;
mod model;

pub use analysis::*;
pub use components::*;
pub use document::*;
pub use events::*;
pub use expression::*;
pub use model::*;
