//! The earthsci-ast core as a Typst plugin.
//!
//! Every export takes and returns bytes, per the wasm-minimal-protocol: Typst
//! passes each argument as a `bytes` value, and a function either returns its
//! result or an error string that Typst shows at the call site. Structured
//! values travel as JSON, which `lib.typ` decodes with `json(bytes)`.
//!
//! Typst requires plugin functions to be pure, and memoizes their calls on the
//! argument bytes, so a document that calls `solve` with an unchanged model
//! does not re-integrate it.

use std::collections::HashMap;

use earthsci_ast::{
    Alg, DocumentFormat, ProblemOptions, Rhs, SolveOptions, esm_problem, expression_names,
    load_string, print_math, solve, validate as validate_file,
};
use earthsci_narrative::build::{BuildOptions, build_document, build_json, build_text};
use serde_json::{Value, json};
use wasm_minimal_protocol::*;

initiate_protocol!();

/// The getrandom 0.3 backend `.cargo/config.toml` selects.
///
/// Its only callers seed hash maps (ahash) and faer's random generator; none of
/// them needs unpredictable bytes. A fixed fill keeps every call reproducible,
/// which Typst's purity contract requires: the same arguments must give the
/// same result, however many calls came before.
///
/// # Safety
///
/// getrandom calls this with a valid, writable `dest` of `len` bytes.
#[unsafe(no_mangle)]
unsafe extern "Rust" fn __getrandom_v03_custom(
    dest: *mut u8,
    len: usize,
) -> Result<(), getrandom::Error> {
    // SAFETY: getrandom passes a valid, writable buffer of `len` bytes.
    unsafe { std::ptr::write_bytes(dest, 0x5a, len) };
    Ok(())
}

fn utf8(arg: &[u8], what: &str) -> Result<String, String> {
    String::from_utf8(arg.to_vec()).map_err(|e| format!("{what} is not UTF-8: {e}"))
}

fn to_bytes(value: &Value) -> Vec<u8> {
    serde_json::to_vec(value).expect("a serde_json::Value always serializes")
}

/// The crate version, so `lib.typ` can check it loaded the plugin it expects.
#[wasm_func]
pub fn version() -> Vec<u8> {
    env!("CARGO_PKG_VERSION").as_bytes().to_vec()
}

/// Render one expression, or one equation (an object with `lhs` and `rhs`),
/// given as its `.esm` JSON, and return `{latex, typst}`: the core's printers
/// (`earthsci_ast::print_math`), the math of the ESM Markdown and Typst
/// formats, with the expression's own names declared.
#[wasm_func]
pub fn render_equation(expr: &[u8]) -> Result<Vec<u8>, String> {
    let json: Value = serde_json::from_slice(expr).map_err(|e| format!("expression: {e}"))?;
    let names = expression_names(&json);
    Ok(to_bytes(&json!({
        "latex": print_math(&json, &names, DocumentFormat::Markdown),
        "typst": print_math(&json, &names, DocumentFormat::Typst),
    })))
}

/// Load an `.esm` document and return its validation result as JSON.
#[wasm_func]
pub fn validate(esm: &[u8]) -> Result<Vec<u8>, String> {
    let esm = utf8(esm, "document")?;
    let file = load_string(&esm).map_err(|e| format!("load error: {e}"))?;
    let result = validate_file(&file);
    serde_json::to_vec(&result).map_err(|e| e.to_string())
}

/// Solve an `.esm` document.
///
/// `opts` is a JSON object: `{t0, t_end, params?, ic?, alg?, reltol?, abstol?,
/// outputPoints?}`. Returns `{time, state, names, retcode, stats}`, where
/// `state[i][k]` is `names[i]` at `time[k]`.
#[wasm_func]
pub fn solve_esm(esm: &[u8], opts: &[u8]) -> Result<Vec<u8>, String> {
    let esm = utf8(esm, "document")?;
    let opts: Value = serde_json::from_slice(opts).map_err(|e| format!("options: {e}"))?;
    let num = |key: &str| opts.get(key).and_then(Value::as_f64);
    let t0 = num("t0").unwrap_or(0.0);
    let t_end = num("t_end").ok_or("options: `t_end` is required")?;
    let bindings = |key: &str| -> Result<HashMap<String, f64>, String> {
        match opts.get(key) {
            None | Some(Value::Null) => Ok(HashMap::new()),
            Some(v) => serde_json::from_value(v.clone()).map_err(|e| format!("options.{key}: {e}")),
        }
    };

    let file = load_string(&esm).map_err(|e| format!("load error: {e}"))?;
    let prob = esm_problem(
        &file,
        (t0, t_end),
        ProblemOptions {
            p: bindings("params")?,
            u0: bindings("ic")?,
            rhs: Rhs::Always,
            ..Default::default()
        },
    )
    .map_err(|e| format!("problem build error: {e}"))?;

    let mut solve_opts = SolveOptions::default();
    if let Some(name) = opts.get("alg").and_then(Value::as_str) {
        solve_opts.alg = Alg::from_name(name).ok_or_else(|| format!("unknown alg `{name}`"))?;
    }
    solve_opts.reltol = num("reltol");
    solve_opts.abstol = num("abstol");
    if let Some(n) = opts.get("outputPoints").and_then(Value::as_u64) {
        solve_opts.sample_evenly(t0, t_end, n as usize);
    }

    let sol = solve(&prob, &solve_opts).map_err(|e| format!("solve error: {e}"))?;
    Ok(to_bytes(&json!({
        "time": sol.time,
        "state": sol.state,
        "names": sol.state_variable_names,
        "retcode": sol.retcode.name(),
        "stats": {
            "rhsCalls": sol.metadata.n_rhs_calls,
            "jacobianCalls": sol.metadata.n_jacobian_calls,
            "acceptedSteps": sol.metadata.n_accepted_steps,
            "rejectedSteps": sol.metadata.n_rejected_steps,
        },
    })))
}

/// The narrative build options from the plugin's JSON options:
/// `{run_tests?, run_analyses?, render_svg?, points?, width?, height?}`.
fn build_options(opts: &Value) -> BuildOptions {
    let flag = |key: &str, default: bool| opts.get(key).and_then(Value::as_bool).unwrap_or(default);
    let mut build_opts = BuildOptions {
        run_tests: flag("run_tests", true),
        run_analyses: flag("run_analyses", true),
        render_svg: flag("render_svg", true),
        ..Default::default()
    };
    if let Some(n) = opts.get("points").and_then(Value::as_u64) {
        build_opts.run.points = n as usize;
    }
    if let Some(w) = opts.get("width").and_then(Value::as_f64) {
        build_opts.svg.width = w;
    }
    if let Some(h) = opts.get("height").and_then(Value::as_f64) {
        build_opts.svg.height = h;
    }
    build_opts
}

/// Build a narrative document in the element format: element JSON in, the
/// narrative `BuildOutput` JSON out (the assembled `.esm`, diagnostics, and one
/// output per element — math, test results, figures).
///
/// `opts` is a JSON object: `{run_tests?, run_analyses?, render_svg?, points?,
/// width?, height?}`, all optional. Problems in the document are diagnostics in
/// the output, never a plugin error, so the document can show them in place.
#[wasm_func]
pub fn build(doc: &[u8], opts: &[u8]) -> Result<Vec<u8>, String> {
    let doc = utf8(doc, "document")?;
    let opts: Value = serde_json::from_slice(opts).map_err(|e| format!("options: {e}"))?;
    let out = build_json(&doc, &build_options(&opts));
    serde_json::to_vec(&out).map_err(|e| e.to_string())
}

/// Build an `.esm` document: its text in, the narrative `BuildOutput` JSON
/// out (validation, the results of its tests, its figures, under
/// `constructs` by JSON pointer).
///
/// The text is read by the core as `opts.format`: `"typst"` (the default; a
/// Typst document can pass its own source, `read("model.typ")`), `"markdown"`,
/// or `"json"`. The other options are [`build`]'s. A text the core refuses is
/// a diagnostic in the output, never a plugin error.
#[wasm_func]
pub fn build_document_text(text: &[u8], opts: &[u8]) -> Result<Vec<u8>, String> {
    let text = utf8(text, "document")?;
    let opts: Value = serde_json::from_slice(opts).map_err(|e| format!("options: {e}"))?;
    let build_opts = build_options(&opts);
    let out = match opts
        .get("format")
        .and_then(Value::as_str)
        .unwrap_or("typst")
    {
        "typst" => build_text(&text, DocumentFormat::Typst, &build_opts),
        "markdown" => build_text(&text, DocumentFormat::Markdown, &build_opts),
        "json" => {
            let esm: Value = serde_json::from_str(&text).map_err(|e| format!("document: {e}"))?;
            build_document(esm, &build_opts)
        }
        other => {
            return Err(format!(
                "unknown format `{other}` (expected typst, markdown or json)"
            ));
        }
    };
    serde_json::to_vec(&out).map_err(|e| e.to_string())
}
