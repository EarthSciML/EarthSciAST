//! The `esm` command-line tool's entry point: parse the command line, run the
//! subcommand, and map its result to the exit code.
//!
//! The subcommands live in their own modules (`inspect`, `simulate`, `test_cmd`,
//! `conformance`); `backend.rs` holds the time integrators `simulate` runs on.

use clap::Parser;

use crate::args::{Cli, Commands};
use crate::conformance::run_conformance_test;
use crate::inspect::{
    run_convert, run_diff, run_extract, run_graph, run_info, run_pretty, run_round_trip,
    run_stoich, run_units, run_validate, run_validate_fixtures,
};
use crate::simulate::run_simulate;
#[cfg(feature = "diffsol")]
use crate::test_cmd::run_test;

// === Exit discipline =======================================================

/// A deliberate CLI failure (exit 1) raised after a handler has shaped its own
/// diagnostics. [`main`] prints `message` — if any — to stderr verbatim, with
/// no `Error:` prefix and no Debug quoting; `None` means the handler already
/// printed everything (typically a report on stdout). Ordinary propagated
/// errors keep the `Error: {:?}` rendering a `Result` main gives them.
#[derive(Debug)]
pub(crate) struct CliFailure {
    message: Option<String>,
}

impl std::fmt::Display for CliFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message.as_deref().unwrap_or("command failed"))
    }
}

impl std::error::Error for CliFailure {}

/// Exit-1 failure carrying a message for stderr.
pub(crate) fn fail(message: impl Into<String>) -> Box<dyn std::error::Error> {
    Box::new(CliFailure {
        message: Some(message.into()),
    })
}

/// The refusal of a command that runs on diffsol only, in a build without it.
#[cfg(not(feature = "diffsol"))]
pub(crate) fn needs_diffsol(command: &str) -> Box<dyn std::error::Error> {
    fail(format!(
        "{command} integrates with diffsol, which this build of `esm` does not \
         have: rebuild with `--features diffsol`"
    ))
}

/// Exit-1 failure whose diagnostics the handler already printed.
pub(crate) fn fail_silent() -> Box<dyn std::error::Error> {
    Box::new(CliFailure { message: None })
}

/// The single exit point: every handler returns `Result`, and failure exits 1.
/// A [`CliFailure`] prints its own message (if any) verbatim to stderr; any
/// other error is rendered `Error: {:?}` — the same report `std`'s
/// `Termination` gives a `Result`-returning main. (Clap usage errors exit 2
/// from `Cli::parse`, as ever.)
pub fn main() -> std::process::ExitCode {
    let cli = Cli::parse();

    let result = match cli.command {
        Commands::Validate { file, verbose } => run_validate(file, verbose),
        Commands::Pretty { file, format } => run_pretty(file, format),
        Commands::Extract {
            file,
            component,
            output,
        } => run_extract(file, component, output),
        Commands::Diff { file1, file2 } => run_diff(file1, file2),
        Commands::Stoich { file, system } => run_stoich(file, system),
        Commands::Graph {
            file,
            level,
            format,
            system,
        } => run_graph(file, level, format, system),
        Commands::Convert { input, output, to } => run_convert(input, output, to),
        Commands::Simulate {
            file,
            time,
            output,
            observed,
            model,
            format,
            compiler,
            no_count_fold,
            backend,
            run_config,
            dt,
            plan_dir,
        } => run_simulate(
            file,
            time,
            output,
            observed,
            model,
            format,
            compiler,
            no_count_fold,
            backend,
            crate::backend::IntegratorOptions {
                run_config,
                dt,
                plan_dir,
            },
        ),
        Commands::Info { file } => run_info(file),
        Commands::Units { file, check } => run_units(file, check),
        Commands::ValidateFixtures {
            directory,
            recursive,
        } => run_validate_fixtures(directory, recursive),
        Commands::RoundTrip { file, rounds } => run_round_trip(file, rounds),
        Commands::Test {
            paths,
            model,
            filter,
            solver,
            reltol,
            abstol,
            verbose,
            compiler,
        } => {
            #[cfg(feature = "diffsol")]
            {
                run_test(
                    paths, model, filter, solver, reltol, abstol, verbose, compiler,
                )
            }
            #[cfg(not(feature = "diffsol"))]
            {
                let _ = (
                    paths, model, filter, solver, reltol, abstol, verbose, compiler,
                );
                Err(needs_diffsol("esm test"))
            }
        }
        Commands::ConformanceTest { out_dir, manifest } => {
            run_conformance_test(&out_dir, manifest.as_deref())
        }
    };

    match result {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            match e.downcast::<CliFailure>() {
                Ok(failure) => {
                    if let Some(message) = failure.message {
                        eprintln!("{message}");
                    }
                }
                Err(other) => eprintln!("Error: {other:?}"),
            }
            std::process::ExitCode::FAILURE
        }
    }
}
