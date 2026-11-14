//! The `esm` command-line tool.
//!
//! The implementation is `esm_impl.rs`; the time integrators `esm simulate`
//! can run on are behind the [`backend::Backend`] trait in `backend.rs`.

mod backend;
mod esm_impl;

fn main() -> std::process::ExitCode {
    esm_impl::main()
}
