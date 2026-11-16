//! The `esm` command line: the subcommands, their arguments and the typed
//! values their flags take.

use clap::{Parser, Subcommand, ValueEnum};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "esm")]
#[command(about = "A CLI tool for EarthSciML Abstract Syntax Tree Format")]
#[command(version)]
pub(crate) struct Cli {
    #[command(subcommand)]
    pub(crate) command: Commands,
}

#[derive(Subcommand)]
pub(crate) enum Commands {
    /// Validate an ESM file
    Validate {
        /// Path to the ESM file to validate
        #[arg(value_name = "FILE")]
        file: PathBuf,
        /// Show detailed validation output
        #[arg(long)]
        verbose: bool,
    },
    /// Pretty-print mathematical expressions in an ESM file
    #[command(visible_alias = "display")]
    Pretty {
        /// Path to the ESM file
        #[arg(value_name = "FILE")]
        file: PathBuf,
        /// Output format (unicode, latex, ascii)
        #[arg(short, long, default_value = "unicode")]
        format: DisplayFormat,
    },
    /// Extract a single component from an ESM file
    Extract {
        /// Input ESM file
        #[arg(value_name = "FILE")]
        file: PathBuf,
        /// Component ID to extract
        #[arg(long)]
        component: String,
        /// Output file (or stdout if not specified)
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Compare two ESM files semantically
    Diff {
        /// First ESM file
        #[arg(value_name = "FILE1")]
        file1: PathBuf,
        /// Second ESM file
        #[arg(value_name = "FILE2")]
        file2: PathBuf,
    },
    /// Generate stoichiometric matrix for a reaction system
    Stoich {
        /// Path to the ESM file
        #[arg(value_name = "FILE")]
        file: PathBuf,
        /// Reaction system ID
        #[arg(long)]
        system: String,
    },
    /// Generate system or expression graphs
    Graph {
        /// Path to the ESM file
        #[arg(value_name = "FILE")]
        file: PathBuf,
        /// Graph level (component or expression)
        #[arg(long, default_value = "component")]
        level: GraphLevel,
        /// Output format (dot, mermaid, json)
        #[arg(short, long, default_value = "dot")]
        format: GraphFormat,
        /// System ID (for expression-level graphs)
        #[arg(long)]
        system: Option<String>,
    },
    /// Convert an ESM file to a different format
    Convert {
        /// Input ESM file
        #[arg(value_name = "INPUT")]
        input: PathBuf,
        /// Output file (or stdout if not specified)
        #[arg(short, long, value_name = "OUTPUT")]
        output: Option<PathBuf>,
        /// Target format (json, compact-json)
        #[arg(long, default_value = "json")]
        to: ConvertFormat,
    },
    /// Run basic simulations
    Simulate {
        /// Path to the ESM file
        #[arg(value_name = "FILE")]
        file: PathBuf,
        /// Simulation duration
        #[arg(long, default_value = "10.0")]
        time: f64,
        /// Output file for results
        #[arg(short, long)]
        output: Option<PathBuf>,
        /// Observed field to write alongside the state; repeat for several.
        /// Output is the state PLUS the fields named here, never every
        /// observed by default (streaming-output-sinks RFC decision 8).
        ///
        /// On a document with nothing to integrate this selects the COLUMNS of
        /// the single evaluation, and only their dependency cone (each named
        /// observed and every observed it reads, transitively) is evaluated,
        /// not the whole observed graph; omitted, every field the build
        /// materialized is written. Under the strict `native` compiler only
        /// the cone can be refused, so a document refused whole can still be
        /// run for columns that do not read the refused rule. A name no
        /// declared variable could answer is refused before anything is
        /// evaluated.
        #[arg(long = "observed", value_name = "NAME")]
        observed: Vec<String>,
        /// Build this model when the document holds several.
        #[arg(long = "model", value_name = "NAME")]
        model: Option<String>,
        /// Shape of --output: `flat` is the flat state rows keyed by cell key;
        /// `grid` is the derived output plan — dimension-labeled, row-major
        /// [time, …spatial] arrays with CF coordinates and attributes; `csv`
        /// is one row per index tuple over the shape the written fields share
        /// — a RELATIONAL document's rows, for a row-by-row comparator.
        #[arg(long, default_value = "flat")]
        format: SimulateFormat,
        /// WHICH strategy builds the right-hand side (API_SPEC §5.8's closed
        /// vocabulary): `native` (the default — the tape, for every document,
        /// and strict: a rule it cannot express is a build error naming the
        /// rule), `interpreter` (the reference: every fast tier off, no
        /// performance promise), or `xla` (the emitter over the tape, run
        /// through XLA; needs a build with the `xla` feature and a usable
        /// `xla_extension`, and refuses with `compiler_unavailable`
        /// otherwise). `mtk` and `sympy` belong to the Julia and Python
        /// bindings and are always `compiler_unavailable` here.
        #[arg(long, value_name = "NAME")]
        compiler: Option<String>,
        /// Build without the counted-bracket rewrite
        /// (`CompilerRewrites::count_fold`): the A/B seam for timing it.
        #[arg(long, hide = true)]
        no_count_fold: bool,
        /// WHICH time integrator runs a document that integrates: `diffsol`
        /// (the solver `earthsci-ast` links; cargo feature `diffsol`, on by
        /// default) or `integrator` (EarthSciIntegrator; cargo feature
        /// `integrator`). Omitted, the first of those this build has. A name
        /// this build lacks is refused, naming the feature to build with.
        /// The integrator refuses `--observed` and `--compiler`. (Not `--solver`:
        /// `esm test --solver` names diffsol's method.)
        #[arg(long, value_name = "NAME")]
        backend: Option<String>,
        /// `integrator` only: the run configuration (EarthSciIntegrator
        /// spec/run-config.md) to plan, whose `model` must be FILE. Omitted,
        /// the integrator's own default schedule (`"auto"`) runs, inside
        /// fixed macro steps of `--dt`.
        #[arg(long, value_name = "FILE")]
        run_config: Option<PathBuf>,
        /// `integrator` only: the fixed macro step of the default run
        /// configuration, in seconds; default a hundredth of the run.
        #[arg(long, value_name = "SECONDS")]
        dt: Option<f64>,
        /// `integrator` only: where to write the plan. Omitted, it goes in a
        /// directory under the system temporary directory, removed after the
        /// run.
        #[arg(long, value_name = "DIR")]
        plan_dir: Option<PathBuf>,
    },
    /// Show information about an ESM file
    Info {
        /// Path to the ESM file
        #[arg(value_name = "FILE")]
        file: PathBuf,
    },
    /// Dimensional analysis report
    Units {
        /// Path to the ESM file
        #[arg(value_name = "FILE")]
        file: PathBuf,
        /// Check dimensional consistency
        #[arg(long)]
        check: bool,
    },
    /// Batch validation for test suites
    ValidateFixtures {
        /// Directory containing ESM files
        #[arg(value_name = "DIRECTORY")]
        directory: PathBuf,
        /// Recursive directory traversal
        #[arg(short, long)]
        recursive: bool,
    },
    /// Test load/save fidelity
    RoundTrip {
        /// Path to the ESM file
        #[arg(value_name = "FILE")]
        file: PathBuf,
        /// Number of round trips
        #[arg(long, default_value = "1")]
        rounds: usize,
    },
    /// Run the inline §6.6 tests of every named file and report pass/fail
    #[command(visible_alias = "run-tests")]
    Test {
        /// ESM files, and/or directories searched recursively for `.esm` files
        #[arg(value_name = "PATH", required = true)]
        paths: Vec<PathBuf>,
        /// Only run the tests of this model
        #[arg(long, value_name = "NAME")]
        model: Option<String>,
        /// Only run tests whose id contains this substring
        #[arg(long, value_name = "SUBSTRING")]
        filter: Option<String>,
        /// Solver family for the inline-test integrations
        #[arg(long, default_value = "bdf")]
        solver: SolverAlg,
        /// Relative SOLVER tolerance — how accurately each test is integrated,
        /// NOT the §6.6.4 tolerance its assertions are judged against.
        /// Unset resolves per esm-spec §2.2.2: the document's `solver.reltol`
        /// if it declares one, else the runner default.
        #[arg(long)]
        reltol: Option<f64>,
        /// Absolute SOLVER tolerance — how accurately each test is integrated,
        /// NOT the §6.6.4 tolerance its assertions are judged against.
        /// Unset resolves per esm-spec §2.2.2, as `--reltol`.
        #[arg(long)]
        abstol: Option<f64>,
        /// Report every assertion, not just the summary table
        #[arg(short, long)]
        verbose: bool,
        /// WHICH strategy builds each test's right-hand side (API_SPEC §5.8's
        /// closed vocabulary). Unset is `native`, which is STRICT: a document
        /// whose rules the tape cannot lower fails with the refusal rather
        /// than running on a slower path. Pass `interpreter` to run the
        /// reference evaluator, which refuses nothing it can evaluate.
        #[arg(long, value_name = "NAME")]
        compiler: Option<String>,
    },
    /// Run cross-language conformance tests and write results.json to OUT_DIR
    ConformanceTest {
        /// Directory to write results.json into
        #[arg(value_name = "OUT_DIR")]
        out_dir: PathBuf,
        /// Shared corpus manifest (scripts/conformance_corpus.py). Defaults to
        /// $ESM_CONFORMANCE_MANIFEST, then <OUT_DIR>/../corpus_manifest.json.
        #[arg(value_name = "MANIFEST")]
        manifest: Option<PathBuf>,
    },
}

// === Enumerated flag values ================================================
//
// Typed `ValueEnum` flags: clap itself rejects an unknown value (with its
// standard "invalid value … possible values …" usage error, exit 2), so the
// handlers match exhaustively instead of each carrying a reject-unknown arm.

/// `graph --level`.
#[derive(Clone, Copy, ValueEnum)]
pub(crate) enum GraphLevel {
    Component,
    Expression,
}

/// `graph --format` (§4.8.3 rendering formats).
#[derive(Clone, Copy, ValueEnum)]
pub(crate) enum GraphFormat {
    Dot,
    Mermaid,
    Json,
}

/// `simulate --format`.
#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
pub(crate) enum SimulateFormat {
    /// The flat solver state: one row per cell key, no axis metadata.
    Flat,
    /// The `derive_output_plan` result: one entry per emergent grid, each with
    /// its dimensions, CF dimension coordinates and row-major variable arrays.
    Grid,
    /// One row per index tuple: the index columns `i1…in`, then one column per
    /// field, over the shape every written field shares. This is the shape of a
    /// RELATIONAL document — rows computed from rows — and the shape a
    /// row-by-row comparator reads. Only for a document evaluated once; a
    /// trajectory is not a row set.
    Csv,
}

/// `convert --to`.
#[derive(Clone, Copy, ValueEnum)]
pub(crate) enum ConvertFormat {
    Json,
    CompactJson,
}

/// `test --solver`. [`earthsci_ast::Alg`] is a library type and cannot derive
/// `clap::ValueEnum` here, so the CLI spelling of the solver family lives in
/// this shim; `Alg::from_name` remains the mapping for string hosts.
#[derive(Clone, Copy, ValueEnum)]
pub(crate) enum SolverAlg {
    Bdf,
    Sdirk,
    Erk,
}

impl From<SolverAlg> for earthsci_ast::Alg {
    fn from(value: SolverAlg) -> Self {
        match value {
            SolverAlg::Bdf => earthsci_ast::Alg::Bdf,
            SolverAlg::Sdirk => earthsci_ast::Alg::Sdirk,
            SolverAlg::Erk => earthsci_ast::Alg::Erk,
        }
    }
}

// === CLI helpers ===========================================================

/// The three expression rendering formats accepted by `pretty --format`.
#[derive(Clone, Copy, ValueEnum)]
pub(crate) enum DisplayFormat {
    Unicode,
    Latex,
    Ascii,
}
