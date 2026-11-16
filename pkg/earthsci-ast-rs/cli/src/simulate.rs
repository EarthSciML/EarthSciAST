//! `esm simulate`: build and integrate a document, or evaluate one with
//! nothing to integrate, and write the result in the requested shape.

use std::fs;
use std::path::PathBuf;

use crate::args::SimulateFormat;
use crate::data_sources::close_declared_extents;
use crate::esm_impl::fail;
use crate::input::{load_at, read_input};

#[allow(clippy::too_many_arguments)]
pub(crate) fn run_simulate(
    file: PathBuf,
    time: f64,
    output: Option<PathBuf>,
    observed: Vec<String>,
    model: Option<String>,
    format: SimulateFormat,
    compiler: Option<String>,
    no_count_fold: bool,
    backend: Option<String>,
    integrator: crate::backend::IntegratorOptions,
) -> Result<(), Box<dyn std::error::Error>> {
    // Which time integrator, checked before anything is loaded: a name this
    // build lacks says nothing about the document. A build with no integrator
    // is refused only below, once the document turns out to integrate.
    let choice = crate::backend::choose(backend.as_deref(), &integrator).map_err(fail)?;
    // A value outside the closed vocabulary is `compiler_unknown` (esm-spec
    // §9.6.6) and is refused HERE, before anything is loaded: it is the one of
    // the three failures that says nothing about the document.
    let compiler = match compiler.as_deref() {
        None => None,
        Some(name) => Some(earthsci_ast::Compiler::parse_named(name).map_err(fail)?),
    };
    let content = read_input(&file)?;
    let esm_file = load_at(&file, &content)?;
    // A name the document does not declare is refused HERE, before anything
    // is ingested or evaluated.
    refuse_undeclared_observed(&esm_file, &observed)?;

    println!("Running simulation for: {}", file.display());
    println!("Simulation time: 0 → {time}");

    // RFC decision 8: the runner must EVALUATE and append a requested observed
    // before an output plan can find a slot for it, so the request travels with
    // the solve rather than being applied to the finished solution.
    let opts = earthsci_ast::SolveOptions {
        output_observed: observed.clone(),
        ..Default::default()
    };
    // The document's own `data_sources`, bound to real readers before anything
    // is evaluated. A document that declares data and cannot read it must stop
    // here: running on with every data-fed parameter at its `default` produces
    // a trajectory that looks like an answer and is not one.
    //
    // A FACTORY, because the build below may happen twice (`ProblemOptions`
    // consumes its providers by value). `close_declared_extents` also re-loads
    // the document with every metaparameter its sources measure closed, so an
    // index set sized by one is sized by the data rather than by the
    // declaration's placeholder default.
    let (esm_file, providers) = close_declared_extents(esm_file, |mp| {
        earthsci_ast::load_string_with_options(
            &content,
            &earthsci_ast::LoadOptions {
                base_path: file.parent().map(std::path::Path::to_path_buf),
                metaparameters: mp.clone(),
            },
        )
        .map_err(|e| format!("re-loading with the discovered source extents: {e}"))
    })
    .map_err(fail)?;
    let ingesting = providers.is_some();
    let mut rewrites = earthsci_ast::simulate_array::tape::CompilerRewrites::default();
    rewrites.count_fold = !no_count_fold;
    let build = |pipeline: bool| -> Result<earthsci_ast::EsmProblem, Box<dyn std::error::Error>> {
        let mut popts = earthsci_ast::ProblemOptions {
            // `Auto`, not `Always`. A document with no differential equations
            // has nothing to integrate, and compiling a right-hand side for it
            // anyway is what made this command die INSIDE THE SOLVER
            // ("Exceeded maximum number of nonlinear solver failures at
            // time = 0") on a document that evaluates perfectly well. `Auto`
            // gives it the static backend and the single evaluation below.
            rhs: earthsci_ast::Rhs::Auto,
            compiler,
            rewrites,
            model_name: model.clone(),
            build_pipeline: pipeline,
            // A data-fed parameter named by `--observed` is written from its
            // ingested values (finding F43); the rest are not kept.
            retain_data_fields: observed.clone(),
            // A document with nothing to integrate evaluates only what the
            // named fields need; omitted, it evaluates every observed.
            observed_cone: (!observed.is_empty()).then(|| observed.clone()),
            ..Default::default()
        };
        if let Some(make) = &providers {
            popts.build_providers = make()?;
            popts.build_pipeline = true;
        }
        earthsci_ast::esm_problem(&esm_file, (0.0, time), popts)
            .map_err(|e| fail(format!("problem build failed: {e}")))
    };

    let prob = build(false)?;
    // Filled only on the static path: `--format csv` writes from the FIELDS,
    // not from flattened cell keys.
    let mut evaluated: Vec<(String, ndarray::ArrayD<f64>)> = Vec::new();
    let sol = if prob.is_dynamic() {
        // The integrator reads the document itself and builds its own right-hand
        // side, so the options that steer `earthsci-ast`'s build and evaluation
        // would be silently ignored: refuse them instead. Only for a document that
        // integrates: a static one is evaluated by `earthsci-ast` whichever backend
        // was chosen, and takes them all.
        if choice == Some("integrator") {
            let ignored: Vec<&str> = [
                (!observed.is_empty(), "--observed"),
                (compiler.is_some(), "--compiler"),
                (no_count_fold, "--no-count-fold"),
            ]
            .into_iter()
            .filter_map(|(given, flag)| given.then_some(flag))
            .collect();
            if !ignored.is_empty() {
                return Err(fail(format!(
                    "{} {} the right-hand side `earthsci-ast` builds and the diffsol \
                     backend integrates; the integrator backend builds its own from \
                     the document and writes the state only",
                    ignored.join(", "),
                    if ignored.len() == 1 {
                        "configures"
                    } else {
                        "configure"
                    }
                )));
            }
        }
        let backend = crate::backend::select(choice, integrator).map_err(fail)?;
        // API_SPEC §5.8, "Every Problem reports what ran": one line, so a
        // number in the output below is tied to the way it was produced. Not
        // for the integrator, which never evaluates this Problem's right-hand
        // side: its report would describe a compiler that did not run.
        if backend.name() == "diffsol" {
            println!("{}", prob.compiler_report());
        }
        let sol = backend.simulate(&crate::backend::SimulateRun {
            file: &file,
            esm_file: &esm_file,
            prob: &prob,
            opts: &opts,
            tspan: (0.0, time),
        })?;
        println!(
            "✓ Simulation complete ({} backend): {} output points, alg {}, retcode {}",
            backend.name(),
            sol.time.len(),
            sol.metadata.alg,
            sol.retcode
        );
        sol
    } else {
        // A RELATIONAL document: it computes rows from rows and integrates
        // nothing. Its answers are the fields the build materialized, so it is
        // EVALUATED ONCE rather than solved.
        //
        // The first build already evaluated its observed graph on the named
        // compiler — the tape under `native` — and those fields are the
        // answer. Only when it produced none (a document the array runtime
        // cannot build on its own: value invention, a derived index set) is
        // the document rebuilt with the build pipeline on, and that rebuild is
        // under the named compiler like any other build: the pipeline reports
        // each observed it evaluates, and a strict compiler refuses one it
        // would have to walk per cell. A command that wrote an empty file
        // would be the silent-empty twin of the silent zero. The pipeline has
        // already run whenever the document ingests data. The report printed
        // is the one for the build whose fields are written.
        //
        // Some fields cannot mean "some are missing": the first build's
        // state-free evaluation is all or nothing (one stateless pass over
        // EVERY observed rule of the flattened system, or no fields at all),
        // and the pipeline evaluates a subset of those rules — one model's
        // observed definitions, value-invention assignments excluded.
        let prob = if ingesting || !prob.observed_fields().is_empty() {
            prob
        } else {
            build(true)?
        };
        println!("{}", prob.compiler_report());
        evaluated = static_fields(&prob, &observed)?;
        println!(
            "✓ Static evaluation complete: {} field(s). The document declares no \
             differential equations, so it was evaluated once rather than integrated.",
            evaluated.len()
        );
        static_solution(&evaluated)
    };
    if !sol.retcode.is_success() {
        println!(
            "⚠ The run did NOT reach t = {time}: it stopped at t = {} with retcode {}",
            sol.time.last().copied().unwrap_or(0.0),
            sol.retcode
        );
    }
    if let Some(&t_final) = sol.time.last() {
        println!("Final state at t = {t_final}:");
        for (name, series) in sol.state_variable_names.iter().zip(sol.state.iter()) {
            if let Some(v) = series.last() {
                println!("  {name} = {v}");
            }
        }
    }

    if let Some(output_path) = output {
        let out = match format {
            SimulateFormat::Flat => serde_json::json!({
                "time": sol.time,
                "state": sol.state,
                "state_variable_names": sol.state_variable_names,
                "alg": sol.metadata.alg,
                "retcode": sol.retcode.name(),
            }),
            SimulateFormat::Grid => gridded_results(&esm_file, &sol, &observed)?,
            SimulateFormat::Csv => {
                if evaluated.is_empty() {
                    return Err(fail(
                        "--format csv writes ONE row set, and this document integrates: \
                         its result is a trajectory. Use --format flat or --format grid.",
                    ));
                }
                write_csv_rows(&evaluated, &output_path)?;
                println!("Results written to: {}", output_path.display());
                return Ok(());
            }
        };
        // Streamed, and pretty so a 600k-cell field is one value per line and
        // `diff` against a reference dataset reports the cells that moved.
        let mut w = std::io::BufWriter::new(fs::File::create(&output_path)?);
        serde_json::to_writer_pretty(&mut w, &out)?;
        std::io::Write::write_all(&mut w, b"\n")?;
        std::io::Write::flush(&mut w)?;
        println!("Results written to: {}", output_path.display());
    }
    Ok(())
}

// =============================================================================
// Single evaluation of a document with nothing to integrate
// =============================================================================
//
// A MOVES-shaped calculator is a RELATIONAL document: every equation computes
// rows from rows and none of them is a `D(x)/dt`. Such a document evaluates
// correctly — `esm test` asserts on it — but until now there was no route from
// its computed rows to a file: `simulate --output` was the only subcommand that
// writes values, and it compiled a right-hand side for a system with nothing to
// integrate and then failed inside the solver. `info` reports structure, not
// values.
//
// These three functions are that route. They do not add a mode to the solver;
// they add a SINK to the evaluation the build pipeline already performs.

/// Refuse a `--observed` name that addresses no variable the document
/// declares.
///
/// A request is known unless CONFORMANCE_SPEC §5.17.4's output-request rule
/// finds it MISSING among the declared variables' qualified names (`Model.var`,
/// `Model.Sub.var`, reaction-system species and parameters included): the
/// exact name, or any whose last dotted segment it shares. The writers
/// resolve over a subset of those names by the same rule, so nothing they
/// would answer is refused here. An ambiguous name passes, and is reported
/// where it is resolved (`ambiguous_output_name`); so is a declared variable
/// the build does not materialize.
pub(crate) fn refuse_undeclared_observed(
    esm_file: &earthsci_ast::EsmFile,
    observed: &[String],
) -> Result<(), Box<dyn std::error::Error>> {
    use earthsci_ast::extension::data_output::{RequestMatch, match_output_request};
    if observed.is_empty() {
        return Ok(());
    }
    fn walk_subsystems(prefix: &str, subs: Option<&serde_json::Value>, out: &mut Vec<String>) {
        let Some(subs) = subs.and_then(|s| s.as_object()) else {
            return;
        };
        for (name, sub) in subs {
            let p = format!("{prefix}.{name}");
            for key in ["variables", "species", "parameters"] {
                if let Some(vars) = sub.get(key).and_then(|v| v.as_object()) {
                    out.extend(vars.keys().map(|v| format!("{p}.{v}")));
                }
            }
            walk_subsystems(&p, sub.get("subsystems"), out);
        }
    }
    let mut declared: Vec<String> = Vec::new();
    for (m, model) in esm_file.models.iter().flatten() {
        declared.extend(model.variables.keys().map(|v| format!("{m}.{v}")));
        let subs = model
            .subsystems
            .as_ref()
            .and_then(|s| serde_json::to_value(s).ok());
        walk_subsystems(m, subs.as_ref(), &mut declared);
    }
    for (r, rs) in esm_file.reaction_systems.iter().flatten() {
        declared.extend(rs.species.keys().map(|v| format!("{r}.{v}")));
        declared.extend(rs.parameters.keys().map(|v| format!("{r}.{v}")));
        let subs = rs
            .subsystems
            .as_ref()
            .and_then(|s| serde_json::to_value(s).ok());
        walk_subsystems(r, subs.as_ref(), &mut declared);
    }
    let candidates: Vec<&str> = declared.iter().map(String::as_str).collect();
    let unknown: Vec<&str> = observed
        .iter()
        .map(String::as_str)
        .filter(|n| matches!(match_output_request(n, &candidates), RequestMatch::Missing))
        .collect();
    if unknown.is_empty() {
        return Ok(());
    }
    Err(fail(format!(
        "--observed {}: the document declares no variable of that name, so \
         nothing was evaluated. Name a declared variable, bare (`var`) or \
         qualified (`Model.var`).",
        unknown
            .iter()
            .map(|n| format!("'{n}'"))
            .collect::<Vec<_>>()
            .join(", ")
    )))
}

/// The materialized static fields a run emits: one named column per field,
/// each an N-dimensional array.
pub(crate) type StaticFields = Vec<(String, ndarray::ArrayD<f64>)>;

/// The build-time fields to write, in the order they will be columns.
///
/// `observed` names them explicitly (the `--observed` flag); empty means every
/// field the build materialized. A named field that the build did not produce
/// is an ERROR that says so — never an omitted column, which a comparator would
/// read as a schema change rather than as a failure.
pub(crate) fn static_fields(
    prob: &earthsci_ast::EsmProblem,
    observed: &[String],
) -> Result<StaticFields, Box<dyn std::error::Error>> {
    let names: Vec<String> = if observed.is_empty() {
        prob.observed_field_names()
    } else {
        observed.to_vec()
    };
    if names.is_empty() {
        return Err(fail(
            "the document declares no differential equations and its build \
             materialized no fields, so there is nothing to write. Check that the \
             values you want are OBSERVED variables (an equation whose LHS is the \
             bare name), and that any `data_sources` they read were ingested.",
        ));
    }
    let mut out = Vec::with_capacity(names.len());
    for name in names {
        let arr = earthsci_ast::observed_field(prob, &name)
            .map_err(|e| fail(format!("evaluating '{name}': {e}")))?;
        out.push((name, arr));
    }
    Ok(out)
}

/// The single-record [`earthsci_ast::Solution`] the `flat` and `grid` writers
/// render, built from `fields`.
///
/// Cell keys are `name[i,j,…]`, 1-based and COLUMN-MAJOR — the identical
/// spelling the array runtime's own slot table gives a state variable, so
/// `derive_output_plan` grids these fields exactly as it grids a trajectory's.
pub(crate) fn static_solution(fields: &[(String, ndarray::ArrayD<f64>)]) -> earthsci_ast::Solution {
    let mut state_variable_names = Vec::new();
    let mut state = Vec::new();
    for (name, arr) in fields {
        let shape = arr.shape();
        if shape.is_empty() {
            state_variable_names.push(name.clone());
            state.push(vec![arr[ndarray::IxDyn(&[])]]);
            continue;
        }
        for flat in 0..arr.len() {
            let mut rem = flat;
            let mut idx = vec![0usize; shape.len()];
            for (d, dim) in shape.iter().enumerate() {
                idx[d] = rem % dim;
                rem /= dim;
            }
            let label = idx
                .iter()
                .map(|i| (i + 1).to_string())
                .collect::<Vec<_>>()
                .join(",");
            state_variable_names.push(format!("{name}[{label}]"));
            state.push(vec![arr[ndarray::IxDyn(&idx)]]);
        }
    }
    earthsci_ast::Solution {
        time: vec![0.0],
        state,
        state_variable_names,
        retcode: earthsci_ast::ReturnCode::Success,
        metadata: earthsci_ast::SolutionMetadata {
            alg: "static".to_string(),
            ..Default::default()
        },
    }
}

/// Write `fields` as one row per index tuple: `i1…in`, then one column per
/// field, in natural (row-major) reading order.
///
/// Every field must share one shape, because a row is one index tuple across
/// all of them — that is what makes the table a row set rather than several
/// unrelated arrays side by side. A mismatch names the shapes rather than
/// truncating or padding, and a rank-0 field is refused for the same reason: it
/// is one value, not a column. Select a consistent set with `--observed`.
pub(crate) fn write_csv_rows(
    fields: &[(String, ndarray::ArrayD<f64>)],
    path: &std::path::Path,
) -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Write;

    let shape = fields[0].1.shape().to_vec();
    if shape.is_empty() {
        return Err(fail(format!(
            "--format csv writes a ROW SET, and '{}' is a single value, not a column. \
             Name the row-shaped fields with --observed.",
            fields[0].0
        )));
    }
    if let Some((name, arr)) = fields.iter().find(|(_, a)| a.shape() != shape.as_slice()) {
        return Err(fail(format!(
            "--format csv writes ONE row set, so every written field must share a \
             shape: '{}' is {:?} but '{}' is {:?}. Name a consistent set with \
             --observed.",
            fields[0].0,
            shape,
            name,
            arr.shape()
        )));
    }

    let mut w = std::io::BufWriter::new(fs::File::create(path)?);
    let mut header: Vec<String> = (1..=shape.len()).map(|d| format!("i{d}")).collect();
    header.extend(fields.iter().map(|(n, _)| n.clone()));
    writeln!(w, "{}", header.join(","))?;

    let total: usize = shape.iter().product();
    let mut idx = vec![0usize; shape.len()];
    for _ in 0..total {
        let mut row: Vec<String> = idx.iter().map(|i| (i + 1).to_string()).collect();
        row.extend(
            fields
                .iter()
                .map(|(_, a)| format_csv_float(a[ndarray::IxDyn(&idx)])),
        );
        writeln!(w, "{}", row.join(","))?;
        // Row-major odometer: last axis fastest, so the file reads in the same
        // order as the nested arrays `--format grid` writes.
        for d in (0..shape.len()).rev() {
            idx[d] += 1;
            if idx[d] < shape[d] {
                break;
            }
            idx[d] = 0;
        }
    }
    w.flush()?;
    Ok(())
}

/// A float rendered for CSV without losing a bit: the shortest round-tripping
/// digits (a decimal tie takes the even last digit, as the other bindings
/// write it), laid out as std's `Display` lays them out (`100`, `0.25`), which
/// is what a comparator reading with `float()` needs. Non-finite values are
/// written as-is (`NaN`, `inf`) rather than blanked, so a wrong answer stays
/// visible instead of reading as missing.
pub(crate) fn format_csv_float(v: f64) -> String {
    earthsci_ast::extension::canonicalize::format_plain_float(v)
}

/// The `simulate --format grid` document: [`earthsci_ast::derive_output_plan`]
/// applied to the solution's own flat slot names, then filled.
///
/// The plan is the whole of the derivation — which variables are output, how
/// the flat column-major state inverts into row-major `[time, …spatial]`
/// arrays, what the axes are really called, and which CF coordinates and
/// attributes describe them — so this function only renders it. The rendering
/// is field-for-field `earthsciio::format::OutputSchema` (see
/// `tests/data_output_zarr_roundtrip.rs`, which builds exactly this from a
/// plan), so pointing the CLI at a real Zarr sink later is a swap of the
/// serializer, not of the derivation. It is deliberately NOT done here:
/// EarthSciIO is behind the opt-in `esio` feature, which raises the crate's
/// MSRV above its declared 1.89, and `esm` also builds without it.
pub(crate) fn gridded_results(
    esm_file: &earthsci_ast::EsmFile,
    sol: &earthsci_ast::Solution,
    observed: &[String],
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    // A `--observed` name an `operator_compose` renaming match DELETED addresses
    // a variable that MOVED (issue #230), and `derive_output_plan` sees only the
    // request and the slot names — so it would report the dead spelling as
    // unknown. The solution carries the merge's map for exactly this.
    let renames = &sol.metadata.merged_variable_renames;
    let resolved: Vec<String> = observed
        .iter()
        .map(|n| {
            renames
                .get(n.as_str())
                .cloned()
                .unwrap_or_else(|| n.clone())
        })
        .collect();
    let plan = earthsci_ast::derive_output_plan(esm_file, &sol.state_variable_names, &resolved)
        .map_err(|e| fail(format!("deriving the output plan: {e}")))?;

    let n_records = sol.time.len();
    let n_slots = sol.state.len();
    let mut grids = Vec::with_capacity(plan.grids.len());
    for grid in &plan.grids {
        // One buffer per variable, `[time, …spatial]` row-major, filled a whole
        // record at a time so the flat state is transposed once.
        let mut data: Vec<Vec<f64>> = grid
            .vars
            .iter()
            .map(|v| vec![0.0f64; n_records * v.values_per_record()])
            .collect();
        let mut flat = vec![0.0f64; n_slots];
        for r in 0..n_records {
            for (i, slot) in flat.iter_mut().enumerate() {
                *slot = sol.state[i][r];
            }
            for (v, buf) in grid.vars.iter().zip(data.iter_mut()) {
                v.gridding
                    .scatter_record(&flat, buf, r)
                    .map_err(|e| fail(format!("gridding '{}': {e}", v.name)))?;
            }
        }

        let mut dims = vec![serde_json::json!([grid.time_dim, n_records])];
        dims.extend(grid.dims.iter().map(|(n, l)| serde_json::json!([n, l])));

        let mut coords = vec![serde_json::json!({
            "name": grid.time_dim,
            "values": sol.time,
            "attrs": {},
        })];
        coords.extend(
            grid.coords.iter().map(
                |c| serde_json::json!({ "name": c.name, "values": c.values, "attrs": c.attrs }),
            ),
        );

        let vars: Vec<serde_json::Value> = grid
            .vars
            .iter()
            .zip(data)
            .map(|(v, buf)| {
                serde_json::json!({
                    "name": v.name,
                    "dims": v.dims,
                    "attrs": v.attrs,
                    "dtype": v.dtype,
                    "data": buf,
                })
            })
            .collect();

        grids.push(serde_json::json!({
            "dims": dims,
            "time_dim": grid.time_dim,
            "coords": coords,
            "vars": vars,
        }));
    }

    println!(
        "Output plan: {} grid(s), {} variable(s)",
        plan.grids.len(),
        plan.n_vars()
    );
    for grid in &plan.grids {
        let axes: Vec<String> = grid.dims.iter().map(|(n, l)| format!("{n}={l}")).collect();
        println!(
            "  [{}] {}",
            if axes.is_empty() {
                "scalar".to_string()
            } else {
                axes.join(", ")
            },
            grid.vars
                .iter()
                .map(|v| v.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }

    Ok(serde_json::json!({
        "alg": sol.metadata.alg,
        "retcode": sol.retcode.name(),
        "grids": grids,
    }))
}
