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

    let mut result = String::new();
    let chars: Vec<char> = s.chars().collect();
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
            result.push(ch);
            i += 1;
        }
    }

    result
}

/// Find if there's a valid element symbol at the given position
fn find_element_at_position(s: &str, pos: usize) -> Option<usize> {
    // Look backwards from position to find potential element start
    let chars: Vec<char> = s.chars().collect();

    // Try 2-letter elements first (at pos-1, pos)
    if pos > 0 && pos < chars.len() {
        let two_letter = format!("{}{}", chars[pos - 1], chars[pos]);
        if ELEMENTS.contains(&two_letter.as_str()) {
            return Some(pos);
        }
    }

    // Try 1-letter elements (at pos)
    if pos < chars.len() {
        let one_letter = chars[pos].to_string();
        if ELEMENTS.contains(&one_letter.as_str()) {
            return Some(pos);
        }
    }

    None
}

/// Backend-independent pieces of a formatted floating-point number.
///
/// The Unicode, LaTeX, and ASCII printers previously each hand-rolled the
/// 0.0 special case, integer collapse, trailing-zero trimming, and
/// scientific-notation cutoffs — with slightly divergent orderings. They now
/// share `format_display_float` and differ only in how they render the
/// exponent (Unicode superscripts, LaTeX `\times 10^{...}`, ASCII `e`).
enum FloatParts {
    /// Rendered verbatim in every backend (e.g. "0.0", "42", "3.15").
    Plain(String),
    /// Scientific notation, e.g. mantissa "1.80" with exponent "-12".
    Scientific { mantissa: String, exponent: String },
}

/// Shared float-formatting core for all three expression printers.
fn format_display_float(n: f64) -> FloatParts {
    let abs_n = n.abs();

    // Scientific notation for very large or very small magnitudes. This
    // check comes first (matching the reference Unicode printer) so integral
    // values like 2e4 render as scientific rather than collapsing to "20000".
    if abs_n >= 10000.0 || (abs_n < 0.0001 && abs_n != 0.0) {
        // `{:.2e}` normalizes the mantissa (including rounding overflow such
        // as 9.999e4 -> 1.00e5), which manual log10 arithmetic got wrong.
        let sci = format!("{n:.2e}");
        return match sci.find('e') {
            Some(e_pos) => FloatParts::Scientific {
                mantissa: sci[..e_pos].to_string(),
                exponent: sci[e_pos + 1..].trim_start_matches('+').to_string(),
            },
            // Non-finite values ("inf", "NaN") carry no exponent.
            None => FloatParts::Plain(sci),
        };
    }

    // Special handling for 0.0 - display as "0.0" instead of "0"
    if n == 0.0 {
        return FloatParts::Plain("0.0".to_string());
    }

    // Other integers in normal range display without a decimal point
    if n.fract() == 0.0 {
        return FloatParts::Plain(format!("{}", n as i64));
    }

    // 1-4 significant digits in decimal notation, trailing zeros removed
    let formatted = format!("{n:.4}");
    FloatParts::Plain(
        formatted
            .trim_end_matches('0')
            .trim_end_matches('.')
            .to_string(),
    )
}

/// Format a number according to the specification
fn format_number_unicode(n: f64) -> String {
    match format_display_float(n) {
        FloatParts::Plain(s) => s,
        FloatParts::Scientific { mantissa, exponent } => {
            format_scientific_unicode(&format!("{mantissa}e{exponent}"))
        }
    }
}

/// Convert scientific notation to Unicode with superscripts
fn format_scientific_unicode(sci: &str) -> String {
    if let Some(e_pos) = sci.find('e') {
        let (mantissa, exponent) = sci.split_at(e_pos);
        let exp_part = &exponent[1..]; // Skip 'e'

        let mut unicode_exp = String::new();
        let mut exp_chars = exp_part.chars();

        // Handle sign
        if let Some(first) = exp_chars.next() {
            match first {
                '+' => {} // Skip plus
                '-' => unicode_exp.push('⁻'),
                d if d.is_ascii_digit() => {
                    if let Some(digit) = d.to_digit(10) {
                        unicode_exp.push(UNICODE_SUPERSCRIPTS[digit as usize]);
                    }
                }
                _ => {}
            }
        }

        // Convert remaining digits
        for ch in exp_chars {
            if let Some(digit) = ch.to_digit(10) {
                unicode_exp.push(UNICODE_SUPERSCRIPTS[digit as usize]);
            }
        }

        format!("{mantissa}×10{unicode_exp}")
    } else {
        sci.to_string()
    }
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
            Expr::Number(n) => format_number_unicode(*n),
            Expr::Integer(n) => n.to_string(),
            Expr::Variable(name) => format_chemical_subscripts(name),
            Expr::Operator(node) => {
                format_operator_unicode(&node.op, &node.args, &node.wrt, &node.dim, parent_prec)
            }
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

fn format_operator_unicode(
    op: &str,
    args: &[Expr],
    wrt: &Option<String>,
    dim: &Option<String>,
    parent_prec: i32,
) -> String {
    let op_prec = get_precedence(op);
    let needs_parens = op_prec > 0 && op_prec <= parent_prec;
    // Renders an argument at precedence 0 (used inside delimited contexts).
    let r0 = |arg: &Expr| arg.to_unicode_with_precedence(0);

    let result = match op {
        "+" => {
            if args.len() >= 2 {
                args.iter()
                    .map(|arg| arg.to_unicode_with_precedence(op_prec))
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
                    .map(|arg| arg.to_unicode_with_precedence(op_prec))
                    .collect::<Vec<_>>()
                    .join("·")
            } else {
                call_form("·", args, r0)
            }
        }
        "/" => {
            if args.len() == 2 {
                format!(
                    "{}/{}",
                    args[0].to_unicode_with_precedence(op_prec),
                    args[1].to_unicode_with_precedence(op_prec + 1)
                )
            } else {
                call_form("÷", args, r0)
            }
        }
        "^" => {
            if args.len() == 2 {
                match &args[1] {
                    Expr::Number(n) if *n == 2.0 => {
                        format!("{}²", args[0].to_unicode_with_precedence(op_prec))
                    }
                    Expr::Number(n) if *n == 3.0 => {
                        format!("{}³", args[0].to_unicode_with_precedence(op_prec))
                    }
                    _ => format!(
                        "{}^{}",
                        args[0].to_unicode_with_precedence(op_prec),
                        args[1].to_unicode_with_precedence(op_prec + 1)
                    ),
                }
            } else {
                call_form("^", args, r0)
            }
        }
        "D" => {
            // Derivative operator
            if let (Some(wrt_var), [arg]) = (wrt, args) {
                format!("∂{}/∂{}", r0(arg), format_chemical_subscripts(wrt_var))
            } else {
                call_form("D", args, r0)
            }
        }
        "grad" => {
            // Gradient - use dim field if available
            if let ([arg], Some(dim_val)) = (args, dim) {
                format!("∂{}/∂{}", r0(arg), dim_val)
            } else if args.len() == 1 {
                call_form("∇", args, r0)
            } else {
                call_form("grad", args, r0)
            }
        }
        "div" => {
            // Divergence operator
            if let [arg] = args {
                format!("∇·{}", arg.to_unicode_with_precedence(op_prec))
            } else {
                call_form("div", args, r0)
            }
        }
        "laplacian" => {
            // Laplacian operator
            if let [arg] = args {
                format!("∇²{}", arg.to_unicode_with_precedence(op_prec))
            } else {
                call_form("laplacian", args, r0)
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
                format!("√{}", arg.to_unicode_with_precedence(op_prec))
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
        "binomial" => {
            if args.len() == 2 {
                format!("C({},{})", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("binomial", args, r0)
            }
        }
        "gamma" => {
            if args.len() == 1 {
                call_form("Γ", args, r0)
            } else {
                call_form("gamma", args, r0)
            }
        }
        "Pre" => {
            if args.len() == 1 {
                format!("{}⁻", args[0].to_unicode_with_precedence(op_prec))
            } else {
                call_form("Pre", args, r0)
            }
        }
        // Genuinely call-shaped operators (exp, ifelse, min/max, trig,
        // hyperbolics, erf/erfc, atan2, ...) and unknown operators.
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
        Expr::Integer(n) => n.to_string(),
        Expr::Number(n) => match format_display_float(*n) {
            FloatParts::Plain(s) => s,
            FloatParts::Scientific { mantissa, exponent } => {
                format!("{mantissa} \\times 10^{{{exponent}}}")
            }
        },
        Expr::Variable(name) => format_variable_latex(name),
        Expr::Operator(node) => {
            format_operator_latex(&node.op, &node.args, &node.wrt, &node.dim, parent_prec)
        }
    }
}

fn format_variable_latex(name: &str) -> String {
    // Simple variable (single letter, no digits)
    if name.len() == 1 && !name.chars().any(|c| c.is_ascii_digit()) {
        return name.to_string();
    }

    // Check if the name contains chemical elements after a prefix
    // Look for patterns like "k_NO_O3" where we want "k_{\\mathrm{NO_O_3}}"
    if let Some(underscore_pos) = name.find('_') {
        let prefix = &name[..underscore_pos + 1]; // Include underscore
        let suffix = &name[underscore_pos + 1..];

        // Check if suffix looks like a chemical formula (starts with element)
        if is_chemical_formula(suffix) {
            return format!(
                "{}{{\\mathrm{{{}}}}}",
                prefix,
                format_chemical_latex(suffix)
            );
        }
    }

    // Check if starts with lowercase letters that could be non-chemical prefix
    let mut prefix_end = 0;
    for ch in name.chars() {
        if ch.is_ascii_lowercase() || ch == '_' {
            prefix_end += ch.len_utf8();
        } else {
            break;
        }
    }

    if prefix_end > 0 && prefix_end < name.len() {
        let prefix = &name[..prefix_end];
        let suffix = &name[prefix_end..];

        if is_chemical_formula(suffix) {
            return format!(
                "{}_{{\\mathrm{{{}}}}}",
                prefix,
                format_chemical_latex(suffix)
            );
        }
    }

    // Default: treat entire name as potentially chemical
    if name.len() > 1 || name.chars().any(|c| c.is_ascii_digit()) {
        format!("\\mathrm{{{}}}", format_chemical_latex(name))
    } else {
        name.to_string()
    }
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

fn format_chemical_latex(s: &str) -> String {
    let mut result = String::new();
    let mut chars = s.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch.is_alphabetic() {
            result.push(ch);

            // Check if this starts an element symbol and convert following digits
            let current_pos = result.len() - 1;
            if find_element_at_position(&result, current_pos).is_some() {
                // Collect consecutive digits after the element
                let mut digits = String::new();
                while let Some(&next_ch) = chars.peek() {
                    if next_ch.is_ascii_digit() {
                        digits.push(chars.next().unwrap());
                    } else {
                        break;
                    }
                }

                // Convert digits to LaTeX subscripts
                if !digits.is_empty() {
                    result.push('_');
                    if digits.len() > 1 {
                        result.push('{');
                        result.push_str(&digits);
                        result.push('}');
                    } else {
                        result.push_str(&digits);
                    }
                }
            }
        } else {
            result.push(ch);
        }
    }

    result
}

fn format_operator_latex(
    op: &str,
    args: &[Expr],
    wrt: &Option<String>,
    dim: &Option<String>,
    parent_prec: i32,
) -> String {
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
            if args.len() >= 2 {
                args.iter()
                    .map(|arg| to_latex_prec(arg, op_prec))
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
                args.iter()
                    .map(|arg| to_latex_prec(arg, op_prec))
                    .collect::<Vec<_>>()
                    .join(" \\cdot ")
            } else {
                call_form("\\cdot", args, r0)
            }
        }
        // Binary `/` renders as `\frac` above; anything else falls back.
        "/" => call_form("\\div", args, r0),
        "^" => {
            if args.len() == 2 {
                // The base still needs parenthesization (`{a + b}^{2}`
                // typesets the superscript directly after `b`, reading as
                // `a + b²`), but the exponent sits inside `^{...}`, which
                // groups visually, so it renders at precedence 0.
                format!(
                    "{{{}}}^{{{}}}",
                    to_latex_prec(&args[0], op_prec),
                    r0(&args[1])
                )
            } else {
                call_form("^", args, r0)
            }
        }
        "D" => {
            if let (Some(wrt_var), [arg]) = (wrt, args) {
                format!("\\frac{{\\partial {}}}{{\\partial {}}}", r0(arg), wrt_var)
            } else {
                call_form("D", args, r0)
            }
        }
        "grad" => {
            if let ([arg], Some(dim_val)) = (args, dim) {
                format!("\\frac{{\\partial {}}}{{\\partial {}}}", r0(arg), dim_val)
            } else if args.len() == 1 {
                call_form("\\nabla", args, r0)
            } else {
                call_form("\\mathrm{grad}", args, r0)
            }
        }
        "div" => {
            if let [arg] = args {
                format!("\\nabla \\cdot {}", to_latex_prec(arg, op_prec))
            } else {
                call_form("\\mathrm{div}", args, r0)
            }
        }
        "laplacian" => {
            if let [arg] = args {
                format!("\\nabla^2 {}", to_latex_prec(arg, op_prec))
            } else {
                call_form("\\mathrm{laplacian}", args, r0)
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
                    "\\begin{{cases}} {} & \\text{{if }} {} \\\\\\\\ {} & \\text{{otherwise}} \\end{{cases}}",
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
                    format!("\\lnot ({})", r0(&args[0]))
                } else {
                    format!("\\lnot {}", r0(&args[0]))
                }
            } else {
                call_form("\\lnot", args, r0)
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
        "binomial" => {
            if args.len() == 2 {
                format!("\\binom{{{}}}{{{}}}", r0(&args[0]), r0(&args[1]))
            } else {
                call_form("\\mathrm{binomial}", args, r0)
            }
        }
        "gamma" => call_form("\\Gamma", args, r0),
        "erf" => call_form("\\mathrm{erf}", args, r0),
        "erfc" => call_form("\\mathrm{erfc}", args, r0),
        "sin" | "cos" | "tan" | "sinh" | "cosh" | "tanh" => call_form(&format!("\\{op}"), args, r0),
        "asinh" => call_form("\\sinh^{-1}", args, r0),
        "acosh" => call_form("\\cosh^{-1}", args, r0),
        "atanh" => call_form("\\tanh^{-1}", args, r0),
        "Pre" => {
            if args.len() == 1 {
                format!("{{{}}}^{{-}}", r0(&args[0]))
            } else {
                call_form("\\mathrm{Pre}", args, r0)
            }
        }
        _ => call_form(&format!("\\mathrm{{{op}}}"), args, r0),
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
        Expr::Integer(n) => n.to_string(),
        Expr::Number(n) => match format_display_float(*n) {
            FloatParts::Plain(s) => s,
            FloatParts::Scientific { mantissa, exponent } => format!("{mantissa}e{exponent}"),
        },
        Expr::Variable(name) => name.clone(),
        Expr::Operator(node) => {
            format_operator_ascii(&node.op, &node.args, &node.wrt, &node.dim, parent_prec)
        }
    }
}

fn format_operator_ascii(
    op: &str,
    args: &[Expr],
    wrt: &Option<String>,
    dim: &Option<String>,
    parent_prec: i32,
) -> String {
    let op_prec = get_precedence(op);
    let needs_parens = op_prec > 0 && op_prec <= parent_prec;
    // Renders an argument at precedence 0 (used inside delimited contexts).
    let r0 = |arg: &Expr| to_ascii_prec(arg, 0);

    let result = match op {
        "+" => {
            if args.len() == 2 {
                format!(
                    "{} + {}",
                    to_ascii_prec(&args[0], op_prec),
                    to_ascii_prec(&args[1], op_prec)
                )
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
            if args.len() == 2 {
                format!(
                    "{} * {}",
                    to_ascii_prec(&args[0], op_prec),
                    to_ascii_prec(&args[1], op_prec)
                )
            } else {
                call_form("*", args, r0)
            }
        }
        "/" => {
            if args.len() == 2 {
                format!(
                    "{} / {}",
                    to_ascii_prec(&args[0], op_prec),
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
                format!("D({})/D{}", r0(arg), wrt_var)
            } else {
                call_form("D", args, r0)
            }
        }
        "grad" => {
            if let ([arg], Some(dim_val)) = (args, dim) {
                format!("d({})/d{}", r0(arg), dim_val)
            } else {
                call_form("grad", args, r0)
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
                args.iter()
                    .map(|arg| format!("({})", r0(arg)))
                    .collect::<Vec<_>>()
                    .join(" && ")
            } else {
                call_form("and", args, r0)
            }
        }
        "or" => {
            if args.len() >= 2 {
                args.iter()
                    .map(|arg| format!("({})", r0(arg)))
                    .collect::<Vec<_>>()
                    .join(" || ")
            } else {
                call_form("or", args, r0)
            }
        }
        "not" => {
            if args.len() == 1 {
                format!("!({})", r0(&args[0]))
            } else {
                call_form("not", args, r0)
            }
        }
        "binomial" => format!(
            "binomial({}, {})",
            args.first().map(r0).unwrap_or_default(),
            args.get(1).map(r0).unwrap_or_default()
        ),
        "Pre" => {
            if args.len() == 1 {
                format!("{}-", r0(&args[0]))
            } else {
                call_form("Pre", args, r0)
            }
        }
        // Genuinely call-shaped operators (log, sqrt, trig, min/max,
        // laplacian, erf/erfc, ...) and unknown operators.
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
        assert_eq!(format_number_unicode(1.8e-12), "1.80×10⁻¹²");
        assert_eq!(format_number_unicode(2.46e19), "2.46×10¹⁹");

        // Test special handling of 0.0 - should display as "0.0" not "0"
        assert_eq!(format_number_unicode(0.0), "0.0");
        assert_eq!(format_number_unicode(-0.0), "0.0");

        // Other integers should still display without decimal point
        assert_eq!(format_number_unicode(1.0), "1");
        assert_eq!(format_number_unicode(-1.0), "-1");
    }

    #[test]
    fn test_zero_formatting_all_formats() {
        // Test that 0.0 is handled specially in all formatting functions
        let zero_expr = Expr::Number(0.0);
        let one_expr = Expr::Number(1.0);
        let neg_zero_expr = Expr::Number(-0.0);

        // Unicode formatting
        assert_eq!(to_unicode(&zero_expr), "0.0");
        assert_eq!(to_unicode(&neg_zero_expr), "0.0");
        assert_eq!(to_unicode(&one_expr), "1");

        // LaTeX formatting
        assert_eq!(to_latex(&zero_expr), "0.0");
        assert_eq!(to_latex(&neg_zero_expr), "0.0");
        assert_eq!(to_latex(&one_expr), "1");

        // ASCII formatting
        assert_eq!(to_ascii(&zero_expr), "0.0");
        assert_eq!(to_ascii(&neg_zero_expr), "0.0");
        assert_eq!(to_ascii(&one_expr), "1");
    }

    #[test]
    fn test_scientific_unicode() {
        assert_eq!(format_scientific_unicode("1.80e-12"), "1.80×10⁻¹²");
        assert_eq!(format_scientific_unicode("2.46e+19"), "2.46×10¹⁹");
    }

    #[test]
    fn test_expr_display() {
        let expr = Expr::Variable("O3".to_string());
        assert_eq!(format!("{expr}"), "O₃");

        let expr = Expr::Number(1.8e-12);
        assert_eq!(format!("{expr}"), "1.80×10⁻¹²");
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
            coupletype: None,
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

        // Test all three formatting functions
        assert_eq!(to_unicode(&pre_expr), "x⁻");
        assert_eq!(to_latex(&pre_expr), "{x}^{-}");
        assert_eq!(to_ascii(&pre_expr), "x-");

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

        assert_eq!(to_unicode(&complex_pre), "a + b⁻");
        assert_eq!(to_latex(&complex_pre), "{a + b}^{-}");
        assert_eq!(to_ascii(&complex_pre), "a + b-");

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
        assert_eq!(to_latex(&pow), "{(a + b)}^{2}");
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
        assert_eq!(to_unicode(&small), "1.80×10⁻¹²");
        assert_eq!(to_latex(&small), "1.80 \\times 10^{-12}");
        assert_eq!(to_ascii(&small), "1.80e-12");
    }
}
