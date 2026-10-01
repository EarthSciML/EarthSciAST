//! Expressions as Typst math.
//!
//! The output is Typst math source, the text an author would write between
//! `$ … $`, and it reads like the core's LaTeX rendering
//! (`earthsci_ast::to_latex`):
//!
//! - **Operators** are laid out natively, with the LaTeX backend's
//!   parenthesization rules (`display.rs`, `format_operator`): the same
//!   precedence table, unary minus binding tighter than `+` and looser than
//!   `*` (so `-(a + b)` keeps its parentheses and `-a dot.op b` needs none),
//!   `a + (-b)` printed as `a - b`, and a right operand of `-` or `/`
//!   parenthesized only when it binds no tighter. Division is an explicit
//!   `frac(a, b)`, a derivative `frac(partial x, partial t)`, and a product
//!   joins its factors with `dot.op`.
//! - **Names and numbers** reuse the core's decisions by translating its LaTeX
//!   for that one leaf into Typst: `\mathrm{H_2O}` becomes `"H"_2"O"`,
//!   `\lambda` becomes `lambda`, `T_{298}` becomes `T_298`, and
//!   `1.8 \times 10^{-12}` becomes `1.8 times 10^(-12)`. A name whose LaTeX
//!   falls outside the small subset the core emits is printed as upright text,
//!   so the output is always valid Typst.
//! - **Array and structural operators** (`faq`, `index`, `makearray`, …) have
//!   no place in box models; they print as upright text holding their Unicode
//!   rendering.
//!
//! Typst behaviors this relies on: a bare multi-letter word is a variable
//! lookup, so upright words are quoted and math-italic letters are separate
//! tokens (`C a`, which Typst sets side by side); whitespace between two
//! quoted strings prints as a space, so the parts of a chemical formula are
//! joined without any; and consecutive subscripts nest (`k_a_b` puts `b`
//! under `a`), so the core's double subscripts are merged into one,
//! comma-separated.

use earthsci_ast::{Equation, Expr, ExpressionNode, to_latex, to_unicode};

/// Render an expression as Typst math source (the text between `$ … $`).
pub fn expr_to_typst(expr: &Expr) -> String {
    render(expr, 0)
}

/// Render an equation as Typst math source, `lhs = rhs`.
pub fn equation_to_typst(eq: &Equation) -> String {
    format!("{} = {}", expr_to_typst(&eq.lhs), expr_to_typst(&eq.rhs))
}

/// Render a variable name as Typst math source.
pub fn name_to_typst(name: &str) -> String {
    let latex = to_latex(&Expr::Variable(name.to_string()));
    latex_leaf_to_typst(&latex).unwrap_or_else(|| quote(name))
}

// ---------------------------------------------------------------------------
// Operators
// ---------------------------------------------------------------------------

/// Operator precedence, higher binding tighter: the core's `PRECEDENCE` table.
fn precedence(op: &str) -> i32 {
    match op {
        "+" | "-" => 1,
        "*" | "/" => 2,
        "^" => 3,
        _ => 0,
    }
}

/// The precedence a unary minus's operand renders at: additive, so a negated
/// sum keeps its parentheses, `-(a + b)`, while a product or power does not,
/// `-a dot.op b`. The core's `UMINUS_OPERAND_PARENT_PREC`.
const UNARY_MINUS_OPERAND: i32 = 1;

/// A unary-minus operand the precedence table leaves bare but the core
/// parenthesizes: a comparison or logical operator, which this table, like
/// the core's, gives precedence 0. (The core also parenthesizes a power of a
/// literal, `-(2^2)`, for its parser's sake; typeset, `-2^2` already reads as
/// that.)
fn unary_minus_needs_parens(operand: &Expr) -> bool {
    matches!(operand, Expr::Operator(n)
        if matches!(n.op.as_str(), "<" | ">" | "<=" | ">=" | "==" | "!=" | "=" | "and" | "or"))
}

/// Operators the core renders from fields other than `args` (its
/// `format_structural_op`). They print as upright text here.
const STRUCTURAL_OPS: &[&str] = &[
    "const",
    "true",
    "fn",
    "enum",
    "index",
    "broadcast",
    "integral",
    "table_lookup",
    "apply_expression_template",
    "makearray",
    "reshape",
    "transpose",
    "concat",
    "intersect_polygon",
    "polygon_intersection_area",
    "faq",
    "argmin",
    "argmax",
];

fn render(expr: &Expr, parent_prec: i32) -> String {
    match expr {
        Expr::Number(n) => number_to_typst(*n),
        Expr::Integer(n) => number_to_typst(*n as f64),
        Expr::Variable(name) => name_to_typst(name),
        Expr::Operator(node) => render_operator(expr, node, parent_prec),
    }
}

/// Render at precedence 0, for a delimited position: a call's arguments, a
/// fraction's numerator or denominator, an exponent.
fn r0(expr: &Expr) -> String {
    render(expr, 0)
}

/// `callee(a, b, …)`.
fn call(callee: &str, args: &[Expr]) -> String {
    let inner = args.iter().map(r0).collect::<Vec<_>>().join(", ");
    format!("{callee}({inner})")
}

/// A call to an operator Typst does not know: its name as an upright
/// operator, `op("grad")(x)`.
fn named_call(name: &str, args: &[Expr]) -> String {
    call(&format!("op({})", quote(name)), args)
}

/// An operand, parenthesized when it is an operator node.
fn wrap_if_op(expr: &Expr) -> String {
    let s = r0(expr);
    if matches!(expr, Expr::Operator(_)) {
        format!("({s})")
    } else {
        s
    }
}

fn render_operator(expr: &Expr, node: &ExpressionNode, parent_prec: i32) -> String {
    let op = node.op.as_str();
    if STRUCTURAL_OPS.contains(&op) {
        return quote(&to_unicode(expr));
    }
    let args = node.args.as_slice();
    let op_prec = precedence(op);
    let needs_parens = op_prec > 0 && op_prec <= parent_prec;

    // A fraction groups its own operands, but still takes parentheses from its
    // parent when precedence demands them (`(frac(b, c))^(d)`), as `\frac`
    // does in the core.
    if op == "/" && args.len() == 2 {
        let frac = format!("frac({}, {})", r0(&args[0]), r0(&args[1]));
        return if needs_parens {
            format!("({frac})")
        } else {
            frac
        };
    }

    let result = match op {
        "+" => {
            if let Some(s) = sum_as_difference(args, op_prec) {
                s
            } else if args.len() >= 2 {
                args.iter()
                    .map(|a| render(a, op_prec - 1))
                    .collect::<Vec<_>>()
                    .join(" + ")
            } else {
                named_call("+", args)
            }
        }
        "-" => match args {
            [a] if unary_minus_needs_parens(a) => format!("-({})", r0(a)),
            [a] => format!("-{}", render(a, UNARY_MINUS_OPERAND)),
            // Left-associative: the right operand keeps parentheses when it
            // binds no tighter (`a - (b - c)`), not when it binds tighter.
            [a, b] => format!("{} - {}", render(a, op_prec - 1), render(b, op_prec)),
            _ => named_call("-", args),
        },
        "*" => {
            if args.len() >= 2 {
                // The core's LaTeX juxtaposes the factors when one is a name
                // already written as LaTeX; so does this.
                let juxtapose = args
                    .iter()
                    .any(|a| matches!(a, Expr::Variable(v) if v.contains('\\')));
                let sep = if juxtapose { " " } else { " dot.op " };
                args.iter()
                    .map(|a| render(a, op_prec - 1))
                    .collect::<Vec<_>>()
                    .join(sep)
            } else {
                named_call("⋅", args)
            }
        }
        // Binary `/` returned above.
        "/" => named_call("÷", args),
        "^" => match args {
            [base, exponent] => format!("{}^({})", power_base(base, op_prec), r0(exponent)),
            _ => named_call("^", args),
        },
        "D" => match args {
            [arg] => {
                // An absent `wrt` means `t` (esm-spec §4.2).
                let wrt = node.wrt.as_deref().unwrap_or("t");
                format!(
                    "frac(partial {}, partial {})",
                    wrap_if_op(arg),
                    name_to_typst(wrt)
                )
            }
            _ => named_call("D", args),
        },
        ">" => binary(args, ">", ">"),
        "<" => binary(args, "<", "<"),
        ">=" => binary(args, ">=", "≥"),
        "<=" => binary(args, "<=", "≤"),
        "=" | "==" => binary(args, "=", "="),
        "!=" => binary(args, "!=", "≠"),
        "and" => joined(args, " and ", "∧"),
        "or" => joined(args, " or ", "∨"),
        "not" => match args {
            [arg] => format!("not {}", wrap_if_op(arg)),
            _ => named_call("¬", args),
        },
        "exp" => call("exp", args),
        "ifelse" => match args {
            // A quad between the columns, as LaTeX's `cases` has.
            [cond, then, otherwise] => format!(
                "cases({} quad & \"if\" {}, {} quad & \"otherwise\")",
                r0(then),
                r0(cond),
                r0(otherwise)
            ),
            _ => named_call("ifelse", args),
        },
        "log" => {
            if args.len() == 1 {
                call("ln", args)
            } else {
                call("log", args)
            }
        }
        "log10" => call("log_10", args),
        // Typst's `sqrt`, `abs`, `floor` and `ceil` take one body.
        "sqrt" | "abs" | "floor" | "ceil" => {
            if args.len() == 1 {
                call(op, args)
            } else {
                named_call(op, args)
            }
        }
        "sign" => named_call("sgn", args),
        "asin" => call("arcsin", args),
        "acos" => call("arccos", args),
        "atan" => call("arctan", args),
        "asinh" => call("sinh^(-1)", args),
        "acosh" => call("cosh^(-1)", args),
        "atanh" => call("tanh^(-1)", args),
        "min" | "max" | "sin" | "cos" | "tan" | "sinh" | "cosh" | "tanh" => call(op, args),
        // `atan2`, `Pre`, the open-tier sugar (`grad`, `div`, `laplacian`) and
        // any user op: the name as an upright operator.
        _ => named_call(op, args),
    };

    if needs_parens {
        format!("({result})")
    } else {
        result
    }
}

/// `a + (-b)` renders as `a - b`, as in the core.
fn sum_as_difference(args: &[Expr], op_prec: i32) -> Option<String> {
    let [a, Expr::Operator(neg)] = args else {
        return None;
    };
    let [b] = neg.args.as_slice() else {
        return None;
    };
    if neg.op != "-" {
        return None;
    }
    Some(format!(
        "{} - {}",
        render(a, op_prec - 1),
        render(b, op_prec)
    ))
}

/// `a SYM b`, or a call form at any other arity.
fn binary(args: &[Expr], infix: &str, call_symbol: &str) -> String {
    match args {
        [a, b] => format!("{} {infix} {}", r0(a), r0(b)),
        _ => named_call(call_symbol, args),
    }
}

/// Operands joined by `sep`, or a call form with fewer than two.
fn joined(args: &[Expr], sep: &str, call_symbol: &str) -> String {
    if args.len() >= 2 {
        args.iter().map(r0).collect::<Vec<_>>().join(sep)
    } else {
        named_call(call_symbol, args)
    }
}

/// The base of a power. Beyond the precedence rule, a leaf that already
/// carries a superscript or prints as several tokens with a sign or spaces (a
/// negative or scientific number, a charged species) is parenthesized, since
/// `x^a^b` would nest and `1.8 times 10^(-12)^(2)` would misread. The core's
/// LaTeX has the same two cases, and emits a double superscript there.
fn power_base(base: &Expr, op_prec: i32) -> String {
    let s = render(base, op_prec);
    let plain = match base {
        Expr::Number(_) | Expr::Integer(_) => !s.starts_with('-') && !s.contains(' '),
        Expr::Variable(_) => !s.contains('^'),
        Expr::Operator(_) => true,
    };
    if plain { s } else { format!("({s})") }
}

// ---------------------------------------------------------------------------
// Leaves: the core's LaTeX for one name or number, translated
// ---------------------------------------------------------------------------

/// A number, in the core's display format.
fn number_to_typst(n: f64) -> String {
    let latex = to_latex(&Expr::Number(n));
    latex_leaf_to_typst(&latex).unwrap_or_else(|| quote(&latex))
}

/// A Typst string literal, which math sets as upright text.
fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}

/// One atom of a leaf's LaTeX: a base and its scripts.
#[derive(Debug, Clone)]
struct Atom {
    base: Base,
    /// Subscripts. More than one is LaTeX's double subscript, which this
    /// renders as one comma-separated subscript.
    subs: Vec<Vec<Atom>>,
    sup: Option<Vec<Atom>>,
}

#[derive(Debug, Clone)]
enum Base {
    /// A run of characters, upright (`\mathrm`, `\text`) or math italic.
    Text { text: String, upright: bool },
    /// A Typst symbol name (`lambda`, `partial`, `times`).
    Symbol(&'static str),
    /// A braced group.
    Group(Vec<Atom>),
}

impl Atom {
    fn new(base: Base) -> Atom {
        Atom {
            base,
            subs: Vec::new(),
            sup: None,
        }
    }

    fn text(text: String, upright: bool) -> Atom {
        Atom::new(Base::Text { text, upright })
    }

    fn is_scripted(&self) -> bool {
        !self.subs.is_empty() || self.sup.is_some()
    }
}

/// Translate the LaTeX the core prints for one name or number into Typst, or
/// `None` when it uses anything outside the subset handled here.
fn latex_leaf_to_typst(latex: &str) -> Option<String> {
    let chars: Vec<char> = latex.chars().collect();
    let mut parser = Parser { chars, pos: 0 };
    let atoms = parser.seq(false, false)?;
    if parser.pos != parser.chars.len() {
        return None;
    }
    render_seq(&atoms)
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    /// Atoms until the end of input, or the closing brace when `in_group`.
    fn seq(&mut self, upright: bool, in_group: bool) -> Option<Vec<Atom>> {
        let mut atoms: Vec<Atom> = Vec::new();
        // LaTeX ignores spaces in math, but they end a run of characters
        // (`1.8 \times 10`).
        let mut run_open = false;
        while let Some(c) = self.peek() {
            self.pos += 1;
            match c {
                '}' => return in_group.then_some(atoms),
                '{' => {
                    let inner = self.seq(upright, true)?;
                    atoms.push(Atom::new(Base::Group(inner)));
                    run_open = false;
                }
                '_' | '^' => {
                    let script = self.script(upright)?;
                    let last = atoms.last_mut()?;
                    if c == '_' {
                        last.subs.push(script);
                    } else if last.sup.replace(script).is_some() {
                        return None;
                    }
                    run_open = false;
                }
                '\\' => match self.command()? {
                    Command::Atom(atom) => {
                        atoms.push(atom);
                        run_open = false;
                    }
                    Command::Char(ch) => {
                        push_char(&mut atoms, ch, upright, run_open);
                        run_open = true;
                    }
                },
                ' ' => run_open = false,
                _ => {
                    push_char(&mut atoms, c, upright, run_open);
                    run_open = true;
                }
            }
        }
        (!in_group).then_some(atoms)
    }

    /// A sub- or superscript's argument: a braced group, a command, or one
    /// character.
    fn script(&mut self, upright: bool) -> Option<Vec<Atom>> {
        let c = self.peek()?;
        self.pos += 1;
        match c {
            '{' => self.seq(upright, true),
            '\\' => Some(vec![match self.command()? {
                Command::Atom(atom) => atom,
                Command::Char(ch) => Atom::text(ch.to_string(), upright),
            }]),
            '}' | '_' | '^' | ' ' => None,
            _ => Some(vec![Atom::text(c.to_string(), upright)]),
        }
    }

    /// A command, after its backslash.
    fn command(&mut self) -> Option<Command> {
        let first = self.peek()?;
        if !first.is_ascii_alphabetic() {
            self.pos += 1;
            return match first {
                '_' | '{' | '}' | '%' | '&' | '#' | '$' => Some(Command::Char(first)),
                _ => None,
            };
        }
        let start = self.pos;
        while self.peek().is_some_and(|c| c.is_ascii_alphabetic()) {
            self.pos += 1;
        }
        let name: String = self.chars[start..self.pos].iter().collect();
        match name.as_str() {
            "mathrm" | "text" => {
                if self.peek() != Some('{') {
                    return None;
                }
                self.pos += 1;
                let inner = self.seq(true, true)?;
                Some(Command::Atom(Atom::new(Base::Group(inner))))
            }
            _ => symbol_name(&name).map(|s| Command::Atom(Atom::new(Base::Symbol(s)))),
        }
    }
}

enum Command {
    Atom(Atom),
    /// An escaped character (`\_`), part of the surrounding run.
    Char(char),
}

/// Append a character to the open run, or start a new one.
fn push_char(atoms: &mut Vec<Atom>, c: char, upright: bool, run_open: bool) {
    if run_open
        && let Some(atom) = atoms.last_mut()
        && !atom.is_scripted()
        && let Base::Text {
            text,
            upright: run_upright,
        } = &mut atom.base
        && *run_upright == upright
    {
        text.push(c);
        return;
    }
    atoms.push(Atom::text(c.to_string(), upright));
}

/// The Typst symbol for a LaTeX command the core puts in a leaf.
fn symbol_name(command: &str) -> Option<&'static str> {
    const SYMBOLS: &[&str] = &[
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa",
        "lambda", "mu", "nu", "xi", "omicron", "pi", "rho", "sigma", "tau", "upsilon", "phi",
        "chi", "psi", "omega", "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon",
        "Phi", "Psi", "Omega", "partial", "times",
    ];
    if command == "infty" {
        return Some("infinity");
    }
    SYMBOLS.iter().find(|s| **s == command).copied()
}

/// Render a sequence of atoms, separating two pieces only where they would
/// otherwise run together into one token.
fn render_seq(atoms: &[Atom]) -> Option<String> {
    let mut out = String::new();
    for atom in atoms {
        let s = render_atom(atom)?;
        push_piece(&mut out, &s);
    }
    Some(out)
}

/// Append `piece`, with a space when the two would merge into one token
/// (`alpha` then `x`). Never a space otherwise: between two strings it would
/// print.
fn push_piece(out: &mut String, piece: &str) {
    let wordish = |c: char| c.is_alphanumeric() || c == '.';
    if out.chars().last().is_some_and(wordish) && piece.chars().next().is_some_and(wordish) {
        out.push(' ');
    }
    out.push_str(piece);
}

fn render_atom(atom: &Atom) -> Option<String> {
    if atom.is_scripted() {
        match &atom.base {
            // Scripts on a group attach to its last atom, which reads the same.
            Base::Group(inner) => {
                let mut inner = inner.clone();
                let last = inner.last_mut()?;
                last.subs.extend(atom.subs.iter().cloned());
                if let Some(sup) = &atom.sup
                    && last.sup.replace(sup.clone()).is_some()
                {
                    return None;
                }
                return render_seq(&inner);
            }
            // Scripts on an italic run attach to its last token (a letter or
            // a number), as in LaTeX.
            Base::Text {
                text,
                upright: false,
            } => {
                let mut tokens = italic_tokens(text)?;
                let last = tokens.pop()?;
                let mut out = String::new();
                for t in &tokens {
                    push_piece(&mut out, t);
                }
                push_piece(&mut out, &attach_scripts(last, atom)?);
                return Some(out);
            }
            _ => {}
        }
    }
    let s = match &atom.base {
        Base::Text { text, upright } => render_text(text, *upright)?,
        Base::Symbol(name) => (*name).to_string(),
        Base::Group(inner) => render_seq(inner)?,
    };
    attach_scripts(s, atom)
}

/// `base` followed by `atom`'s scripts.
fn attach_scripts(mut s: String, atom: &Atom) -> Option<String> {
    if s.is_empty() {
        return None;
    }
    if !atom.subs.is_empty() {
        let parts = atom
            .subs
            .iter()
            .map(|sub| render_seq(sub))
            .collect::<Option<Vec<_>>>()?;
        s.push('_');
        s.push_str(&script_arg(&parts.join(", ")));
    }
    if let Some(sup) = &atom.sup {
        s.push('^');
        s.push_str(&script_arg(&render_seq(sup)?));
    }
    Some(s)
}

/// A run of characters. Upright text is a string literal, except a whole
/// number, which Typst sets upright anyway. In a math-italic run each letter
/// is its own token (`Ca` → `C a`, set side by side) and each digit run a
/// number.
fn render_text(text: &str, upright: bool) -> Option<String> {
    if upright && !text.chars().all(|c| c.is_ascii_digit()) {
        return Some(quote(text));
    }
    let mut out = String::new();
    for t in &italic_tokens(text)? {
        push_piece(&mut out, t);
    }
    Some(out)
}

/// The tokens of a math-italic run: single letters, digit runs, signs and
/// primes. Any other character is not one the core writes there, and refuses
/// the run.
fn italic_tokens(text: &str) -> Option<Vec<String>> {
    let mut tokens: Vec<String> = Vec::new();
    for c in text.chars() {
        let numeric = c.is_ascii_digit() || c == '.';
        match tokens.last_mut() {
            Some(t) if numeric && t.chars().all(|d| d.is_ascii_digit() || d == '.') => t.push(c),
            _ if numeric || c.is_alphabetic() || matches!(c, '-' | '+' | '\'') => {
                tokens.push(c.to_string())
            }
            _ => return None,
        }
    }
    (!tokens.is_empty()).then_some(tokens)
}

/// A rendered script argument: bare when it is one token, else in parentheses
/// (which Typst drops around a script).
fn script_arg(s: &str) -> String {
    if is_single_token(s) {
        s.to_string()
    } else {
        format!("({s})")
    }
}

/// Whether Typst reads `s` as one atom: a letter, a whole number, a symbol
/// name, or one string literal.
fn is_single_token(s: &str) -> bool {
    let Some(first) = s.chars().next() else {
        return false;
    };
    if first == '"' {
        // One literal: its first unescaped closing quote ends `s`.
        let mut escaped = false;
        for (i, c) in s.char_indices().skip(1) {
            match c {
                '\\' if !escaped => escaped = true,
                '"' if !escaped => return i + 1 == s.len(),
                _ => escaped = false,
            }
        }
        return false;
    }
    if s.chars().all(|c| c.is_ascii_digit()) {
        return true;
    }
    if s.chars().count() == 1 {
        return first.is_alphabetic();
    }
    symbol_name(s).is_some() || s == "infinity"
}

#[cfg(test)]
mod tests {
    use super::*;
    use earthsci_ast::parse_expression;

    fn t(src: &str) -> String {
        expr_to_typst(&parse_expression(src).unwrap())
    }

    #[test]
    fn names() {
        assert_eq!(name_to_typst("x"), "x");
        assert_eq!(name_to_typst("lambda"), "lambda");
        assert_eq!(name_to_typst("H2O"), r#""H"_2"O""#);
        assert_eq!(name_to_typst("T298"), "T_298");
        assert_eq!(name_to_typst("jNO2"), r#"j_("NO"_2)"#);
        assert_eq!(name_to_typst("Ca"), "C a");
        assert_eq!(name_to_typst("rate_constant"), r#""rate_constant""#);
        assert_eq!(name_to_typst("k_NO2_O3"), r#"k_("NO"_2, "O"_3)"#);
    }

    #[test]
    fn numbers() {
        assert_eq!(number_to_typst(1.8e-12), "1.8 times 10^(-12)");
        assert_eq!(number_to_typst(-2.5), "-2.5");
        assert_eq!(number_to_typst(f64::NEG_INFINITY), "-infinity");
        assert_eq!(number_to_typst(f64::NAN), r#""NaN""#);
    }

    #[test]
    fn operators() {
        assert_eq!(t("D(N, t)"), "frac(partial N, partial t)");
        assert_eq!(t("-lambda * N"), "-lambda dot.op N");
        assert_eq!(t("(a + b) / c"), "frac(a + b, c)");
        assert_eq!(t("(a + b)^2"), "(a + b)^(2)");
    }
}
