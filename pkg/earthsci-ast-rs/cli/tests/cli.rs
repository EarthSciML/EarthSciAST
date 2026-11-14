//! The tests that drive the `esm` binary, compiled as ONE test binary.
//!
//! Cargo sets `CARGO_BIN_EXE_esm` only for the package that owns the binary,
//! so every test that runs `esm` lives in this crate. Each file under
//! `tests/cli/` is a module here (cargo discovers only top-level `tests/*.rs`
//! files as targets). Where a file shares its name with one in `earthsci-ast`'s
//! `tests/`, that one holds the library half of the same pins.
//!
//! The binary runs with this crate's directory as its working directory, so a
//! fixture of `earthsci-ast` is `../tests/fixtures/...` and a shared fixture
//! of the repository is `../../../tests/...`.

#[path = "cli/array_observed_output.rs"]
mod array_observed_output;
#[path = "cli/cli_data_source_ingest.rs"]
mod cli_data_source_ingest;
#[path = "cli/cli_static_evaluation_output.rs"]
mod cli_static_evaluation_output;
#[path = "cli/cli_test_command.rs"]
mod cli_test_command;
#[path = "cli/cli_units_command.rs"]
mod cli_units_command;
#[path = "cli/observed_cone.rs"]
mod observed_cone;
#[path = "cli/records_per_sample_conformance.rs"]
mod records_per_sample_conformance;
#[path = "cli/simulate_backend.rs"]
mod simulate_backend;
#[path = "cli/undeclared_operand_gate.rs"]
mod undeclared_operand_gate;
#[path = "cli/url_substitutions_conformance.rs"]
mod url_substitutions_conformance;
