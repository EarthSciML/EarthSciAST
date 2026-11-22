//! `esm test`: run the inline tests (esm-spec §6.6) of every named document
//! and report pass or fail.

use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::args::SolverAlg;
use crate::data_sources::cache_root;
use crate::esm_impl::{fail, fail_silent};
use crate::input::collect_esm_files;

// === Inline-test runner (esm-spec §6.6) ====================================

/// The SOLVER tolerances the inline-test integrations run at — deliberately
/// NOT the library defaults [`earthsci_ast::DEFAULT_RELTOL`] /
/// [`earthsci_ast::DEFAULT_ABSTOL`], and deliberately not the §6.6.4 assertion
/// tolerances either. A default is what a document gets when its author
/// expressed no opinion about accuracy; a test asserting a number to sixteen
/// digits has very much expressed one, so integrating at the library default
/// would make the test assert something about the library's default rather
/// than about the model.
///
/// `TEST_ABSTOL` matches the Python binding's `1e-14` rather than the Julia
/// runner's `1e-12`, for the reason Python records: the shared fixture corpus
/// this command is pointed at integrates concentrations of order `1e-6` while
/// asserting a RELATIVE `1e-6`, an absolute gate near `4e-13`. A solver
/// `abstol` of `1e-12` is looser than the assertion it has to clear, so the
/// run could not be accurate enough to be worth asserting on. That is a
/// property of the fixtures, not a divergence between the bindings.
pub(crate) const TEST_RELTOL: f64 = 1e-10;
pub(crate) const TEST_ABSTOL: f64 = 1e-14;

/// PASS / FAIL / ERROR — the tri-state verdict the Julia runner reports.
///
/// [`earthsci_ast::AssertionResult`] carries a two-state `passed: bool` and
/// stays that way: it is `Serialize`d verbatim by `examples/pde_conformance.rs`
/// as a payload an external runner consumes. The third state is RECOVERED from
/// it instead. `run_inline_tests` sets `actual: Some(_)` exactly on the path that
/// got as far as comparing a number against the resolved tolerance, and
/// `actual: None` on every path that failed before then — discretization
/// injection, the problem build, the solve, the solver retcode, and assertion
/// evaluation. So a non-passing result with no `actual` never reached the
/// comparison and is an ERROR; one with an `actual` reached it and lost, and
/// is a FAIL.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Verdict {
    Pass,
    Fail,
    Error,
}

impl Verdict {
    /// The verdict of one finished assertion, per the `actual`-is-`None`
    /// invariant documented on [`Verdict`].
    fn of(passed: bool, actual: Option<f64>) -> Self {
        match (passed, actual) {
            (true, _) => Verdict::Pass,
            (false, None) => Verdict::Error,
            (false, Some(_)) => Verdict::Fail,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Verdict::Pass => "PASS",
            Verdict::Fail => "FAIL",
            Verdict::Error => "ERROR",
        }
    }

    /// Column of the summary table's `pass | fail | err` triple.
    fn column(self) -> usize {
        match self {
            Verdict::Pass => 0,
            Verdict::Fail => 1,
            Verdict::Error => 2,
        }
    }
}

/// One assertion's outcome, tagged with the file it came from.
///
/// [`earthsci_ast::AssertionResult`] now carries a `file` of its own, but it is
/// empty on every row this command produces: the engine is handed an
/// already-loaded document, which has no path. This command also has to report
/// a file that fails to LOAD, and a `Verdict` the library's two-state `passed`
/// does not carry — so the runner keeps its own row type rather than the
/// library's.
pub(crate) struct TestRow {
    file: PathBuf,
    container: String,
    test_id: String,
    assertion_idx: usize,
    variable: String,
    time: f64,
    verdict: Verdict,
    message: String,
}

/// Render a float the way Julia's `print` does, so the two runners' summaries
/// read the same (`100.0`, `1.0e6`, a decimal tie with the even last digit).
pub(crate) fn julia_float(v: f64) -> String {
    earthsci_ast::extension::canonicalize::format_julia_float(v)
}

/// Every `.esm` file named by `paths`: a path that is a directory is walked
/// RECURSIVELY (matching the Julia runner's `discover_esm_files`, which has no
/// non-recursive mode), any other path is taken as named — including one that
/// does not exist, which then surfaces as a load ERROR naming it rather than
/// vanishing from the run. Globally sorted and deduplicated, so overlapping
/// arguments run each file exactly once.
pub(crate) fn discover_test_inputs(
    paths: &[PathBuf],
) -> Result<Vec<PathBuf>, Box<dyn std::error::Error>> {
    let mut out = Vec::new();
    for path in paths {
        if path.is_dir() {
            collect_esm_files(path, true, &mut out)?;
        } else {
            out.push(path.clone());
        }
    }
    out.sort();
    out.dedup();
    Ok(out)
}

/// `path` relative to the working directory when it lies under it, else `path`
/// verbatim — the Julia summary's `rel`, which relativizes against its root
/// and otherwise prints the path as given.
pub(crate) fn relative_to_cwd(path: &std::path::Path) -> String {
    std::env::current_dir()
        .ok()
        .and_then(|cwd| {
            path.strip_prefix(&cwd)
                .ok()
                .map(std::path::Path::to_path_buf)
        })
        .unwrap_or_else(|| path.to_path_buf())
        .display()
        .to_string()
}

/// The top-level `models.<k>` and `reaction_systems.<k>` MOUNT EDGES a document
/// declares in its SOURCE, as `"<k> ← <ref>"` lines in document order (models
/// first).
///
/// Read from the raw file because a LOADED document no longer shows them: the
/// mount splices the referenced leaf's component in under the same key (§4.7 /
/// §9.7.10), leaving nothing to distinguish it from one the document wrote
/// itself. `esm test` reports them so the §6.6 rule — a mount does not carry the
/// mounted component's inline tests — is VISIBLE rather than silent: the reader
/// is told which components were not asserted on here, and where their own
/// assertions live.
///
/// Best-effort: an unreadable or unparseable file yields nothing, because the
/// run itself already reports that failure as a load ERROR row.
pub(crate) fn mounted_components(path: &std::path::Path) -> Vec<String> {
    let Ok(text) = crate::input::read_input(path) else {
        return Vec::new();
    };
    let Ok(raw) = serde_json::from_str::<serde_json::Value>(&text) else {
        return Vec::new();
    };
    // The mount-edge shape `ref_loading::inline_toplevel_refs` recognises: a
    // string `ref` and no inline `variables` (a model) or `species` (a reaction
    // system).
    [("models", "variables"), ("reaction_systems", "species")]
        .into_iter()
        .filter_map(|(block, inline_key)| {
            raw.get(block)
                .and_then(|v| v.as_object())
                .map(|systems| (systems, inline_key))
        })
        .flat_map(|(systems, inline_key)| {
            systems
                .iter()
                .filter(move |(_, m)| {
                    m.get("ref").is_some_and(serde_json::Value::is_string)
                        && m.get(inline_key).is_none()
                })
                .map(|(k, m)| {
                    let target = m.get("ref").and_then(|v| v.as_str()).unwrap_or("<ref>");
                    format!("{k} ← {target}")
                })
        })
        .collect()
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn run_test(
    paths: Vec<PathBuf>,
    model: Option<String>,
    filter: Option<String>,
    solver: SolverAlg,
    reltol: Option<f64>,
    abstol: Option<f64>,
    verbose: bool,
    compiler: Option<String>,
) -> Result<(), Box<dyn std::error::Error>> {
    // Refused before anything is discovered: a value outside the closed
    // vocabulary is `compiler_unknown` and says nothing about any document.
    let compiler = match compiler.as_deref() {
        None => None,
        Some(name) => Some(earthsci_ast::Compiler::parse_named(name).map_err(fail)?),
    };
    let files = discover_test_inputs(&paths)?;
    if files.is_empty() {
        // A mis-rooted invocation must not silently pass, but nor is finding
        // nothing a test failure: warn loudly and exit 0, as the Julia runner
        // does.
        let named: Vec<String> = paths.iter().map(|p| p.display().to_string()).collect();
        println!("⚠ No .esm files discovered under: {}", named.join(", "));
        return Ok(());
    }

    // Tolerances are NOT pinned here: they resolve per FILE, below, because
    // level 2 of the esm-spec §2.2.2 chain is the document's own `solver`
    // block and this command runs many documents.
    let opts = earthsci_ast::SolveOptions {
        alg: solver.into(),
        ..Default::default()
    };

    let mut rows: Vec<TestRow> = Vec::new();
    for path in &files {
        let first_row = rows.len();
        match earthsci_ast::load_path(path) {
            // A file that will not parse is one ERROR row, not a crash that
            // abandons the remaining files.
            Err(e) => rows.push(TestRow {
                file: path.clone(),
                container: "<parse>".to_string(),
                test_id: "<load>".to_string(),
                assertion_idx: 0,
                variable: String::new(),
                time: f64::NAN,
                verdict: Verdict::Error,
                message: format!("Parse failed: {e}"),
            }),
            Ok(esm_file) => {
                // The document's own `data_sources`, bound to real readers, and
                // every metaparameter one of them measures closed to the value
                // the DATA gave before any shape is taken from it.
                //
                // The providers are derived from the LOADED file rather than
                // from the file on disk so a §4.7 subsystem `ref` has already
                // been resolved and a mounted component's data bindings are
                // visible here.
                let ready = earthsci_ast::bind_data_sources(esm_file, &cache_root(), |mp| {
                    earthsci_ast::load_path_with_options(path, mp)
                });
                let (esm_file, providers) = match ready {
                    Ok(bound) => (bound.file, bound.providers),
                    Err(e) => {
                        rows.push(TestRow {
                            file: path.clone(),
                            container: "<data_sources>".to_string(),
                            test_id: "<ingest>".to_string(),
                            assertion_idx: 0,
                            variable: String::new(),
                            time: f64::NAN,
                            verdict: Verdict::Error,
                            message: e.0,
                        });
                        continue;
                    }
                };
                // `path.parent()` anchors §6.6.5 `from_file` references at the
                // document's own directory — the pinned cross-binding
                // convention, and the reason this loads with `load_path`
                // rather than `load_string` (only `load_path` resolves §4.7
                // subsystem `ref`s relative to the file).
                // `--filter` is applied INSIDE the runner, before anything is
                // built or solved, so narrowing to one test costs one test
                // rather than the whole document (it used to select rows out of
                // an already-evaluated `Vec`). The surviving rows are the same
                // either way: a result's `test_id` is its test's `id`.
                // esm-spec §2.2.2, resolved per file: an explicit `--reltol` /
                // `--abstol` wins, else this document's `solver` block, else
                // the runner defaults. The runner defaults sit at the BOTTOM of
                // the chain (they are binding defaults, not a caller's
                // opinion), which is what lets a stiff document ask for its own
                // integration accuracy without every invocation naming it.
                let file_opts = earthsci_ast::SolveOptions {
                    reltol: Some(
                        reltol
                            .or(esm_file.solver.as_ref().and_then(|s| s.reltol))
                            .unwrap_or(TEST_RELTOL),
                    ),
                    abstol: Some(
                        abstol
                            .or(esm_file.solver.as_ref().and_then(|s| s.abstol))
                            .unwrap_or(TEST_ABSTOL),
                    ),
                    ..opts.clone()
                };
                let results = earthsci_ast::run_inline_tests_with_options(
                    &esm_file,
                    &earthsci_ast::InlineTestOptions {
                        model_name: model.clone(),
                        solve: file_opts,
                        base_dir: path.parent().map(std::path::Path::to_path_buf),
                        test_filter: filter.clone(),
                        compiler,
                        providers,
                        ..Default::default()
                    },
                );
                for r in results {
                    rows.push(TestRow {
                        file: path.clone(),
                        container: r.model,
                        test_id: r.test_id,
                        assertion_idx: r.assertion_idx,
                        variable: r.variable,
                        time: r.time,
                        verdict: Verdict::of(r.passed, r.actual),
                        message: r.message,
                    });
                }
            }
        }
        if verbose {
            println!("{}", relative_to_cwd(path));
            for row in &rows[first_row..] {
                println!(
                    "  {:<5} {}/{}[{}] ({}@t={})",
                    row.verdict.label(),
                    row.container,
                    row.test_id,
                    row.assertion_idx,
                    row.variable,
                    julia_float(row.time),
                );
                if !row.message.is_empty() {
                    println!("        {}", row.message);
                }
            }
        }
    }

    print_test_summary(&files, &rows);
    if rows.iter().any(|r| r.verdict != Verdict::Pass) {
        return Err(fail_silent());
    }
    Ok(())
}

/// The per-file `pass | fail | err` table, its `TOTAL` row and the `Failures:`
/// block — a port of the Julia runner's `_print_summary`, so the two runners'
/// output can be read side by side.
pub(crate) fn print_test_summary(files: &[PathBuf], rows: &[TestRow]) {
    println!();
    println!("================ ESM inline-test summary ================");
    println!("Files discovered: {}", files.len());
    println!("Assertions:       {}", rows.len());

    // esm-spec §6.6: a mount does not carry the mounted component's inline
    // tests. Naming the mount edges keeps that VISIBLE — the reader sees which
    // components this run did not assert on, and where their assertions do run —
    // rather than losing them silently. Printed before the `rows.is_empty()`
    // exit, so a document that is nothing but mounts and coupling still says so.
    let mounts: Vec<(String, String)> = files
        .iter()
        .flat_map(|path| {
            let file = relative_to_cwd(path);
            mounted_components(path)
                .into_iter()
                .map(move |edge| (file.clone(), edge))
        })
        .collect();
    if !mounts.is_empty() {
        println!(
            "Mounted:          {} (esm-spec §6.6 — a mounted component's inline tests are not \
             run here; they run when its own file is a test target)",
            mounts.len()
        );
        for (file, edge) in &mounts {
            println!("  - {file} :: {edge}");
        }
    }

    if rows.is_empty() {
        println!("(no inline tests found)");
        println!("=========================================================");
        return;
    }

    let mut by_file: BTreeMap<String, [usize; 3]> = BTreeMap::new();
    let mut totals = [0usize; 3];
    for row in rows {
        by_file.entry(relative_to_cwd(&row.file)).or_default()[row.verdict.column()] += 1;
        totals[row.verdict.column()] += 1;
    }

    let pad = by_file
        .keys()
        .map(|name| name.chars().count())
        .max()
        .unwrap_or(20)
        .max(20);
    let rule = "-".repeat(pad + 25);
    println!(
        "  {:<pad$}  {:>5}  {:>5}  {:>5}",
        "file", "pass", "fail", "err"
    );
    println!("  {rule}");
    for (name, counts) in &by_file {
        println!(
            "  {:<pad$}  {:>5}  {:>5}  {:>5}",
            name, counts[0], counts[1], counts[2]
        );
    }
    println!("  {rule}");
    println!(
        "  {:<pad$}  {:>5}  {:>5}  {:>5}",
        "TOTAL", totals[0], totals[1], totals[2]
    );

    if totals[1] + totals[2] > 0 {
        println!();
        println!("Failures:");
        for row in rows.iter().filter(|r| r.verdict != Verdict::Pass) {
            println!(
                "  - {} :: {}/{}[{}] ({}@t={}) — {}",
                relative_to_cwd(&row.file),
                row.container,
                row.test_id,
                row.assertion_idx,
                row.variable,
                julia_float(row.time),
                row.verdict.label(),
            );
            if !row.message.is_empty() {
                println!("      {}", row.message);
            }
        }
    }
    println!("=========================================================");
}
