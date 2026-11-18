//! The `esm` command-line tool.
//!
//! The command line is defined in `args.rs` and dispatched by `esm_impl.rs`;
//! each subcommand family has its own module, and the time integrators
//! `esm simulate` can run on are behind the [`backend::Backend`] trait in
//! `backend.rs`.

mod args;
mod backend;
mod conformance;
mod data_sources;
mod esm_impl;
mod input;
mod inspect;
mod simulate;
#[cfg(feature = "diffsol")]
mod test_cmd;

fn main() -> std::process::ExitCode {
    esm_impl::main()
}
