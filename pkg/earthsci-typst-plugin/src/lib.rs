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
    Alg, Compile, ProblemOptions, SolveOptions, esm_problem, load_string, parse_equation, solve,
    to_ascii, to_latex, to_unicode, validate as validate_file,
};
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

/// Parse one equation in the text syntax (`D(N, t) = -lambda*N`) and return
/// `{ascii, unicode, latex}` renderings of it.
#[wasm_func]
pub fn render_equation(text: &[u8]) -> Result<Vec<u8>, String> {
    let text = utf8(text, "equation")?;
    let eq = parse_equation(&text).map_err(|e| e.to_string())?;
    Ok(to_bytes(&json!({
        "ascii": format!("{} = {}", to_ascii(&eq.lhs), to_ascii(&eq.rhs)),
        "unicode": format!("{} = {}", to_unicode(&eq.lhs), to_unicode(&eq.rhs)),
        "latex": format!("{} = {}", to_latex(&eq.lhs), to_latex(&eq.rhs)),
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
            compile: Compile::Always,
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
