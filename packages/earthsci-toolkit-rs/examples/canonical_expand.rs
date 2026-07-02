//! canonical_expand — expand one `.esm` document through the raw §9.7
//! pipeline and emit the post-lowering document as canonical golden bytes.
//!
//! ```text
//! cargo run --example canonical_expand -- <input.esm> [--metaparameters N=8[,M=4…]]
//! ```
//!
//! The pipeline is the official one (`resolve_template_machinery` →
//! `lower_expression_templates`, the same pair the §9.7 conformance tests
//! drive), anchored at the input file's directory for relative import refs.
//! The output byte scheme is the Julia reference golden writer's
//! (`scripts/generate-template-import-goldens.jl`, reused by the
//! EarthSciDiscretizations runners): object keys sorted, arrays in order,
//! 2-space indent, trailing newline, and scalars exactly as JSON3 renders
//! them after `JSON3.read`'s numeric normalization — integral floats become
//! integers (`0.0` → `0`), non-integral floats print via Ryu shortest with
//! Julia's positional/scientific switch at `1e-5` / `1e6`.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::Path;
use std::process::ExitCode;

use earthsci_toolkit::lower_expression_templates::lower_expression_templates;
use earthsci_toolkit::template_imports::resolve_template_machinery;
use serde_json::Value;

/// Render a non-integral finite float exactly as Julia's `JSON3.write`
/// (Base.Ryu shortest digits; scientific iff the decimal exponent is < -4 or
/// >= 6; scientific mantissa always carries a fraction digit; exponent
/// unpadded, no `+`).
fn julia_float_repr(v: f64) -> Result<String, String> {
    if !v.is_finite() {
        return Err(format!("non-finite float {v} is not valid JSON"));
    }
    let s = format!("{:e}", v.abs()); // d[.ddd]e<exp>, shortest digits
    let (mant, exp) = s.split_once('e').ok_or("missing exponent")?;
    let e10: i64 = exp.parse().map_err(|e| format!("exponent parse: {e}"))?;
    let mut digits: String = mant.chars().filter(|c| *c != '.').collect();
    while digits.len() > 1 && digits.ends_with('0') {
        digits.pop();
    }
    let sign = if v < 0.0 { "-" } else { "" };
    if (-4..=5).contains(&e10) {
        // positional
        if e10 < 0 {
            let zeros = "0".repeat((-e10 - 1) as usize);
            return Ok(format!("{sign}0.{zeros}{digits}"));
        }
        let point = (e10 + 1) as usize;
        if digits.len() <= point {
            let zeros = "0".repeat(point - digits.len());
            return Ok(format!("{sign}{digits}{zeros}.0"));
        }
        return Ok(format!("{sign}{}.{}", &digits[..point], &digits[point..]));
    }
    let head = &digits[..1];
    let frac = if digits.len() > 1 { &digits[1..] } else { "0" };
    Ok(format!("{sign}{head}.{frac}e{e10}"))
}

fn scalar(v: &Value) -> Result<String, String> {
    match v {
        Value::Null => Ok("null".to_string()),
        Value::Bool(b) => Ok(b.to_string()),
        Value::String(s) => serde_json::to_string(s).map_err(|e| e.to_string()),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                return Ok(i.to_string());
            }
            if let Some(u) = n.as_u64() {
                return Ok(u.to_string());
            }
            let f = n.as_f64().ok_or("unrepresentable number")?;
            // JSON3.read numeric normalization: integral floats parse as Int64.
            if f == f.trunc() && f >= i64::MIN as f64 && f < i64::MAX as f64 {
                return Ok((f as i64).to_string());
            }
            julia_float_repr(f)
        }
        _ => Err("scalar() called on a container".to_string()),
    }
}

fn write_sorted(out: &mut String, v: &Value, indent: usize) -> Result<(), String> {
    let pad = "  ".repeat(indent);
    let pad1 = "  ".repeat(indent + 1);
    match v {
        Value::Object(map) => {
            if map.is_empty() {
                out.push_str("{}");
                return Ok(());
            }
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort(); // byte order == Unicode code-point order (§5.5.1)
            out.push_str("{\n");
            for (i, k) in keys.iter().enumerate() {
                let key = serde_json::to_string(k).map_err(|e| e.to_string())?;
                let _ = write!(out, "{pad1}{key}: ");
                write_sorted(out, &map[k.as_str()], indent + 1)?;
                out.push_str(if i + 1 < keys.len() { ",\n" } else { "\n" });
            }
            out.push_str(&pad);
            out.push('}');
        }
        Value::Array(items) => {
            if items.is_empty() {
                out.push_str("[]");
                return Ok(());
            }
            out.push_str("[\n");
            for (i, item) in items.iter().enumerate() {
                out.push_str(&pad1);
                write_sorted(out, item, indent + 1)?;
                out.push_str(if i + 1 < items.len() { ",\n" } else { "\n" });
            }
            out.push_str(&pad);
            out.push(']');
        }
        _ => out.push_str(&scalar(v)?),
    }
    Ok(())
}

fn canonical_bytes(doc: &Value) -> Result<String, String> {
    let mut out = String::new();
    write_sorted(&mut out, doc, 0)?;
    out.push('\n');
    Ok(out)
}

fn parse_metaparameters(spec: &str) -> Result<BTreeMap<String, i64>, String> {
    let mut out = BTreeMap::new();
    for pair in spec.split(',').filter(|p| !p.is_empty()) {
        let (name, value) = pair
            .split_once('=')
            .ok_or_else(|| format!("bad metaparameter '{pair}' (want name=int)"))?;
        let n: i64 = value
            .parse()
            .map_err(|e| format!("bad metaparameter value '{pair}': {e}"))?;
        out.insert(name.to_string(), n);
    }
    Ok(out)
}

fn run() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let mut input: Option<String> = None;
    let mut metaparameters = BTreeMap::new();
    while let Some(a) = args.next() {
        match a.as_str() {
            "--metaparameters" => {
                let spec = args.next().ok_or("--metaparameters needs a value")?;
                metaparameters = parse_metaparameters(&spec)?;
            }
            _ if input.is_none() => input = Some(a),
            _ => return Err(format!("unknown argument '{a}'")),
        }
    }
    let input = input.ok_or(
        "usage: canonical_expand <input.esm> [--metaparameters N=8[,M=4…]]",
    )?;
    let path = Path::new(&input);
    let text = std::fs::read_to_string(path).map_err(|e| format!("{input}: {e}"))?;
    let raw: Value = serde_json::from_str(&text).map_err(|e| format!("{input}: {e}"))?;
    let base = path.parent().unwrap_or_else(|| Path::new("."));
    let resolved = resolve_template_machinery(&raw, base, &metaparameters)
        .map_err(|e| format!("resolve_template_machinery: {e}"))?;
    let mut doc = resolved.unwrap_or(raw);
    lower_expression_templates(&mut doc)
        .map_err(|e| format!("lower_expression_templates: {e}"))?;
    print!("{}", canonical_bytes(&doc)?);
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}
