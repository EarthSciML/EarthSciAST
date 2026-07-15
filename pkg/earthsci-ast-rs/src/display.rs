//! Display formatting implementations for ESM expressions, models, and files
//!
//! This module implements `std::fmt::Display` and other formatting functions
//! for expressions with Unicode mathematical notation, chemical subscripts,
//! LaTeX output, and summary displays for models and reaction systems.

use crate::types::*;
use std::fmt;

// Element table - periodic table symbols for chemical subscript detection
const ELEMENTS: &[&str; 118] = &[
    "H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P", "S", "Cl",
    "Ar", "K", "Ca", "Sc", "Ti", "V", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Ga", "Ge", "As",
    "Se", "Br", "Kr", "Rb", "Sr", "Y", "Zr", "Nb", "Mo", "Tc", "Ru", "Rh", "Pd", "Ag", "Cd", "In",
    "Sn", "Sb", "Te", "I", "Xe", "Cs", "Ba", "La", "Ce", "Pr", "Nd", "Pm", "Sm", "Eu", "Gd", "Tb",
    "Dy", "Ho", "Er", "Tm", "Yb", "Lu", "Hf", "Ta", "W", "Re", "Os", "Ir", "Pt", "Au", "Hg", "Tl",
    "Pb", "Bi", "Po", "At", "Rn", "Fr", "Ra", "Ac", "Th", "Pa", "U", "Np", "Pu", "Am", "Cm", "Bk",
    "Cf", "Es", "Fm", "Md", "No", "Lr", "Rf", "Db", "Sg", "Bh", "Hs", "Mt", "Ds", "Rg", "Cn", "Nh",
    "Fl", "Mc", "Lv", "Ts", "Og",
];

// Unicode subscript digits
const UNICODE_SUBSCRIPTS: [char; 10] = ['₀', '₁', '₂', '₃', '₄', '₅', '₆', '₇', '₈', '₉'];

// Unicode superscript digits
const UNICODE_SUPERSCRIPTS: [char; 10] = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];

// Operator precedence levels (higher = tighter binding)
const PRECEDENCE: &[(&str, i32)] = &[("+", 1), ("-", 1), ("*", 2), ("/", 2), ("^", 3)];

/// Get operator precedence (higher means tighter binding)
fn get_precedence(op: &str) -> i32 {
    for (operator, prec) in PRECEDENCE {
        if operator == &op {
            return *prec;
        }
    }
    0 // Default for unknown operators
}

/// Convert a string with chemical subscripts and Greek letters to Unicode
fn format_chemical_subscripts(s: &str) -> String {
    // Handle Greek letter conversions first
    let greek_converted = match s {
        "alpha" => "α",
        "beta" => "β",
        "gamma" => "γ",
        "delta" => "δ",
        "epsilon" => "ε",
        "zeta" => "ζ",
        "eta" => "η",
        "theta" => "θ",
        "iota" => "ι",
        "kappa" => "κ",
        "lambda" => "λ",
        "mu" => "μ",
        "nu" => "ν",
        "xi" => "ξ",
        "omicron" => "ο",
        "pi" => "π",
        "rho" => "ρ",
        "sigma" => "σ",
        "tau" => "τ",
        "upsilon" => "υ",
        "phi" => "φ",
        "chi" => "χ",
        "psi" => "ψ",
        "omega" => "ω",
        _ => s,
    };

    // If we converted to a Greek letter, return it
    if greek_converted != s {
        return greek_converted.to_string();
    }

    // Peel a trailing ionic charge (`Ca2+`, `SO4-2`) so its magnitude renders
    // as a SUPERSCRIPT (`Ca²⁺`, `SO₄²⁻`) rather than an atom-count subscript.
    let (body, charge) = split_charge(s);

    let mut result = String::new();
    let chars: Vec<char> = body.chars().collect();
    let mut i = 0;

    while i < chars.len() {
        let ch = chars[i];

        if ch.is_alphabetic() {
            // Try to match 2-letter element symbol first
            if i + 1 < chars.len() {
                let two_letter = format!("{}{}", ch, chars[i + 1]);
                if ELEMENTS.contains(&two_letter.as_str()) {
                    result.push_str(&two_letter);
                    i += 2;

                    // Convert following digits to subscripts
                    while i < chars.len() && chars[i].is_ascii_digit() {
                        let digit = chars[i].to_digit(10).unwrap();
                        result.push(UNICODE_SUBSCRIPTS[digit as usize]);
                        i += 1;
                    }
                    continue;
                }
            }

            // Try 1-letter element symbol
            if ELEMENTS.contains(&ch.to_string().as_str()) {
                result.push(ch);
                i += 1;

                // Convert following digits to subscripts
                while i < chars.len() && chars[i].is_ascii_digit() {
                    let digit = chars[i].to_digit(10).unwrap();
                    result.push(UNICODE_SUBSCRIPTS[digit as usize]);
                    i += 1;
                }
                continue;
            }

            // Not an element symbol, just add the character
            result.push(ch);
            i += 1;
        } else {
            // A group-count after a closing bracket subscripts too (`Ca(OH)2`
            // → `Ca(OH)₂`); every other non-element character is copied as-is.
            result.push(ch);
            i += 1;
            if ch == ')' || ch == ']' {
                while i < chars.len() && chars[i].is_ascii_digit() {
                    let digit = chars[i].to_digit(10).unwrap();
                    result.push(UNICODE_SUBSCRIPTS[digit as usize]);
                    i += 1;
                }
            }
        }
    }

    result.push_str(&to_superscript_str(&charge));
    result
}

/// Split off a trailing ionic charge suffix, returning `(body, charge)` where
/// `charge` is the raw magnitude-then-sign string (`"2+"`, `"2-"`) — the caller
/// renders it as a superscript (Unicode `²⁺` via `to_superscript_str`, or LaTeX
/// `^{2+}`). Empty `charge` when no sign is present or the remaining body is not
/// a chemical formula, so ordinary identifiers are untouched. Input `2+` and
/// `-2` after a chemical body both normalize to `"2+"` / `"2-"`.
fn split_charge(s: &str) -> (&str, String) {
    let last = match s.chars().last() {
        Some(c) => c,
        None => return (s, String::new()),
    };
    // digits-then-sign, e.g. "Ca2+"
    if last == '+' || last == '-' {
        let without_sign = &s[..s.len() - 1];
        let mag: String = without_sign
            .chars()
            .rev()
            .take_while(|c| c.is_ascii_digit())
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        let body = &without_sign[..without_sign.len() - mag.len()];
        if !mag.is_empty() && is_chemical_formula(body) {
            return (body, format!("{mag}{last}"));
        }
    }
    // sign-then-digits, e.g. "SO4-2"
    if last.is_ascii_digit() {
        let mag: String = s
            .chars()
            .rev()
            .take_while(|c| c.is_ascii_digit())
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        let before = &s[..s.len() - mag.len()];
        if let Some(sign) = before.chars().last()
            && (sign == '+' || sign == '-')
        {
            let body = &before[..before.len() - 1];
            if is_chemical_formula(body) {
                return (body, format!("{mag}{sign}"));
            }
        }
    }
    (s, String::new())
}

/// Backend-independent pieces of a formatted floating-point number.
///
/// The Unicode, LaTeX, and ASCII printers previously each hand-rolled the
/// 0.0 special case, integer collapse, trailing-zero trimming, and
/// scientific-notation cutoffs — with slightly divergent orderings. They now
/// share `format_display_float` and differ only in how they render the
/// exponent (Unicode superscripts, LaTeX `\times 10^{...}`, ASCII `e`).
enum FloatParts {
    /// Rendered verbatim in every backend (e.g. "0", "42", "3.15").
    Plain(String),
    /// Scientific notation, e.g. mantissa "1.8" with exponent "-12". The
    /// mantissa always carries at least one decimal digit ("1" -> "1.0") and
    /// the exponent has no leading `+` (matching tests/display goldens).
    Scientific { mantissa: String, exponent: String },
    /// `+inf` (`false`) / `-inf` (`true`).
    Inf(bool),
    /// Not-a-number.
    NaN,
}

// Scientific-notation cutoffs (esm-spec §6.1 / RENDERING_CONTRACT.md "Number
// formatting"): a nonzero magnitude below the min or at/above the max renders
// in scientific notation, in EVERY backend and for integers alike.
const SCI_NOTATION_MIN: f64 = 0.01;
const SCI_NOTATION_MAX: f64 = 10000.0;

/// Shared float-formatting core for all three expression printers. Integer and
/// float leaves both flow through here so a magnitude like `15000` renders as
/// `1.5×10⁴` regardless of which JSON token produced it.
fn format_display_float(n: f64) -> FloatParts {
    if n.is_nan() {
        return FloatParts::NaN;
    }
    if n.is_infinite() {
        return FloatParts::Inf(n < 0.0);
    }
    // Zero prints as a bare "0" (never "0.0"), in every backend.
    if n == 0.0 {
        return FloatParts::Plain("0".to_string());
    }

    let abs_n = n.abs();
    if !(SCI_NOTATION_MIN..SCI_NOTATION_MAX).contains(&abs_n) {
        // Rust's `{:e}` yields the shortest round-tripping mantissa with no
        // precision loss (e.g. 0.009999 -> "9.999e-3") and an exponent with no
        // leading `+`, matching the normative number-formatting contract.
        let sci = format!("{n:e}");
        if let Some(e_pos) = sci.find('e') {
            let mut mantissa = sci[..e_pos].to_string();
            // Ensure at least one decimal place: "1" -> "1.0", "8.64" stays.
            if !mantissa.contains('.') {
                mantissa.push_str(".0");
            }
            return FloatParts::Scientific {
                mantissa,
                exponent: sci[e_pos + 1..].to_string(),
            };
        }
        return FloatParts::Plain(sci);
    }

    // Integers in normal range display without a decimal point.
    if n.fract() == 0.0 {
        return FloatParts::Plain(format!("{}", n as i64));
    }

    // In-range fractional value: shortest round-tripping decimal, no rounding.
    FloatParts::Plain(format!("{n}"))
}

/// Replace a leading ASCII hyphen with the Unicode U+2212 MINUS SIGN (used by
/// the Unicode number printer for both the mantissa and plain values).
fn unicode_minus(s: String) -> String {
    match s.strip_prefix('-') {
        Some(rest) => format!("−{rest}"),
        None => s,
    }
}

/// Unicode number rendering (U+2212 minus, superscript exponent, `∞`/`NaN`).
fn format_number_unicode(n: f64) -> String {
    match format_display_float(n) {
        FloatParts::Plain(s) => unicode_minus(s),
        FloatParts::Scientific { mantissa, exponent } => {
            format!(
                "{}×10{}",
                unicode_minus(mantissa),
                to_superscript_str(&exponent)
            )
        }
        FloatParts::Inf(neg) => if neg { "−∞" } else { "∞" }.to_string(),
        FloatParts::NaN => "NaN".to_string(),
    }
}

/// LaTeX number rendering (`\times 10^{…}`, `\infty`/`\text{NaN}`).
fn format_number_latex(n: f64) -> String {
    match format_display_float(n) {
        FloatParts::Plain(s) => s,
        FloatParts::Scientific { mantissa, exponent } => {
            format!("{mantissa} \\times 10^{{{exponent}}}")
        }
        FloatParts::Inf(neg) => if neg { "-\\infty" } else { "\\infty" }.to_string(),
        FloatParts::NaN => "\\text{NaN}".to_string(),
    }
}

/// ASCII number rendering (`mantissa e exp`, no `+` on a positive exponent).
fn format_number_ascii(n: f64) -> String {
    match format_display_float(n) {
        FloatParts::Plain(s) => s,
        FloatParts::Scientific { mantissa, exponent } => format!("{mantissa}e{exponent}"),
        FloatParts::Inf(neg) => if neg { "-inf" } else { "inf" }.to_string(),
        FloatParts::NaN => "NaN".to_string(),
    }
}

/// Render a non-finite value carried as a JSON *string* token (`"Infinity"`,
/// `"-Infinity"`, `"NaN"`) — JSON cannot encode these as numbers, so the corpus
/// smuggles them through as variable names. Returns `None` for any ordinary
/// identifier. See RENDERING_CONTRACT.md "Number formatting".
fn nonfinite_string(name: &str, fmt: Fmt) -> Option<String> {
    let n = match name {
        "Infinity" => f64::INFINITY,
        "-Infinity" => f64::NEG_INFINITY,
        "NaN" => f64::NAN,
        _ => return None,
    };
    Some(match fmt {
        Fmt::Unicode => format_number_unicode(n),
        Fmt::Latex => format_number_latex(n),
        Fmt::Ascii => format_number_ascii(n),
    })
}

impl fmt::Display for Expr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_unicode())
    }
}

impl Expr {
    /// Convert expression to Unicode mathematical notation
    pub fn to_unicode(&self) -> String {
        self.to_unicode_with_precedence(0)
    }

    fn to_unicode_with_precedence(&self, parent_prec: i32) -> String {
        match self {
            // Integers and floats share one formatter so a large-magnitude
            // integer (e.g. 15000) renders as scientific `1.5×10⁴` too.
            Expr::Number(n) => format_number_unicode(*n),
            Expr::Integer(n) => format_number_unicode(*n as f64),
            Expr::Variable(name) => nonfinite_string(name, Fmt::Unicode)
                .unwrap_or_else(|| format_chemical_subscripts(name)),
            Expr::Operator(node) => format_operator_unicode(node, parent_prec),
        }
    }
}

/// Render a call-shaped form `op_symbol(arg1, arg2, ...)`.
///
/// Dozens of match arms and every `_` fallback across the three printers
/// previously hand-rolled this exact shape; they share this helper instead.
/// `render` supplies the backend-specific argument rendering (typically at
/// precedence 0, since the parentheses already delimit the arguments).
fn call_form(op_symbol: &str, args: &[Expr], render: impl Fn(&Expr) -> String) -> String {
    format!(
        "{}({})",
        op_symbol,
        args.iter().map(render).collect::<Vec<_>>().join(", ")
    )
}

/// The three text-rendering backends. Shared by the structural / array-query
/// op renderer so it can produce all three formats from one code path (the
/// scalar-op dispatch keeps three separate functions for readability).
#[derive(Clone, Copy, PartialEq, Eq)]
enum Fmt {
    Unicode,
    Latex,
    Ascii,
}

/// Render a sub-expression in the requested backend at outer precedence.
fn render_fmt(expr: &Expr, fmt: Fmt) -> String {
    match fmt {
        Fmt::Unicode => to_unicode(expr),
        Fmt::Latex => to_latex(expr),
        Fmt::Ascii => to_ascii(expr),
    }
}

/// Render an operator node as a scalar expression in the requested backend
/// (used by `broadcast`, which renders identically to its elementwise `fn`).
fn render_operator(node: &ExpressionNode, fmt: Fmt) -> String {
    match fmt {
        Fmt::Unicode => format_operator_unicode(node, 0),
        Fmt::Latex => format_operator_latex(node, 0),
        Fmt::Ascii => format_operator_ascii(node, 0),
    }
}

/// Escape LaTeX-special underscores in a bare operator / identifier name.
fn latex_name(name: &str) -> String {
    name.replace('_', "\\_")
}

/// The integer value of an exponent literal, if it is one (used to pick
/// Unicode-superscript rendering for `x^n`).
fn integer_exponent(e: &Expr) -> Option<i64> {
    match e {
        Expr::Integer(n) => Some(*n),
        Expr::Number(n) if n.fract() == 0.0 => Some(*n as i64),
        _ => None,
    }
}

/// Convert a decimal integer string to Unicode superscript characters.
fn to_superscript_str(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '0'..='9' => UNICODE_SUPERSCRIPTS[c.to_digit(10).unwrap() as usize],
            '-' => '⁻',
            '+' => '⁺',
            other => other,
        })
        .collect()
}

/// Replace Unicode Greek characters with their ASCII names (e.g. `θ` → `theta`)
/// for the ASCII backend. Non-Greek characters pass through unchanged.
fn greek_to_ascii(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        let name = match c {
            'α' => "alpha",
            'β' => "beta",
            'γ' => "gamma",
            'δ' => "delta",
            'ε' => "epsilon",
            'ζ' => "zeta",
            'η' => "eta",
            'θ' => "theta",
            'ι' => "iota",
            'κ' => "kappa",
            'λ' => "lambda",
            'μ' => "mu",
            'ν' => "nu",
            'ξ' => "xi",
            'ο' => "omicron",
            'π' => "pi",
            'ρ' => "rho",
            'σ' => "sigma",
            'τ' => "tau",
            'υ' => "upsilon",
            'φ' => "phi",
            'χ' => "chi",
            'ψ' => "psi",
            'ω' => "omega",
            other => {
                out.push(other);
                continue;
            }
        };
        out.push_str(name);
    }
    out
}

/// LaTeX command for a variable name that is exactly a Greek letter, given
/// either as a spelled name (`"phi"`) or a single Unicode character (`"θ"`).
/// Returns `None` for any non-Greek identifier.
fn greek_to_latex(name: &str) -> Option<&'static str> {
    let cmd = match name {
        "alpha" | "α" => "\\alpha",
        "beta" | "β" => "\\beta",
        "gamma" | "γ" => "\\gamma",
        "delta" | "δ" => "\\delta",
        "epsilon" | "ε" => "\\epsilon",
        "zeta" | "ζ" => "\\zeta",
        "eta" | "η" => "\\eta",
        "theta" | "θ" => "\\theta",
        "iota" | "ι" => "\\iota",
        "kappa" | "κ" => "\\kappa",
        "lambda" | "λ" => "\\lambda",
        "mu" | "μ" => "\\mu",
        "nu" | "ν" => "\\nu",
        "xi" | "ξ" => "\\xi",
        "omicron" | "ο" => "\\omicron",
        "pi" | "π" => "\\pi",
        "rho" | "ρ" => "\\rho",
        "sigma" | "σ" => "\\sigma",
        "tau" | "τ" => "\\tau",
        "upsilon" | "υ" => "\\upsilon",
        "phi" | "φ" => "\\phi",
        "chi" | "χ" => "\\chi",
        "psi" | "ψ" => "\\psi",
        "omega" | "ω" => "\\omega",
        "Gamma" => "\\Gamma",
        "Delta" => "\\Delta",
        "Theta" => "\\Theta",
        "Lambda" => "\\Lambda",
        "Xi" => "\\Xi",
        "Pi" => "\\Pi",
        "Sigma" => "\\Sigma",
        "Upsilon" => "\\Upsilon",
        "Phi" => "\\Phi",
        "Psi" => "\\Psi",
        "Omega" => "\\Omega",
        _ => return None,
    };
    Some(cmd)
}

/// The raw identifier string carried by a leaf expression (used by `enum`,
/// whose members are bare `Type`/`Member` names, not rendered sub-expressions).
fn expr_raw_string(e: &Expr) -> String {
    match e {
        Expr::Variable(s) => s.clone(),
        Expr::Integer(n) => n.to_string(),
        Expr::Number(n) => n.to_string(),
        Expr::Operator(node) => node.op.clone(),
    }
}

/// Parenthesize a sub-expression only when it is an operator node (used by
/// `index` / `transpose`, whose base is bracketed rather than call-wrapped).
fn wrap_if_op(expr: &Expr, fmt: Fmt) -> String {
    let s = render_fmt(expr, fmt);
    if matches!(expr, Expr::Operator(_)) {
        format!("({s})")
    } else {
        s
    }
}

/// Render a sub-expression at a specific parent precedence in the given backend.
fn render_at(expr: &Expr, fmt: Fmt, prec: i32) -> String {
    match fmt {
        Fmt::Unicode => expr.to_unicode_with_precedence(prec),
        Fmt::Latex => to_latex_prec(expr, prec),
        Fmt::Ascii => to_ascii_prec(expr, prec),
    }
}

/// Render one operand of an associative n-ary operator (`+`, `*`). A child that
/// is the SAME operator is not self-parenthesized, so `(a+b)+c` prints
/// `a + b + c` and `(a·b)·c` prints `a·b·c`; every other child uses the normal
/// precedence threshold (so `(a+b)·c` and `a·(b/c)` keep their parentheses).
fn render_assoc_operand(expr: &Expr, parent_op: &str, op_prec: i32, fmt: Fmt) -> String {
    let prec = match expr {
        Expr::Operator(n) if n.op == parent_op => 0,
        _ => op_prec,
    };
    render_at(expr, fmt, prec)
}

/// A binary `+` whose right operand is a unary minus renders as a subtraction
/// (`a + (−b)` → `a − b`); returns the rendered string when this applies.
fn sum_as_difference(args: &[Expr], op_prec: i32, fmt: Fmt) -> Option<String> {
    if args.len() != 2 {
        return None;
    }
    let Expr::Operator(n) = &args[1] else {
        return None;
    };
    if n.op != "-" || n.args.len() != 1 {
        return None;
    }
    let minus = if fmt == Fmt::Unicode { "−" } else { "-" };
    Some(format!(
        "{} {minus} {}",
        render_assoc_operand(&args[0], "+", op_prec, fmt),
        render_at(&n.args[0], fmt, op_prec + 1)
    ))
}

/// True when a LaTeX product has a direct operand that is a variable NAME
/// already carrying a command backslash (e.g. `\mathrm{O_3}`); such products
/// render by juxtaposition (a space) rather than with `\cdot`. Mirrors the
/// `latexSep` decision in pretty-print.ts.
fn latex_mul_juxtapose(args: &[Expr]) -> bool {
    args.iter()
        .any(|a| matches!(a, Expr::Variable(v) if v.contains('\\')))
}

/// Render a `const` node's literal JSON value (scalar number or nested array).
/// Integer JSON tokens print as plain integers (so `const 0` is `0`, not
/// `0.0`); float tokens use the backend's number formatting.
fn format_const_value(value: &serde_json::Value, fmt: Fmt) -> String {
    match value {
        serde_json::Value::Array(arr) => {
            let inner = arr
                .iter()
                .map(|v| format_const_value(v, fmt))
                .collect::<Vec<_>>()
                .join(", ");
            format!("[{inner}]")
        }
        serde_json::Value::Number(num) => {
            if let Some(i) = num.as_i64() {
                i.to_string()
            } else if let Some(u) = num.as_u64() {
                u.to_string()
            } else if let Some(f) = num.as_f64() {
                match fmt {
                    Fmt::Unicode => format_number_unicode(f),
                    Fmt::Latex => format_number_latex(f),
                    Fmt::Ascii => format_number_ascii(f),
                }
            } else {
                num.to_string()
            }
        }
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Bool(b) => b.to_string(),
        other => other.to_string(),
    }
}

/// Stringify a scalar JSON value (e.g. a `table_lookup` `output` selector).
fn json_scalar_string(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::Bool(b) => b.to_string(),
        other => other.to_string(),
    }
}

/// Big-operator symbol for an `aggregate` reduction (semiring supersedes the
/// bare `reduce`). See tests/display/RENDERING_CONTRACT.md.
fn aggregate_symbol(semiring: Option<&str>, reduce: &str, fmt: Fmt) -> &'static str {
    enum Fam {
        Plus,
        Times,
        Max,
        Min,
        Bool,
    }
    let fam = if let Some(sr) = semiring {
        match sr {
            "max_product" | "max_sum" => Fam::Max,
            "min_sum" => Fam::Min,
            "bool_and_or" => Fam::Bool,
            _ => Fam::Plus,
        }
    } else {
        match reduce {
            "*" => Fam::Times,
            "max" => Fam::Max,
            "min" => Fam::Min,
            _ => Fam::Plus,
        }
    };
    let (u, l, a) = match fam {
        Fam::Plus => ("Σ", "\\sum", "sum"),
        Fam::Times => ("Π", "\\prod", "prod"),
        Fam::Max => ("max", "\\max", "max"),
        Fam::Min => ("min", "\\min", "min"),
        Fam::Bool => ("⋁", "\\bigvee", "any"),
    };
    match fmt {
        Fmt::Unicode => u,
        Fmt::Latex => l,
        Fmt::Ascii => a,
    }
}

/// Render one range entry (`[a,b]` → `a:b`, index-set ref → `name(of…)`).
fn format_range_spec(rng: &RangeSpec) -> String {
    match rng {
        RangeSpec::Interval(iv) => format!("{}:{}", iv[0], iv[1]),
        RangeSpec::Strided(iv) => format!("{}:{}:{}", iv[0], iv[1], iv[2]),
        RangeSpec::IndexSetRef { from, of } => match of {
            Some(of) if !of.is_empty() => format!("{}({})", from, of.join(", ")),
            _ => from.clone(),
        },
        RangeSpec::RaggedDyn { offsets, of } => format!("{}({})", offsets, of.join(", ")),
        RangeSpec::DerivedDyn { from_faq } => from_faq.clone(),
    }
}

/// Render the ` where {…}` range clause shared by aggregate and argmin/argmax
/// (keys sorted for determinism).
fn format_ranges_clause(ranges: &std::collections::HashMap<String, RangeSpec>, fmt: Fmt) -> String {
    let in_sym = match fmt {
        Fmt::Latex => " \\in ",
        Fmt::Unicode => "∈",
        Fmt::Ascii => " in ",
    };
    let mut keys: Vec<&String> = ranges.keys().collect();
    keys.sort();
    let parts = keys
        .iter()
        .map(|k| format!("{}{}{}", k, in_sym, format_range_spec(&ranges[*k])))
        .collect::<Vec<_>>()
        .join(", ");
    match fmt {
        Fmt::Latex => format!(" \\text{{ where }} \\{{{parts}\\}}"),
        _ => format!(" where {{{parts}}}"),
    }
}

/// Render an `aggregate` node per tests/display/RENDERING_CONTRACT.md §aggregate.
fn format_aggregate(node: &ExpressionNode, fmt: Fmt) -> String {
    let out_idx = node
        .output_idx
        .as_ref()
        .map(|v| v.join(", "))
        .unwrap_or_default();
    let expr_str = node
        .expr
        .as_deref()
        .map(|e| render_fmt(e, fmt))
        .unwrap_or_default();
    let semiring = node.semiring.as_deref();
    let reduce = node.reduce.as_deref().unwrap_or("+");
    let sym = aggregate_symbol(semiring, reduce, fmt);
    let idx_part = if fmt == Fmt::Latex {
        format!("_{{{out_idx}}}")
    } else {
        format!("[{out_idx}]")
    };
    let mut out = format!("{sym}{idx_part} ({expr_str})");
    if let Some(ranges) = &node.ranges
        && !ranges.is_empty()
    {
        out.push_str(&format_ranges_clause(ranges, fmt));
    }
    if let Some(join) = &node.join
        && !join.is_empty()
    {
        let clauses = join
            .iter()
            .map(|c| {
                c.on
                    .iter()
                    .map(|p| format!("{}={}", p[0], p[1]))
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .collect::<Vec<_>>()
            .join("; ");
        out.push_str(&format!(" join({clauses})"));
    }
    if let Some(filter) = node.filter.as_deref() {
        out.push_str(&format!(" if {}", render_fmt(filter, fmt)));
    }
    if node.distinct == Some(true) {
        out.push_str(" distinct");
    }
    if let Some(key) = node.key.as_deref() {
        out.push_str(&format!(" key={}", render_fmt(key, fmt)));
    }
    if let Some(sr) = semiring
        && sr != "sum_product"
    {
        out.push_str(&format!(" [semiring={sr}]"));
    }
    out
}

/// Render an `argmin` / `argmax` arg-witness node.
fn format_arg_witness(node: &ExpressionNode, fmt: Fmt) -> String {
    let arg = node.arg.as_deref().unwrap_or("");
    let expr_str = node
        .expr
        .as_deref()
        .map(|e| render_fmt(e, fmt))
        .unwrap_or_default();
    let idx_part = if fmt == Fmt::Latex {
        format!("_{{{arg}}}")
    } else {
        format!("[{arg}]")
    };
    let name = if fmt == Fmt::Latex {
        format!("\\mathrm{{{}}}", node.op)
    } else {
        node.op.clone()
    };
    let mut out = format!("{name}{idx_part} ({expr_str})");
    if let Some(ranges) = &node.ranges
        && !ranges.is_empty()
    {
        out.push_str(&format_ranges_clause(ranges, fmt));
    }
    out
}

/// Render the closed-core structural / array-query ops (esm-spec §4.2), whose
/// defining data lives in fields OTHER than `args`, plus `integral`. Returns a
/// fully-formatted string, or `None` for ops handled by the scalar-op dispatch
/// (arithmetic, elementary functions, comparisons, `D`, `Pre`, …) or by the
/// generic fallback (open-tier sugar `grad`/`div`/`laplacian`, unknown user
/// ops). Mirrors `formatStructuralOp` in pretty-print.ts.
fn format_structural_op(node: &ExpressionNode, fmt: Fmt) -> Option<String> {
    let op = node.op.as_str();
    let args = node.args.as_slice();
    let eq = if fmt == Fmt::Latex { " = " } else { "=" };

    match op {
        "const" => Some(format_const_value(
            node.value.as_ref().unwrap_or(&serde_json::Value::Null),
            fmt,
        )),

        "true" => Some("true".to_string()),

        "fn" => {
            let name = node.name.as_deref().unwrap_or("");
            let inner = args
                .iter()
                .map(|a| render_fmt(a, fmt))
                .collect::<Vec<_>>()
                .join(", ");
            Some(match fmt {
                Fmt::Latex => format!("\\mathrm{{{}}}({})", latex_name(name), inner),
                _ => format!("{name}({inner})"),
            })
        }

        "enum" => {
            let a0 = args.first().map(expr_raw_string).unwrap_or_default();
            let a1 = args.get(1).map(expr_raw_string).unwrap_or_default();
            let label = format!("{a0}.{a1}");
            Some(match fmt {
                Fmt::Latex => format!("\\mathrm{{{}}}", latex_name(&label)),
                _ => label,
            })
        }

        "index" => {
            if args.is_empty() {
                return None;
            }
            let idx = args[1..]
                .iter()
                .map(|a| render_fmt(a, fmt))
                .collect::<Vec<_>>()
                .join(", ");
            Some(format!("{}[{}]", wrap_if_op(&args[0], fmt), idx))
        }

        "broadcast" => {
            let fn_name = node.broadcast_fn.as_deref()?;
            let synth = ExpressionNode {
                op: fn_name.to_string(),
                args: node.args.clone(),
                ..Default::default()
            };
            Some(render_operator(&synth, fmt))
        }

        "integral" => {
            if args.is_empty() {
                return None;
            }
            let f = render_fmt(&args[0], fmt);
            let v = node.int_var.as_deref().unwrap_or("x");
            let lo = node
                .lower
                .as_deref()
                .map(|e| render_fmt(e, fmt))
                .unwrap_or_default();
            let hi = node
                .upper
                .as_deref()
                .map(|e| render_fmt(e, fmt))
                .unwrap_or_default();
            Some(match fmt {
                Fmt::Latex => format!("\\int_{{{lo}}}^{{{hi}}} {f} \\, d{v}"),
                Fmt::Unicode => format!("∫[{lo}, {hi}] {f} d{v}"),
                Fmt::Ascii => format!("integral({f}, {v}, {lo}, {hi})"),
            })
        }

        "table_lookup" => {
            let table = node.table.as_deref().unwrap_or("");
            let bindings = node
                .axes
                .as_ref()
                .map(|axes| {
                    let mut keys: Vec<&String> = axes.keys().collect();
                    keys.sort();
                    keys.iter()
                        .map(|k| format!("{}{}{}", k, eq, render_fmt(&axes[*k], fmt)))
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            let out_str = match &node.output {
                Some(v) if !v.is_null() => format!(":{}", json_scalar_string(v)),
                _ => String::new(),
            };
            let name = if fmt == Fmt::Latex {
                format!("\\mathrm{{{}}}", latex_name(table))
            } else {
                table.to_string()
            };
            Some(format!("{name}[{bindings}]{out_str}"))
        }

        "apply_expression_template" => {
            let name = node.name.as_deref().unwrap_or("");
            let inner = node
                .bindings
                .as_ref()
                .map(|b| {
                    let mut keys: Vec<&String> = b.keys().collect();
                    keys.sort();
                    keys.iter()
                        .map(|k| format!("{}{}{}", k, eq, render_fmt(&b[*k], fmt)))
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            Some(match fmt {
                Fmt::Latex => format!("\\mathrm{{{}}}\\langle {} \\rangle", latex_name(name), inner),
                Fmt::Unicode => format!("{name}⟨{inner}⟩"),
                Fmt::Ascii => format!("{name}<{inner}>"),
            })
        }

        "makearray" => {
            let values = node.values.as_ref();
            let parts = node
                .regions
                .as_ref()
                .map(|regions| {
                    regions
                        .iter()
                        .enumerate()
                        .map(|(i, region)| {
                            let reg_str = region
                                .iter()
                                .map(|dim| format!("{}:{}", dim[0], dim[1]))
                                .collect::<Vec<_>>()
                                .join(", ");
                            let val = values
                                .and_then(|vs| vs.get(i))
                                .map(|v| render_fmt(v, fmt))
                                .unwrap_or_else(|| "?".to_string());
                            format!("[{reg_str}] = {val}")
                        })
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            let name = if fmt == Fmt::Latex {
                "\\mathrm{makearray}"
            } else {
                "makearray"
            };
            Some(format!("{name}({parts})"))
        }

        "reshape" => {
            if args.is_empty() {
                return None;
            }
            let shape = node
                .shape
                .as_ref()
                .map(|s| {
                    s.iter()
                        .map(|x| x.to_string())
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            let name = if fmt == Fmt::Latex {
                "\\mathrm{reshape}"
            } else {
                "reshape"
            };
            Some(format!("{}({}, [{}])", name, render_fmt(&args[0], fmt), shape))
        }

        "transpose" => {
            if args.is_empty() {
                return None;
            }
            if let Some(perm) = &node.perm
                && !perm.is_empty()
            {
                let p = perm
                    .iter()
                    .map(|x| x.to_string())
                    .collect::<Vec<_>>()
                    .join(", ");
                let name = if fmt == Fmt::Latex {
                    "\\mathrm{transpose}"
                } else {
                    "transpose"
                };
                return Some(format!("{}({}, [{}])", name, render_fmt(&args[0], fmt), p));
            }
            let a = wrap_if_op(&args[0], fmt);
            Some(match fmt {
                Fmt::Latex => format!("{a}^{{T}}"),
                Fmt::Unicode => format!("{a}ᵀ"),
                Fmt::Ascii => format!("transpose({})", render_fmt(&args[0], fmt)),
            })
        }

        "concat" => {
            let inner = args
                .iter()
                .map(|a| render_fmt(a, fmt))
                .collect::<Vec<_>>()
                .join(", ");
            let name = if fmt == Fmt::Latex {
                "\\mathrm{concat}"
            } else {
                "concat"
            };
            let axis = node.axis.unwrap_or(0);
            Some(format!("{name}({inner}, axis={axis})"))
        }

        "intersect_polygon" | "polygon_intersection_area" => {
            let inner = args
                .iter()
                .map(|a| render_fmt(a, fmt))
                .collect::<Vec<_>>()
                .join(", ");
            let name = if fmt == Fmt::Latex {
                format!("\\mathrm{{{}}}", latex_name(op))
            } else {
                op.to_string()
            };
            let manifold = node.manifold.as_deref().unwrap_or("");
            Some(format!("{name}({inner}, manifold={manifold})"))
        }

        "aggregate" => Some(format_aggregate(node, fmt)),

        "argmin" | "argmax" => Some(format_arg_witness(node, fmt)),

        _ => None,
    }
}

fn format_operator_unicode(node: &ExpressionNode, parent_prec: i32) -> String {
    // Closed-core structural / array-query ops (and `integral`) render from
    // their non-`args` fields and are never parenthesized by precedence.
    if let Some(s) = format_structural_op(node, Fmt::Unicode) {
        return s;
    }

    let op = node.op.as_str();
    let args = node.args.as_slice();
    let wrt = &node.wrt;
    let op_prec = get_precedence(op);
    let needs_parens = op_prec > 0 && op_prec <= parent_prec;
    // Renders an argument at precedence 0 (used inside delimited contexts).
    let r0 = |arg: &Expr| arg.to_unicode_with_precedence(0);

    let result = match op {
        "+" => {
            if let Some(s) = sum_as_difference(args, op_prec, Fmt::Unicode) {
                s
            } else if args.len() >= 2 {
                args.iter()
                    .map(|arg| render_assoc_operand(arg, "+", op_prec, Fmt::Unicode))
                    .collect::<Vec<_>>()
                    .join(" + ")
            } else {
                call_form("+", args, r0)
            }
        }
        "-" => {
            if args.len() == 1 {
                format!("−{}", args[0].to_unicode_with_precedence(op_prec))
            } else if args.len() == 2 {
                // Left-associative: the right operand renders at op_prec + 1
                // so `a − (b − c)` keeps its parentheses.
                format!(
                    "{} − {}",
                    args[0].to_unicode_with_precedence(op_prec),
                    args[1].to_unicode_with_precedence(op_prec + 1)
                )
            } else {
                call_form("−", args, r0)
            }
        }
        "*" => {
            if args.len() >= 2 {
                args.iter()
                    .map(|arg| render_assoc_operand(arg, "*", op_prec, Fmt::Unicode))
                    .collect::<Vec<_>>()
                    .join("·")
            } else {
                call_form("·", args, r0)
            }
        }
        "/" => {
            if args.len() == 2 {
                // The left operand of a left-associative `/` only needs parens
                // when it binds *strictly* looser (op_prec - 1), so `a·b/c`
                // stays unparenthesized while `(a + b)/c` does not.
                format!(
                    "{}/{}",
                    args[0].to_unicode_with_precedence(op_prec - 1),
                    args[1].to_unicode_with_precedence(op_prec + 1)
                )
            } else {
                call_form("÷", args, r0)
            }
        }
        "^" => {
            if args.len() == 2 {
                // Integer exponents render as Unicode superscripts.
                if let Some(n) = integer_exponent(&args[1]) {
                    format!(
                        "{}{}",
                        args[0].to_unicode_with_precedence(op_prec),
                        to_superscript_str(&n.to_string())
                    )
                } else {
                    format!(
                        "{}^{}",
                        args[0].to_unicode_with_precedence(op_prec),
                        args[1].to_unicode_with_precedence(op_prec + 1)
                    )
                }
            } else {
                call_form("^", args, r0)
            }
        }
        "D" => {
            // Derivative operator; the operand is parenthesized when it is an
            // operator node (`∂(x + y)/∂t`, never `∂x + y/∂t`).
            if let (Some(wrt_var), [arg]) = (wrt, args) {
                format!(
                    "∂{}/∂{}",
                    wrap_if_op(arg, Fmt::Unicode),
                    format_chemical_subscripts(wrt_var)
                )
            } else {
                call_form("D", args, r0)
            }
        }
        ">" => {
            if args.len() == 2 {
                format!("{} > {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form(">", args, r0)
            }
        }
        "<" => {
            if args.len() == 2 {
                format!("{} < {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("<", args, r0)
            }
        }
        ">=" => {
            if args.len() == 2 {
                format!("{} ≥ {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form(">=", args, r0)
            }
        }
        "<=" => {
            if args.len() == 2 {
                format!("{} ≤ {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("<=", args, r0)
            }
        }
        "=" | "==" => {
            if args.len() == 2 {
                format!("{} = {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("=", args, r0)
            }
        }
        "!=" => {
            if args.len() == 2 {
                format!("{} ≠ {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("!=", args, r0)
            }
        }
        "and" => {
            if args.len() >= 2 {
                args.iter().map(r0).collect::<Vec<_>>().join(" ∧ ")
            } else {
                call_form("and", args, r0)
            }
        }
        "or" => {
            if args.len() >= 2 {
                args.iter().map(r0).collect::<Vec<_>>().join(" ∨ ")
            } else {
                call_form("or", args, r0)
            }
        }
        "not" => {
            if args.len() == 1 {
                // Add parentheses for complex expressions
                if matches!(&args[0], Expr::Operator(_)) {
                    format!("¬({})", r0(&args[0]))
                } else {
                    format!("¬{}", r0(&args[0]))
                }
            } else {
                call_form("not", args, r0)
            }
        }
        "log" => {
            if args.len() == 1 {
                call_form("ln", args, r0)
            } else {
                call_form("log", args, r0)
            }
        }
        "log10" => {
            if args.len() == 1 {
                call_form("log₁₀", args, r0)
            } else {
                call_form("log10", args, r0)
            }
        }
        "sqrt" => {
            if let [arg] = args {
                // Parenthesize a compound radicand for clarity.
                if matches!(arg, Expr::Operator(_)) {
                    format!("√({})", r0(arg))
                } else {
                    format!("√{}", r0(arg))
                }
            } else {
                call_form("sqrt", args, r0)
            }
        }
        "asin" => {
            if args.len() == 1 {
                call_form("arcsin", args, r0)
            } else {
                call_form("asin", args, r0)
            }
        }
        "acos" => {
            if args.len() == 1 {
                call_form("arccos", args, r0)
            } else {
                call_form("acos", args, r0)
            }
        }
        "atan" => {
            if args.len() == 1 {
                call_form("arctan", args, r0)
            } else {
                call_form("atan", args, r0)
            }
        }
        "abs" => {
            if args.len() == 1 {
                format!("|{}|", r0(&args[0]))
            } else {
                call_form("abs", args, r0)
            }
        }
        "sign" => call_form("sgn", args, r0),
        "floor" => {
            if args.len() == 1 {
                format!("⌊{}⌋", r0(&args[0]))
            } else {
                call_form("floor", args, r0)
            }
        }
        "ceil" => {
            if args.len() == 1 {
                format!("⌈{}⌉", r0(&args[0]))
            } else {
                call_form("ceil", args, r0)
            }
        }
        "asinh" => {
            if args.len() == 1 {
                call_form("sinh⁻¹", args, r0)
            } else {
                call_form("asinh", args, r0)
            }
        }
        "acosh" => {
            if args.len() == 1 {
                call_form("cosh⁻¹", args, r0)
            } else {
                call_form("acosh", args, r0)
            }
        }
        "atanh" => {
            if args.len() == 1 {
                call_form("tanh⁻¹", args, r0)
            } else {
                call_form("atanh", args, r0)
            }
        }
        // `Pre` renders as a call form, matching the cross-language contract.
        "Pre" => call_form("Pre", args, r0),
        // Genuinely call-shaped operators (exp, ifelse, min/max, trig,
        // hyperbolics, atan2, ...) and unknown operators (including the
        // open-tier rewrite-target sugar grad/div/laplacian).
        _ => call_form(op, args, r0),
    };

    if needs_parens {
        format!("({result})")
    } else {
        result
    }
}

/// Convert an expression to Unicode mathematical notation
pub fn to_unicode(expr: &Expr) -> String {
    expr.to_unicode()
}

/// Convert an expression to LaTeX notation
pub fn to_latex(expr: &Expr) -> String {
    to_latex_prec(expr, 0)
}

/// LaTeX rendering with the parent operator's precedence threaded through.
///
/// The LaTeX printer previously ignored precedence entirely, so `(a+b)*c`
/// rendered as the mathematically wrong `a + b \cdot c`; it now applies the
/// same parenthesization rule as the reference Unicode printer.
fn to_latex_prec(expr: &Expr, parent_prec: i32) -> String {
    match expr {
        Expr::Integer(n) => format_number_latex(*n as f64),
        Expr::Number(n) => format_number_latex(*n),
        Expr::Variable(name) => {
            nonfinite_string(name, Fmt::Latex).unwrap_or_else(|| format_variable_latex(name))
        }
        Expr::Operator(node) => format_operator_latex(node, parent_prec),
    }
}

fn format_variable_latex(name: &str) -> String {
    // A name that is already LaTeX passes through verbatim.
    if is_preformatted_latex(name) {
        return name.to_string();
    }
    // A variable that is exactly a Greek letter renders as its LaTeX command.
    if let Some(cmd) = greek_to_latex(name) {
        return cmd.to_string();
    }
    format_chemical_latex(name)
}

/// True when a variable NAME is already hand-written LaTeX and must be emitted
/// verbatim (mirrors `isPreformattedLatex` in pretty-print.ts): a `\mathrm{…}`
/// atom, a bare command like `\theta` (a backslash with no brace), or a subscript
/// atom like `k_{NO_O3}` (braces without a leading `\command{…}`). A braced
/// `\command{…}` such as `\mathbf{v}` is NOT pre-formatted — it still takes the
/// generic `\mathrm{…}` wrap.
fn is_preformatted_latex(v: &str) -> bool {
    if v.starts_with("\\mathrm{") {
        return true;
    }
    if v.contains('\\') {
        return !v.contains('{');
    }
    v.contains('{') || v.contains('}')
}

/// True when `variable` (underscores ignored) is PURELY a chemical formula: at
/// least one element symbol and no non-element letters. Uses the same greedy
/// 2-char-before-1-char element tokenizer as `scanElements` in pretty-print.ts.
fn has_element_pattern(variable: &str) -> bool {
    let chars: Vec<char> = variable.chars().filter(|&c| c != '_').collect();
    let mut has_element = false;
    let mut i = 0;
    while i < chars.len() {
        let mut sym_len = 0;
        if i + 1 < chars.len() {
            let two: String = [chars[i], chars[i + 1]].iter().collect();
            if ELEMENTS.contains(&two.as_str()) {
                sym_len = 2;
            }
        }
        if sym_len == 0 && ELEMENTS.contains(&chars[i].to_string().as_str()) {
            sym_len = 1;
        }
        if sym_len > 0 {
            has_element = true;
            i += sym_len;
            while i < chars.len() && chars[i].is_ascii_digit() {
                i += 1;
            }
        } else {
            // A non-element letter means this is not a pure chemical formula.
            if chars[i].is_ascii_alphabetic() {
                return false;
            }
            i += 1;
        }
    }
    has_element
}

/// Convert every digit run in a formula to a LaTeX subscript (`H2O` → `H_2O`,
/// `C12` → `C_{12}`), WITHOUT the `\mathrm{}` wrapper.
fn latex_chemical_inner(formula: &str) -> String {
    let chars: Vec<char> = formula.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_ascii_digit() {
            let mut digits = String::new();
            while i < chars.len() && chars[i].is_ascii_digit() {
                digits.push(chars[i]);
                i += 1;
            }
            if digits.chars().count() == 1 {
                out.push('_');
                out.push_str(&digits);
            } else {
                out.push_str(&format!("_{{{digits}}}"));
            }
        } else {
            out.push(chars[i]);
            i += 1;
        }
    }
    out
}

/// Peel one leading `\mathrm{` and one trailing `}` (independently).
fn strip_outer_mathrm(s: &str) -> String {
    let inner = s.strip_prefix("\\mathrm{").unwrap_or(s);
    inner.strip_suffix('}').unwrap_or(inner).to_string()
}

/// Split a variable into a non-element prefix + element-bearing suffix
/// (`jNO2` → `("j","NO2")`, `k_NO_O3` → `("k","NO_O3")`), or `None`.
fn get_chemical_suffix(variable: &str) -> Option<(String, String)> {
    if variable.contains('_') {
        let parts: Vec<&str> = variable.split('_').collect();
        if parts.len() == 2 && has_element_pattern(parts[1]) && !has_element_pattern(parts[0]) {
            return Some((parts[0].to_string(), parts[1].to_string()));
        }
        if parts.len() == 3 {
            let suffix = parts[1..].join("_");
            if has_element_pattern(&suffix) && !has_element_pattern(parts[0]) {
                return Some((parts[0].to_string(), suffix));
            }
        }
    }
    let chars: Vec<char> = variable.chars().collect();
    for i in 1..chars.len() {
        let prefix: String = chars[..i].iter().collect();
        let suffix: String = chars[i..].iter().collect();
        if has_element_pattern(&suffix) && !has_element_pattern(&prefix) {
            return Some((prefix, suffix));
        }
    }
    None
}

/// Inner content of an element-bearing suffix embedded in a larger variable's
/// subscript (the text INSIDE the enclosing `\mathrm{...}`).
fn format_chemical_suffix_inner(variable: &str) -> String {
    if get_chemical_suffix(variable).is_some() {
        return strip_outer_mathrm(&format_chemical_latex(variable));
    }
    if ELEMENTS.contains(&variable) && !variable.chars().any(|c| c.is_ascii_digit()) {
        return variable.to_string();
    }
    latex_chemical_inner(variable)
}

/// Match a single-letter-then-digits variable (`x1`, `T298`) → `(letter, digits)`.
fn single_letter_digits(name: &str) -> Option<(String, String)> {
    let chars: Vec<char> = name.chars().collect();
    if chars.len() >= 2
        && chars[0].is_ascii_alphabetic()
        && chars[1..].iter().all(|c| c.is_ascii_digit())
    {
        return Some((chars[0].to_string(), chars[1..].iter().collect()));
    }
    None
}

fn is_chemical_formula(s: &str) -> bool {
    if s.is_empty() {
        return false;
    }

    // Check if starts with an element symbol (uppercase letter)
    let first_char = s.chars().next().unwrap();
    if !first_char.is_ascii_uppercase() {
        return false;
    }

    // Try to find a matching element symbol at the start
    if s.len() >= 2 {
        let two_letter = &s[..2];
        if ELEMENTS.contains(&two_letter) {
            return true;
        }
    }

    let one_letter = &s[..1];
    ELEMENTS.contains(&one_letter)
}

/// LaTeX chemical/variable subscript formatting (mirrors `formatChemicalLatex`
/// in pretty-print.ts). Greek and raw-LaTeX names are handled by the caller.
fn format_chemical_latex(variable: &str) -> String {
    // A trailing ionic charge is a superscript, not a subscript
    // (`Ca2+` → `Ca^{2+}`, `SO4-2` → `\mathrm{SO_4}^{2-}`).
    let (charge_body, charge) = split_charge(variable);
    if !charge.is_empty() {
        return format!("{}^{{{charge}}}", format_chemical_latex(charge_body));
    }

    // Mixed variable: non-element prefix + element-bearing suffix.
    if let Some((prefix, suffix)) = get_chemical_suffix(variable) {
        let prefix_multi = prefix.chars().count() > 1;
        if suffix.contains('_') {
            let segments: Vec<&str> = suffix.split('_').collect();
            // Split into per-segment subscripts when the first segment is a
            // complete formula (ends in a digit) or the prefix is multi-char;
            // otherwise the whole suffix stays one `\mathrm{...}` block.
            let should_split =
                segments[0].chars().last().is_some_and(|c| c.is_ascii_digit()) || prefix_multi;
            if should_split {
                let mut result = if prefix_multi {
                    format!("\\mathrm{{{prefix}}}")
                } else {
                    prefix.clone()
                };
                for seg in &segments {
                    if has_element_pattern(seg) {
                        result.push_str(&format!("_{{\\mathrm{{{}}}}}", latex_chemical_inner(seg)));
                    } else {
                        result.push_str(&format!("_\\mathrm{{{seg}}}"));
                    }
                }
                return result;
            }
        }
        let inner = format_chemical_suffix_inner(&suffix);
        let formatted_prefix = if prefix_multi {
            format!("\\mathrm{{{prefix}}}")
        } else {
            prefix
        };
        return format!("{formatted_prefix}_{{\\mathrm{{{inner}}}}}");
    }

    if has_element_pattern(variable) {
        // A bare element symbol without digits (e.g. "C", "Ca") is a variable.
        if ELEMENTS.contains(&variable) && !variable.chars().any(|c| c.is_ascii_digit()) {
            return variable.to_string();
        }
        // Pure chemical formula: digit runs → subscripts, wrapped in `\mathrm`.
        return format!("\\mathrm{{{}}}", latex_chemical_inner(variable));
    }

    // Regular (non-chemical) variable.
    if let Some((letter, digits)) = single_letter_digits(variable) {
        return if digits.chars().count() == 1 {
            format!("{letter}_{digits}")
        } else {
            format!("{letter}_{{{digits}}}")
        };
    }
    if variable.chars().count() == 1 {
        return variable.to_string();
    }
    if variable.contains('_') {
        let parts: Vec<&str> = variable.split('_').collect();
        if parts.iter().any(|p| has_element_pattern(p)) {
            let base = parts[0];
            let mut result = if base.chars().count() == 1 && base.chars().all(|c| c.is_ascii_alphabetic())
            {
                base.to_string()
            } else if has_element_pattern(base) {
                format_chemical_latex(base)
            } else {
                format!("\\mathrm{{{base}}}")
            };
            for part in &parts[1..] {
                if has_element_pattern(part) {
                    result.push_str(&format!("_{{\\mathrm{{{}}}}}", latex_chemical_inner(part)));
                } else {
                    result.push_str(&format!("_\\mathrm{{{part}}}"));
                }
            }
            return result;
        }
        // No chemical segment → plain multi-word variable, underscores escaped.
        return format!("\\mathrm{{{}}}", variable.replace('_', "\\_"));
    }
    // A symbol with no lowercase letters (e.g. "RT", "-E") is a math variable,
    // not a descriptive name — leave it italic instead of wrapping in `\mathrm`.
    if !variable.chars().any(|c| c.is_ascii_lowercase()) {
        return variable.to_string();
    }
    format!("\\mathrm{{{variable}}}")
}

fn format_operator_latex(node: &ExpressionNode, parent_prec: i32) -> String {
    // Closed-core structural / array-query ops (and `integral`) render from
    // their non-`args` fields and are never parenthesized by precedence.
    if let Some(s) = format_structural_op(node, Fmt::Latex) {
        return s;
    }

    let op = node.op.as_str();
    let args = node.args.as_slice();
    let wrt = &node.wrt;
    let op_prec = get_precedence(op);
    let needs_parens = op_prec > 0 && op_prec <= parent_prec;
    // Renders an argument at precedence 0 (used inside delimited contexts).
    let r0 = |arg: &Expr| to_latex_prec(arg, 0);

    // `\frac{...}{...}` groups visually, so the fraction itself never needs
    // parentheses and its numerator/denominator render at precedence 0.
    if op == "/" && args.len() == 2 {
        return format!("\\frac{{{}}}{{{}}}", r0(&args[0]), r0(&args[1]));
    }

    let result = match op {
        "+" => {
            if let Some(s) = sum_as_difference(args, op_prec, Fmt::Latex) {
                s
            } else if args.len() >= 2 {
                args.iter()
                    .map(|arg| render_assoc_operand(arg, "+", op_prec, Fmt::Latex))
                    .collect::<Vec<_>>()
                    .join(" + ")
            } else {
                call_form("+", args, r0)
            }
        }
        "-" => {
            if args.len() == 1 {
                format!("-{}", to_latex_prec(&args[0], op_prec))
            } else if args.len() == 2 {
                // Left-associative: the right operand renders at op_prec + 1
                // so `a - (b - c)` keeps its parentheses.
                format!(
                    "{} - {}",
                    to_latex_prec(&args[0], op_prec),
                    to_latex_prec(&args[1], op_prec + 1)
                )
            } else {
                call_form("-", args, r0)
            }
        }
        "*" => {
            if args.len() >= 2 {
                // A product of already-typeset factors (`\mathrm{O_3}`) uses
                // implicit juxtaposition; plain symbols use `\cdot`.
                let sep = if latex_mul_juxtapose(args) {
                    " "
                } else {
                    " \\cdot "
                };
                args.iter()
                    .map(|arg| render_assoc_operand(arg, "*", op_prec, Fmt::Latex))
                    .collect::<Vec<_>>()
                    .join(sep)
            } else {
                call_form("\\cdot", args, r0)
            }
        }
        // Binary `/` renders as `\frac` above; anything else falls back.
        "/" => call_form("\\div", args, r0),
        "^" => {
            if args.len() == 2 {
                // The base is parenthesized by the precedence rule (so
                // `(a + b)^{2}` keeps visible parens); the exponent sits
                // inside `^{...}`, which groups visually, at precedence 0.
                format!("{}^{{{}}}", to_latex_prec(&args[0], op_prec), r0(&args[1]))
            } else {
                call_form("^", args, r0)
            }
        }
        "D" => {
            if let (Some(wrt_var), [arg]) = (wrt, args) {
                // Operand parenthesized when it is an operator node.
                format!(
                    "\\frac{{\\partial {}}}{{\\partial {}}}",
                    wrap_if_op(arg, Fmt::Latex),
                    wrt_var
                )
            } else {
                call_form("D", args, r0)
            }
        }
        "exp" => {
            if let [arg] = args {
                if matches!(arg, Expr::Operator(_)) {
                    format!("\\exp\\left({}\\right)", r0(arg))
                } else {
                    format!("\\exp({})", r0(arg))
                }
            } else {
                call_form("\\exp", args, r0)
            }
        }
        "ifelse" => {
            if args.len() == 3 {
                format!(
                    "\\begin{{cases}} {} & \\text{{if }} {} \\\\ {} & \\text{{otherwise}} \\end{{cases}}",
                    r0(&args[1]),
                    r0(&args[0]),
                    r0(&args[2])
                )
            } else {
                call_form("\\mathrm{ifelse}", args, r0)
            }
        }
        "and" => {
            if args.len() >= 2 {
                args.iter().map(r0).collect::<Vec<_>>().join(" \\land ")
            } else {
                call_form("\\land", args, r0)
            }
        }
        "or" => {
            if args.len() >= 2 {
                args.iter().map(r0).collect::<Vec<_>>().join(" \\lor ")
            } else {
                call_form("\\lor", args, r0)
            }
        }
        "not" => {
            if args.len() == 1 {
                // Add parentheses for complex expressions
                if matches!(&args[0], Expr::Operator(_)) {
                    format!("\\neg ({})", r0(&args[0]))
                } else {
                    format!("\\neg {}", r0(&args[0]))
                }
            } else {
                call_form("\\neg", args, r0)
            }
        }
        ">" => {
            if args.len() == 2 {
                format!("{} > {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form(">", args, r0)
            }
        }
        "<" => {
            if args.len() == 2 {
                format!("{} < {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("<", args, r0)
            }
        }
        ">=" => {
            if args.len() == 2 {
                format!("{} \\geq {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("\\geq", args, r0)
            }
        }
        "<=" => {
            if args.len() == 2 {
                format!("{} \\leq {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("\\leq", args, r0)
            }
        }
        "=" | "==" => {
            if args.len() == 2 {
                format!("{} = {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("=", args, r0)
            }
        }
        "!=" => {
            if args.len() == 2 {
                format!("{} \\neq {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("\\neq", args, r0)
            }
        }
        "log" => {
            if args.len() == 1 {
                call_form("\\ln", args, r0)
            } else {
                call_form("\\log", args, r0)
            }
        }
        "log10" => call_form("\\log_{10}", args, r0),
        "sqrt" => format!(
            "\\sqrt{{{}}}",
            args.iter().map(r0).collect::<Vec<_>>().join(", ")
        ),
        "asin" => call_form("\\arcsin", args, r0),
        "acos" => call_form("\\arccos", args, r0),
        "atan" => call_form("\\arctan", args, r0),
        "abs" => format!("|{}|", args.iter().map(r0).collect::<Vec<_>>().join(", ")),
        "sign" => call_form("\\mathrm{sgn}", args, r0),
        "floor" => format!(
            "\\lfloor {} \\rfloor",
            args.iter().map(r0).collect::<Vec<_>>().join(", ")
        ),
        "ceil" => format!(
            "\\lceil {} \\rceil",
            args.iter().map(r0).collect::<Vec<_>>().join(", ")
        ),
        "min" => call_form("\\min", args, r0),
        "max" => call_form("\\max", args, r0),
        "atan2" => call_form("\\mathrm{atan2}", args, r0),
        "sin" | "cos" | "tan" | "sinh" | "cosh" | "tanh" => call_form(&format!("\\{op}"), args, r0),
        "asinh" => call_form("\\sinh^{-1}", args, r0),
        "acosh" => call_form("\\cosh^{-1}", args, r0),
        "atanh" => call_form("\\tanh^{-1}", args, r0),
        // `Pre` renders as a call form, matching the cross-language contract.
        "Pre" => call_form("\\mathrm{Pre}", args, r0),
        // Generic fallback for open-tier sugar (grad/div/laplacian) and any
        // unknown user op: `\mathrm{ESC(name)}(args)`, escaping underscores.
        _ => call_form(&format!("\\mathrm{{{}}}", latex_name(op)), args, r0),
    };

    if needs_parens {
        format!("({result})")
    } else {
        result
    }
}

/// Convert an expression to ASCII representation
pub fn to_ascii(expr: &Expr) -> String {
    to_ascii_prec(expr, 0)
}

/// ASCII rendering with the parent operator's precedence threaded through.
///
/// The ASCII printer previously ignored precedence entirely, so `(a+b)*c`
/// rendered as the mathematically wrong `a + b * c`; it now applies the
/// same parenthesization rule as the reference Unicode printer.
fn to_ascii_prec(expr: &Expr, parent_prec: i32) -> String {
    match expr {
        Expr::Integer(n) => format_number_ascii(*n as f64),
        Expr::Number(n) => format_number_ascii(*n),
        // ASCII spells Greek characters out by name (e.g. `θ` → `theta`).
        Expr::Variable(name) => {
            nonfinite_string(name, Fmt::Ascii).unwrap_or_else(|| greek_to_ascii(name))
        }
        Expr::Operator(node) => format_operator_ascii(node, parent_prec),
    }
}

fn format_operator_ascii(node: &ExpressionNode, parent_prec: i32) -> String {
    // Closed-core structural / array-query ops (and `integral`) render from
    // their non-`args` fields and are never parenthesized by precedence.
    if let Some(s) = format_structural_op(node, Fmt::Ascii) {
        return s;
    }

    let op = node.op.as_str();
    let args = node.args.as_slice();
    let wrt = &node.wrt;
    let op_prec = get_precedence(op);
    let needs_parens = op_prec > 0 && op_prec <= parent_prec;
    // Renders an argument at precedence 0 (used inside delimited contexts).
    let r0 = |arg: &Expr| to_ascii_prec(arg, 0);

    let result = match op {
        "+" => {
            if let Some(s) = sum_as_difference(args, op_prec, Fmt::Ascii) {
                s
            } else if args.len() >= 2 {
                args.iter()
                    .map(|arg| render_assoc_operand(arg, "+", op_prec, Fmt::Ascii))
                    .collect::<Vec<_>>()
                    .join(" + ")
            } else {
                call_form("+", args, r0)
            }
        }
        "-" => {
            if args.len() == 1 {
                format!("-{}", to_ascii_prec(&args[0], op_prec))
            } else if args.len() == 2 {
                // Left-associative: the right operand renders at op_prec + 1
                // so `a - (b - c)` keeps its parentheses.
                format!(
                    "{} - {}",
                    to_ascii_prec(&args[0], op_prec),
                    to_ascii_prec(&args[1], op_prec + 1)
                )
            } else {
                call_form("-", args, r0)
            }
        }
        "*" => {
            if args.len() >= 2 {
                args.iter()
                    .map(|arg| render_assoc_operand(arg, "*", op_prec, Fmt::Ascii))
                    .collect::<Vec<_>>()
                    .join(" * ")
            } else {
                call_form("*", args, r0)
            }
        }
        "/" => {
            if args.len() == 2 {
                // Left operand needs parens only when strictly looser-binding
                // (op_prec - 1), so `a * b / c` stays unparenthesized.
                format!(
                    "{} / {}",
                    to_ascii_prec(&args[0], op_prec - 1),
                    to_ascii_prec(&args[1], op_prec + 1)
                )
            } else {
                call_form("/", args, r0)
            }
        }
        "^" => {
            if args.len() == 2 {
                format!(
                    "{}^{}",
                    to_ascii_prec(&args[0], op_prec),
                    to_ascii_prec(&args[1], op_prec + 1)
                )
            } else {
                call_form("^", args, r0)
            }
        }
        "D" => {
            if let (Some(wrt_var), [arg]) = (wrt, args) {
                // ASCII derivative uses the fraction form `D(operand)/Dt`
                // (mirrors unicode/latex `∂x/∂t`); the operand sits inside the
                // `D(...)` parentheses, so `D(x + y)/Dt`.
                format!("D({})/D{wrt_var}", r0(arg))
            } else {
                call_form("D", args, r0)
            }
        }
        ">" => {
            if args.len() == 2 {
                format!("{} > {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form(">", args, r0)
            }
        }
        "<" => {
            if args.len() == 2 {
                format!("{} < {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("<", args, r0)
            }
        }
        ">=" => {
            if args.len() == 2 {
                format!("{} >= {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form(">=", args, r0)
            }
        }
        "<=" => {
            if args.len() == 2 {
                format!("{} <= {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("<=", args, r0)
            }
        }
        "=" | "==" => {
            if args.len() == 2 {
                format!("{} == {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("==", args, r0)
            }
        }
        "!=" => {
            if args.len() == 2 {
                format!("{} != {}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("!=", args, r0)
            }
        }
        "and" => {
            if args.len() >= 2 {
                args.iter().map(r0).collect::<Vec<_>>().join(" and ")
            } else {
                call_form("and", args, r0)
            }
        }
        "or" => {
            if args.len() >= 2 {
                args.iter().map(r0).collect::<Vec<_>>().join(" or ")
            } else {
                call_form("or", args, r0)
            }
        }
        "not" => {
            if args.len() == 1 {
                // Parenthesize a complex operand: `not (x == 0)`.
                if matches!(&args[0], Expr::Operator(_)) {
                    format!("not ({})", r0(&args[0]))
                } else {
                    format!("not {}", r0(&args[0]))
                }
            } else {
                call_form("not", args, r0)
            }
        }
        // `Pre` renders as a call form, matching the cross-language contract.
        "Pre" => call_form("Pre", args, r0),
        // Genuinely call-shaped operators (log, sqrt, trig, min/max, ...) and
        // unknown operators (including the open-tier rewrite-target sugar
        // grad/div/laplacian).
        _ => call_form(op, args, r0),
    };

    if needs_parens {
        format!("({result})")
    } else {
        result
    }
}

impl fmt::Display for Model {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let name = self.name.as_deref().unwrap_or("Unnamed");
        let param_count = self
            .variables
            .iter()
            .filter(|(_, v)| matches!(v.var_type, VariableType::Parameter))
            .count();
        let eq_count = self.equations.len();

        writeln!(
            f,
            "    {} ({} parameters, {} equation{})",
            name,
            param_count,
            eq_count,
            if eq_count == 1 { "" } else { "s" }
        )?;

        // Display equations
        for eq in &self.equations {
            writeln!(f, "      {} = {}", eq.lhs, eq.rhs)?;
        }

        Ok(())
    }
}

impl fmt::Display for ReactionSystem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let species_count = self.species.len();

        // Count parameters
        let param_count = self.parameters.len();

        let reaction_count = self.reactions.len();

        writeln!(
            f,
            "    ReactionSystem ({} species, {} parameters, {} reaction{})",
            species_count,
            param_count,
            reaction_count,
            if reaction_count == 1 { "" } else { "s" }
        )?;

        // Display reactions
        for (i, reaction) in self.reactions.iter().enumerate() {
            let default_name = format!("R{}", i + 1);
            let reaction_name = reaction
                .id
                .as_deref()
                .or(reaction.name.as_deref())
                .unwrap_or(&default_name);

            // Format substrates
            let substrates = reaction
                .substrates
                .iter()
                .flatten()
                .map(|s| {
                    if s.coefficient == 1.0 {
                        format_chemical_subscripts(&s.species)
                    } else {
                        format!(
                            "{}·{}",
                            format_number_unicode(s.coefficient),
                            format_chemical_subscripts(&s.species)
                        )
                    }
                })
                .collect::<Vec<_>>()
                .join(" + ");

            // Format products
            let products = reaction
                .products
                .iter()
                .flatten()
                .map(|p| {
                    if p.coefficient == 1.0 {
                        format_chemical_subscripts(&p.species)
                    } else {
                        format!(
                            "{}·{}",
                            format_number_unicode(p.coefficient),
                            format_chemical_subscripts(&p.species)
                        )
                    }
                })
                .collect::<Vec<_>>()
                .join(" + ");

            writeln!(
                f,
                "      {}: {} → {}    rate: {}",
                reaction_name, substrates, products, reaction.rate
            )?;
        }

        Ok(())
    }
}

impl fmt::Display for EsmFile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let name = self.metadata.name.as_deref().unwrap_or("Unnamed");
        let description = self.metadata.description.as_deref().unwrap_or("");
        let authors = self
            .metadata
            .authors
            .as_ref()
            .map(|a| a.join(", "))
            .unwrap_or_else(|| "Unknown".to_string());

        writeln!(f, "ESM v{}: {}", self.esm, name)?;
        if !description.is_empty() {
            writeln!(f, "  \"{description}\"")?;
        }
        writeln!(f, "  Authors: {authors}")?;
        writeln!(f)?;

        // Display reaction systems
        if let Some(ref reaction_systems) = self.reaction_systems
            && !reaction_systems.is_empty()
        {
            writeln!(f, "  Reaction Systems:")?;
            for system in reaction_systems.values() {
                write!(f, "{system}")?;
                writeln!(f)?;
            }
        }

        // Display models
        if let Some(ref models) = self.models
            && !models.is_empty()
        {
            writeln!(f, "  Models:")?;
            for model in models.values() {
                write!(f, "{model}")?;
                writeln!(f)?;
            }
        }

        // Display data loaders
        if let Some(ref data_loaders) = self.data_loaders
            && !data_loaders.is_empty()
        {
            writeln!(f, "  Data Loaders:")?;
            for (name, loader) in data_loaders {
                let kind = match loader.kind {
                    crate::DataLoaderKind::Grid => "grid",
                    crate::DataLoaderKind::Points => "points",
                    crate::DataLoaderKind::Static => "static",
                };
                writeln!(
                    f,
                    "    {}: [{}] {} ({} variable{})",
                    name,
                    kind,
                    loader.source.url_template,
                    loader.variables.len(),
                    if loader.variables.len() == 1 { "" } else { "s" },
                )?;
            }
            writeln!(f)?;
        }

        // Display coupling
        if let Some(ref coupling) = self.coupling
            && !coupling.is_empty()
        {
            writeln!(f, "  Coupling:")?;
            for (i, entry) in coupling.iter().enumerate() {
                match entry {
                    CouplingEntry::OperatorCompose { systems, .. } => {
                        if systems.len() >= 2 {
                            writeln!(
                                f,
                                "    {}. operator_compose: {} + {}",
                                i + 1,
                                systems[0],
                                systems[1]
                            )?;
                        }
                    }
                    CouplingEntry::VariableMap { from, to, .. } => {
                        writeln!(f, "    {}. variable_map: {} → {}", i + 1, from, to)?;
                    }
                    _ => {
                        writeln!(f, "    {}. {:?}", i + 1, entry)?;
                    }
                }
            }
            writeln!(f)?;
        }

        // Display domain information (EsmFile.domain is the single shared domain)
        if let Some(ref domain) = self.domain {
            write!(f, "  Domain: ")?;

            let mut domain_parts = Vec::new();
            if domain.temporal.is_some() {
                domain_parts.push("temporal".to_string());
            }

            if domain_parts.is_empty() {
                writeln!(f, "[Domain information]")?;
            } else {
                writeln!(f, "{}", domain_parts.join(", "))?;
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_chemical_subscripts() {
        assert_eq!(format_chemical_subscripts("O3"), "O₃");
        assert_eq!(format_chemical_subscripts("NO2"), "NO₂");
        assert_eq!(format_chemical_subscripts("CH4"), "CH₄");
        assert_eq!(format_chemical_subscripts("C2H6"), "C₂H₆");
        assert_eq!(format_chemical_subscripts("H2O2"), "H₂O₂");
    }

    #[test]
    fn test_number_formatting_unicode() {
        assert_eq!(format_number_unicode(42.0), "42");
        assert_eq!(format_number_unicode(3.15), "3.15");
        // Mantissa is full-precision (no forced trailing zero): 1.8, not 1.80.
        assert_eq!(format_number_unicode(1.8e-12), "1.8×10⁻¹²");
        assert_eq!(format_number_unicode(2.46e19), "2.46×10¹⁹");

        // Zero prints as a bare "0" (never "0.0") in every backend.
        assert_eq!(format_number_unicode(0.0), "0");
        assert_eq!(format_number_unicode(-0.0), "0");

        // Other integers display without a decimal point; Unicode uses U+2212.
        assert_eq!(format_number_unicode(1.0), "1");
        assert_eq!(format_number_unicode(-1.0), "−1");
    }

    #[test]
    fn test_zero_formatting_all_formats() {
        // Zero renders as a bare "0" in every backend (RENDERING_CONTRACT.md).
        let zero_expr = Expr::Number(0.0);
        let one_expr = Expr::Number(1.0);
        let neg_zero_expr = Expr::Number(-0.0);

        // Unicode formatting
        assert_eq!(to_unicode(&zero_expr), "0");
        assert_eq!(to_unicode(&neg_zero_expr), "0");
        assert_eq!(to_unicode(&one_expr), "1");

        // LaTeX formatting
        assert_eq!(to_latex(&zero_expr), "0");
        assert_eq!(to_latex(&neg_zero_expr), "0");
        assert_eq!(to_latex(&one_expr), "1");

        // ASCII formatting
        assert_eq!(to_ascii(&zero_expr), "0");
        assert_eq!(to_ascii(&neg_zero_expr), "0");
        assert_eq!(to_ascii(&one_expr), "1");
    }

    #[test]
    fn test_scientific_all_backends() {
        // Full-precision mantissa, U+2212 minus / `\times` / `e`, no `+` sign.
        assert_eq!(format_number_unicode(1.8e-12), "1.8×10⁻¹²");
        assert_eq!(format_number_unicode(2.46e19), "2.46×10¹⁹");
        assert_eq!(format_number_latex(1.8e-12), "1.8 \\times 10^{-12}");
        assert_eq!(format_number_ascii(1.8e-12), "1.8e-12");
        // Non-finite values render as symbols, never stringified.
        assert_eq!(format_number_unicode(f64::INFINITY), "∞");
        assert_eq!(format_number_latex(f64::NEG_INFINITY), "-\\infty");
        assert_eq!(format_number_ascii(f64::NAN), "NaN");
    }

    #[test]
    fn test_expr_display() {
        let expr = Expr::Variable("O3".to_string());
        assert_eq!(format!("{expr}"), "O₃");

        let expr = Expr::Number(1.8e-12);
        assert_eq!(format!("{expr}"), "1.8×10⁻¹²");
    }

    #[test]
    fn test_operator_precedence() {
        let add = Expr::Operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![
                Expr::Operator(ExpressionNode {
                    op: "*".to_string(),
                    args: vec![
                        Expr::Variable("a".to_string()),
                        Expr::Variable("b".to_string()),
                    ],
                    wrt: None,
                    dim: None,
                    ..Default::default()
                }),
                Expr::Variable("c".to_string()),
            ],
            wrt: None,
            dim: None,
            ..Default::default()
        });
        assert_eq!(format!("{add}"), "a·b + c");

        let mul = Expr::Operator(ExpressionNode {
            op: "*".to_string(),
            args: vec![
                Expr::Operator(ExpressionNode {
                    op: "+".to_string(),
                    args: vec![
                        Expr::Variable("a".to_string()),
                        Expr::Variable("b".to_string()),
                    ],
                    wrt: None,
                    dim: None,
                    ..Default::default()
                }),
                Expr::Variable("c".to_string()),
            ],
            wrt: None,
            dim: None,
            ..Default::default()
        });
        assert_eq!(format!("{mul}"), "(a + b)·c");
    }

    #[test]
    fn test_model_summary_display() {
        use std::collections::HashMap;

        // Create minimal ESM file for testing display
        let metadata = Metadata {
            name: Some("TestModel".to_string()),
            description: Some("Test description".to_string()),
            authors: Some(vec!["Test Author".to_string()]),
            license: None,
            created: None,
            modified: None,
            tags: None,
            references: None,
            system_class: None,
            dae_info: None,
            discretized_from: None,
        };

        // Create a simple reaction system
        let mut parameters = HashMap::new();
        parameters.insert(
            "k1".to_string(),
            Parameter {
                default: Some(1.8e-12),
                units: Some("cm3/molec/s".to_string()),
                description: Some("Rate constant".to_string()),
            },
        );

        let reactions = vec![Reaction {
            id: Some("R1".to_string()),
            name: Some("R1".to_string()),
            substrates: Some(vec![StoichiometricEntry {
                species: "A".to_string(),
                coefficient: 1.0,
            }]),
            products: Some(vec![StoichiometricEntry {
                species: "B".to_string(),
                coefficient: 1.0,
            }]),
            rate: Expr::Variable("k1".to_string()),
            reference: None,
        }];

        let mut species = HashMap::new();
        species.insert(
            "A".to_string(),
            Species {
                default: Some(1e-9),
                units: Some("molec/cm3".to_string()),
                description: None,
                constant: None,
            },
        );
        species.insert(
            "B".to_string(),
            Species {
                default: Some(0.0),
                units: Some("molec/cm3".to_string()),
                description: None,
                constant: None,
            },
        );

        let reaction_system = ReactionSystem {
            reference: None,
            species,
            parameters,
            reactions,
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        let mut reaction_systems = HashMap::new();
        reaction_systems.insert("TestReactions".to_string(), reaction_system);

        // Create ESM file
        let esm_file = EsmFile {
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata,
            models: None,
            reaction_systems: Some(reaction_systems),
            operators: None,
            enums: None,

            data_loaders: None,
            coupling: None,
            function_tables: None,
        };

        // Test the display output
        let output = format!("{esm_file}");

        // Check key components are present in the expected format
        assert!(output.contains("ESM v0.1.0: TestModel"));
        assert!(output.contains("\"Test description\""));
        assert!(output.contains("Authors: Test Author"));
        assert!(output.contains("Reaction Systems:"));
        assert!(output.contains("(2 species, 1 parameters, 1 reaction)"));
        assert!(output.contains("R1: A → B    rate: k1"));
    }

    #[test]
    fn test_pre_operator_formatting() {
        use crate::types::*;

        // Test Unicode formatting for Pre operator with x⁻ notation
        let pre_expr = Expr::Operator(ExpressionNode {
            op: "Pre".to_string(),
            args: vec![Expr::Variable("x".to_string())],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        // `Pre` renders as a call form (cross-language rendering contract).
        assert_eq!(to_unicode(&pre_expr), "Pre(x)");
        assert_eq!(to_latex(&pre_expr), "\\mathrm{Pre}(x)");
        assert_eq!(to_ascii(&pre_expr), "Pre(x)");

        // Test with complex expression as argument
        let complex_pre = Expr::Operator(ExpressionNode {
            op: "Pre".to_string(),
            args: vec![Expr::Operator(ExpressionNode {
                op: "+".to_string(),
                args: vec![
                    Expr::Variable("a".to_string()),
                    Expr::Variable("b".to_string()),
                ],
                wrt: None,
                dim: None,
                ..Default::default()
            })],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        assert_eq!(to_unicode(&complex_pre), "Pre(a + b)");
        assert_eq!(to_latex(&complex_pre), "\\mathrm{Pre}(a + b)");
        assert_eq!(to_ascii(&complex_pre), "Pre(a + b)");

        // Test with multiple arguments (should fall back to Pre(...) format)
        let multi_arg_pre = Expr::Operator(ExpressionNode {
            op: "Pre".to_string(),
            args: vec![
                Expr::Variable("x".to_string()),
                Expr::Variable("y".to_string()),
            ],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        assert_eq!(to_unicode(&multi_arg_pre), "Pre(x, y)");
        assert_eq!(to_latex(&multi_arg_pre), "\\mathrm{Pre}(x, y)");
        assert_eq!(to_ascii(&multi_arg_pre), "Pre(x, y)");
    }

    /// Build an operator node for the precedence tests below.
    fn op_node(op: &str, args: Vec<Expr>) -> Expr {
        Expr::Operator(ExpressionNode {
            op: op.to_string(),
            args,
            wrt: None,
            dim: None,
            ..Default::default()
        })
    }

    fn var(name: &str) -> Expr {
        Expr::Variable(name.to_string())
    }

    #[test]
    fn test_precedence_parens_all_printers() {
        // Regression test: the LaTeX and ASCII printers previously ignored
        // precedence, so (a + b) * c rendered as the mathematically wrong
        // `a + b \cdot c` / `a + b * c`.
        let mul = op_node("*", vec![op_node("+", vec![var("a"), var("b")]), var("c")]);
        assert_eq!(to_unicode(&mul), "(a + b)·c");
        assert_eq!(to_latex(&mul), "(a + b) \\cdot c");
        assert_eq!(to_ascii(&mul), "(a + b) * c");

        // No spurious parentheses when precedence already binds correctly.
        let add = op_node("+", vec![var("a"), op_node("*", vec![var("b"), var("c")])]);
        assert_eq!(to_unicode(&add), "a + b·c");
        assert_eq!(to_latex(&add), "a + b \\cdot c");
        assert_eq!(to_ascii(&add), "a + b * c");

        // Left-associative subtraction: the right operand keeps parentheses.
        let sub = op_node("-", vec![var("a"), op_node("-", vec![var("b"), var("c")])]);
        assert_eq!(to_unicode(&sub), "a − (b − c)");
        assert_eq!(to_latex(&sub), "a - (b - c)");
        assert_eq!(to_ascii(&sub), "a - (b - c)");

        // Powers parenthesize a lower-precedence base in every backend
        // (`{a + b}^{2}` would typeset as `a + b²` in LaTeX).
        let pow = op_node(
            "^",
            vec![op_node("+", vec![var("a"), var("b")]), Expr::Number(2.0)],
        );
        assert_eq!(to_unicode(&pow), "(a + b)²");
        assert_eq!(to_latex(&pow), "(a + b)^{2}");
        assert_eq!(to_ascii(&pow), "(a + b)^2");

        // `\frac` groups visually, so a fraction under a product stays bare
        // in LaTeX while the inline forms need parentheses.
        let frac_mul = op_node("*", vec![var("a"), op_node("/", vec![var("b"), var("c")])]);
        assert_eq!(to_unicode(&frac_mul), "a·(b/c)");
        assert_eq!(to_latex(&frac_mul), "a \\cdot \\frac{b}{c}");
        assert_eq!(to_ascii(&frac_mul), "a * (b / c)");
    }

    #[test]
    fn test_scientific_notation_unified_across_printers() {
        // All three printers share one float-formatting core. LaTeX and
        // ASCII previously collapsed large integral floats (e.g. 2.46e19)
        // into long digit strings instead of scientific notation.
        let large = Expr::Number(2.46e19);
        assert_eq!(to_unicode(&large), "2.46×10¹⁹");
        assert_eq!(to_latex(&large), "2.46 \\times 10^{19}");
        assert_eq!(to_ascii(&large), "2.46e19");

        let small = Expr::Number(1.8e-12);
        assert_eq!(to_unicode(&small), "1.8×10⁻¹²");
        assert_eq!(to_latex(&small), "1.8 \\times 10^{-12}");
        assert_eq!(to_ascii(&small), "1.8e-12");

        // A large-magnitude *integer* leaf uses scientific notation too.
        let big_int = Expr::Integer(15000);
        assert_eq!(to_unicode(&big_int), "1.5×10⁴");
        assert_eq!(to_ascii(&big_int), "1.5e4");
    }
}
