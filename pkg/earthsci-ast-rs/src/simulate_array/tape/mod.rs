//! Tape compilation (Step 3a: compile-time half) — the IR. The lowering pass,
//! diagnostics and verification harness land in the follow-up commits.

mod ir;

pub(crate) use ir::*;
