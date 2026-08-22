//! `parse_expression` — the INVERSE of [`crate::display::to_ascii`] for authoring
//! EarthSciAST expressions (esm-spec §4.2) as text.
//!
//! The concrete syntax IS what `to_ascii` emits, so the pair round-trips:
//! `to_ascii(&parse_expression(s)?) == s`. This is a direct port of the
//! TypeScript reference implementation (`pkg/earthsci-ast-ts/src/parse-expression.ts`),
//! whose module docstring is the specification; the shared conformance corpus
//! `tests/conformance/expression_parse/cases.json` is the contract both must
//! satisfy.
//!
//! Coverage:
//!  - scalar tier: arithmetic, powers, comparisons, boolean logic, elementary
//!    functions, derivatives (`D(x)/Dt` and `D(x, t)`), open/user function calls;
//!  - array & call-shaped tier: array literals `[…]` (`const`), indexing
//!    `a[i, j]` (`index`), dotted closed-function calls `datetime.year(t)` (`fn`),
//!    the `true` literal, and `integral` / `reshape` / `transpose` / `concat`;
//!  - reduction & array-query tier: `aggregate` reductions
//!    `sum[i] (expr) where {i in set, j in lo:hi} join(a=b) if pred distinct
//!    key=k [semiring=…]` (all clause shapes), the `argmin`/`argmax` arg-witnesses,
//!    template application `name<binding = value, …>`
//!    (`apply_expression_template`), the geometry ops
//!    `polygon_intersection_area(a, b, manifold=…)` and
//!    `intersect_polygon(a, b, manifold=…[, id=…])`, the `table_lookup` bracket
//!    surface `visc[T=temp]` / `k_rate[T=temp, p=pres]:1`, and the
//!    piecewise-region array `makearray([lo:hi, …] = value, …)`.
//!
//! Aggregate `args` is a derived operand cache the printer doesn't emit; it's
//! reconstructed best-effort (see [`derive_aggregate_args`]) and is
//! reprint-neutral.
//!
//! Still deferred (they need a dedicated surface syntax): `broadcast` and
//! `enum`. Those are refused with an [`ExpressionParseError`], as is the call
//! spelling `table_lookup(…)` (its real surface is `visc[T=temp]`).
//!
//! Design rules: multiplication is ALWAYS explicit (`k * A`) — no implicit
//! juxtaposition, because identifiers are multi-letter (`NO2`, `O3`, `k_photo`).
//!
//! The module is pure text→AST: no filesystem, clock or thread APIs, so it
//! compiles for `wasm32` unchanged.

use crate::types::{Equation, Expr, ExpressionNode, JoinClause, RangeSpec, RegionBound};
use serde_json::Value;
use std::collections::HashMap;

/// Returned when an expression string cannot be parsed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{message} (at character {pos})")]
pub struct ExpressionParseError {
    /// Human-readable description of what went wrong.
    pub message: String,
    /// 0-based **character** offset into the source where parsing failed.
    ///
    /// A character offset, not a byte offset: identifiers legitimately contain
    /// non-ASCII name constituents (`∂u_∂z`, `∇phi`, Greek variable names), and
    /// the TypeScript / Python / Julia bindings all report character offsets.
    pub pos: usize,
}

impl ExpressionParseError {
    fn new(message: impl Into<String>, pos: usize) -> Self {
        Self {
            message: message.into(),
            pos,
        }
    }
}

type PResult<T> = Result<T, ExpressionParseError>;

// --- operator tables ---------------------------------------------------------

/// Binary infix operators the parser recognizes. `^` is the sole
/// right-associative one (mirrors the printer's non-associative-right handling).
const INFIX: &[&str] = &[
    "or", "and", "==", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "^",
];

/// Infix precedence, higher binds tighter. This mirrors the `precedence` field
/// of the TypeScript `op-registry.ts` table (the single cross-binding source of
/// truth for parenthesization), so the parser can never drift from the printer.
/// Anything absent renders as a function call and binds tightest.
const FUNCTION_PRECEDENCE: i32 = 8;

fn op_precedence(op: &str) -> i32 {
    match op {
        "or" => 1,
        "and" => 2,
        ">" | "<" | ">=" | "<=" | "==" | "!=" | "=" => 3,
        "+" | "-" => 4,
        "*" | "/" => 5,
        "not" => 6,
        "^" => 7,
        _ => FUNCTION_PRECEDENCE,
    }
}

/// Unary `-` binds LOOSELY (at `-`'s own additive precedence), so it swallows a
/// whole additive/multiplicative operand — matching how the printer renders
/// `-(Ea/(R*T))` as `-Ea / (R * T)` with no inner parentheses.
const UMINUS_MIN: i32 = 4;
/// `not` binds TIGHTLY (`not p and q` == `(not p) and q`).
const NOT_MIN: i32 = 6;
/// Template binding values bind at additive precedence so the closing `>` — a
/// comparison operator — is never swallowed as `value > …`.
const TEMPLATE_ARG_MIN: i32 = 4;

/// Structural ops whose defining data lives OUTSIDE `args` AND which have no
/// text surface yet — refused, pending a dedicated syntax pass.
///
/// `table_lookup` IS listed even though it round-trips: its surface is the
/// bracket form `visc[T=temp]`, parsed in [`Parser::parse_table_lookup`] without
/// going through [`make_call`], so the CALL spelling `table_lookup(a)` — which
/// the printer never emits — stays refused. `intersect_polygon` is absent: it
/// has a surface now that its `id` is printed.
const STRUCTURAL_OPS: &[&str] = &["table_lookup", "broadcast", "enum"];

/// The aggregate reduction symbols `to_ascii` emits. Each maps to a default
/// `reduce` when no explicit `[semiring=…]` supersedes it; `sum` and `any` carry
/// no `reduce` field (plain `+` / semiring-only).
const AGG_SYMS: &[&str] = &["sum", "prod", "max", "min", "any"];
/// Arg-witness reductions: `argmin[g] (expr) where {…}`.
const ARGWITNESS_SYMS: &[&str] = &["argmin", "argmax"];

fn reduce_by_sym(sym: &str) -> Option<&'static str> {
    match sym {
        "prod" => Some("*"),
        "max" => Some("max"),
        "min" => Some("min"),
        _ => None, // `sum` and `any` carry no `reduce`
    }
}

// --- tokenizer ---------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Num,
    Name,
    Op,
    LParen,
    RParen,
    LBrack,
    RBrack,
    LBrace,
    RBrace,
    /// Range bound separator (`lo:hi`).
    Colon,
    /// Aggregate join-clause separator.
    Semi,
    Comma,
    /// A lone `=`, the equation separator (NOT `==`).
    Eq,
    Eof,
}

#[derive(Debug, Clone)]
struct Tok {
    kind: Kind,
    /// Payload for [`Kind::Name`] and [`Kind::Op`].
    text: String,
    /// Payload for [`Kind::Num`].
    num: f64,
    /// 0-based character offset of the token's first character.
    pos: usize,
}

impl Tok {
    fn simple(kind: Kind, pos: usize) -> Self {
        Tok {
            kind,
            text: String::new(),
            num: 0.0,
            pos,
        }
    }
    /// True when this is the contextual keyword / operator word `v`.
    fn is(&self, kind: Kind, v: &str) -> bool {
        self.kind == kind && self.text == v
    }
}

/// Longest-match-first so `>=`/`<=`/`==`/`!=` beat `>`/`<`/`=`.
const MULTI_OPS: &[&str] = &[">=", "<=", "==", "!="];
const WORD_OPS: &[&str] = &["and", "or", "not"];

fn is_single_op(c: char) -> bool {
    matches!(c, '+' | '-' | '*' | '/' | '^' | '>' | '<')
}

/// Identifiers allow Unicode letters (Greek variables like `ΔF_net`, `Φ`),
/// Unicode numbers (subscript digits in names like `k₀`), and dots (qualified
/// refs like `Emissions.NO`, and dotted closed-function names like
/// `datetime.year`). A leading digit still can't start an identifier (numbers
/// lex first).
///
/// `∂` (U+2202) and `∇` (U+2207) are also name constituents: source variables
/// are sometimes named with them (`∂u_∂z`), and `to_ascii` prints such names
/// verbatim. Those glyphs are NOT ascii operators — the ascii derivative surface
/// is `D(x)/Dt` — so accepting them keeps the parser an exact inverse. The
/// unicode big-operator display forms (`∑ ∫ ∈ ⟨⟩`) remain refused.
fn is_name_start(c: char) -> bool {
    c == '_' || c == '∂' || c == '∇' || c.is_alphabetic()
}

fn is_name_continue(c: char) -> bool {
    c == '_' || c == '.' || c == '∂' || c == '∇' || c.is_alphanumeric()
}

/// Match the JS `NUM_RE` (`\d+\.?\d*|\.\d+` with an optional `[eE][+-]?\d+`)
/// against `src[i..]`, returning the length in CHARACTERS. The source is already
/// a char slice, so every index here is a character index.
fn match_number(src: &[char], i: usize) -> Option<usize> {
    let mut j = i;
    let digits = |j: &mut usize| {
        let start = *j;
        while *j < src.len() && src[*j].is_ascii_digit() {
            *j += 1;
        }
        *j > start
    };
    if digits(&mut j) {
        // \d+\.?\d*
        if j < src.len() && src[j] == '.' {
            j += 1;
            digits(&mut j);
        }
    } else if j < src.len() && src[j] == '.' {
        // \.\d+
        j += 1;
        if !digits(&mut j) {
            return None;
        }
    } else {
        return None;
    }
    // (?:[eE][+-]?\d+)?
    if j < src.len() && (src[j] == 'e' || src[j] == 'E') {
        let mut k = j + 1;
        if k < src.len() && (src[k] == '+' || src[k] == '-') {
            k += 1;
        }
        let mut m = k;
        if digits(&mut m) {
            j = m;
        }
    }
    Some(j - i)
}

fn tokenize(src: &str) -> PResult<Vec<Tok>> {
    let chars: Vec<char> = src.chars().collect();
    let mut toks: Vec<Tok> = Vec::new();
    let mut i = 0usize;
    while i < chars.len() {
        let c = chars[i];
        if matches!(c, ' ' | '\t' | '\n' | '\r') {
            i += 1;
            continue;
        }
        let simple = match c {
            '(' => Some(Kind::LParen),
            ')' => Some(Kind::RParen),
            '[' => Some(Kind::LBrack),
            ']' => Some(Kind::RBrack),
            '{' => Some(Kind::LBrace),
            '}' => Some(Kind::RBrace),
            ':' => Some(Kind::Colon),
            ';' => Some(Kind::Semi),
            ',' => Some(Kind::Comma),
            _ => None,
        };
        if let Some(kind) = simple {
            toks.push(Tok::simple(kind, i));
            i += 1;
            continue;
        }
        if i + 1 < chars.len() {
            let two: String = chars[i..i + 2].iter().collect();
            if MULTI_OPS.contains(&two.as_str()) {
                toks.push(Tok {
                    kind: Kind::Op,
                    text: two,
                    num: 0.0,
                    pos: i,
                });
                i += 2;
                continue;
            }
        }
        if c == '=' {
            // lone '=' (the '==' case was handled just above)
            toks.push(Tok::simple(Kind::Eq, i));
            i += 1;
            continue;
        }
        if is_single_op(c) {
            toks.push(Tok {
                kind: Kind::Op,
                text: c.to_string(),
                num: 0.0,
                pos: i,
            });
            i += 1;
            continue;
        }
        // A number must START with a digit or a `.`; a lone `.` (no digits
        // after) matches nothing and falls through to the error path below.
        let num_len = if c == '.' || c.is_ascii_digit() {
            match_number(&chars, i)
        } else {
            None
        };
        if let Some(len) = num_len {
            let text: String = chars[i..i + len].iter().collect();
            let num: f64 = text
                .parse()
                .map_err(|_| ExpressionParseError::new(format!("Malformed number {text:?}"), i))?;
            toks.push(Tok {
                kind: Kind::Num,
                text,
                num,
                pos: i,
            });
            i += len;
            continue;
        }
        if is_name_start(c) {
            let mut j = i + 1;
            while j < chars.len() && is_name_continue(chars[j]) {
                j += 1;
            }
            let text: String = chars[i..j].iter().collect();
            let kind = if WORD_OPS.contains(&text.as_str()) {
                Kind::Op
            } else {
                Kind::Name
            };
            toks.push(Tok {
                kind,
                text,
                num: 0.0,
                pos: i,
            });
            i = j;
            continue;
        }
        // The big-operator / unicode display forms (∑ ∫ ∈ ⟨⟩ …) are rendered by
        // `to_unicode`/`to_latex`, not the ascii form this parser inverts; refuse
        // them so a caller routes such input elsewhere.
        if !c.is_ascii() {
            return Err(ExpressionParseError::new(
                format!("unicode operator syntax ({c:?}) — use the ascii text form"),
                i,
            ));
        }
        return Err(ExpressionParseError::new(
            format!("Unexpected character {c:?}"),
            i,
        ));
    }
    toks.push(Tok::simple(Kind::Eof, chars.len()));
    Ok(toks)
}

// --- parser (Pratt / precedence-climbing) ------------------------------------

struct Parser {
    toks: Vec<Tok>,
    p: usize,
}

impl Parser {
    fn new(toks: Vec<Tok>) -> Self {
        Parser { toks, p: 0 }
    }

    fn peek(&self) -> &Tok {
        &self.toks[(self.p).min(self.toks.len() - 1)]
    }
    fn peek_at(&self, k: usize) -> &Tok {
        &self.toks[(self.p + k).min(self.toks.len() - 1)]
    }
    fn next(&mut self) -> Tok {
        let t = self.toks[self.p.min(self.toks.len() - 1)].clone();
        if self.p < self.toks.len() {
            self.p += 1;
        }
        t
    }
    fn expect(&mut self, kind: Kind, what: &str) -> PResult<Tok> {
        if self.peek().kind != kind {
            return Err(self.fail_here(format!("Expected {what}")));
        }
        Ok(self.next())
    }
    fn expect_op(&mut self, v: &str, what: &str) -> PResult<()> {
        if !self.peek().is(Kind::Op, v) {
            return Err(self.fail_here(format!("Expected {what}")));
        }
        self.next();
        Ok(())
    }
    fn fail_here(&self, msg: impl Into<String>) -> ExpressionParseError {
        ExpressionParseError::new(msg, self.peek().pos)
    }
    /// True when the next token is the contextual keyword name `v`.
    fn at_word(&self, v: &str) -> bool {
        self.peek().is(Kind::Name, v)
    }

    fn parse_entry(&mut self) -> PResult<Expr> {
        let e = self.parse_expr(0)?;
        if self.peek().kind != Kind::Eof {
            return Err(self.fail_here("Unexpected trailing input"));
        }
        Ok(flatten(&e))
    }

    fn parse_expr(&mut self, min_prec: i32) -> PResult<Expr> {
        let mut left = self.parse_prefix()?;
        loop {
            let (op, prec) = {
                let t = self.peek();
                if t.kind != Kind::Op || !INFIX.contains(&t.text.as_str()) {
                    break;
                }
                (t.text.clone(), op_precedence(&t.text))
            };
            if prec < min_prec {
                break;
            }
            self.next();
            // `^` is the sole right-associative operator.
            let rhs = self.parse_expr(if op == "^" { prec } else { prec + 1 })?;
            left = node(&op, vec![left, rhs]);
        }
        Ok(left)
    }

    fn parse_prefix(&mut self) -> PResult<Expr> {
        // `-` directly before a number is a NEGATIVE LITERAL, not a unary-minus
        // node. Both print as `-1.3`, but only a literal reprints WITHOUT parens
        // as an operand (`x^-1.3`, not `x^(-1.3)`) — matching how `to_ascii`
        // emits negative constants (e.g. Arrhenius `(300/T)^-1.3`).
        if self.peek().is(Kind::Op, "-") && self.peek_at(1).kind == Kind::Num {
            self.next();
            let n = self.next();
            return Ok(Expr::Number(-n.num));
        }
        if self.peek().kind == Kind::Op && (self.peek().text == "-" || self.peek().text == "not") {
            let op = self.next().text;
            let min = if op == "not" { NOT_MIN } else { UMINUS_MIN };
            let operand = self.parse_expr(min)?;
            return Ok(node(&op, vec![operand]));
        }
        self.parse_postfix()
    }

    /// Atom, then postfix `[…]` indexing, then the derivative sugar
    /// `D(expr)/D<name>`.
    fn parse_postfix(&mut self) -> PResult<Expr> {
        let mut n = self.parse_atom()?;
        while self.peek().kind == Kind::LBrack {
            // A trailing `[semiring=…]` is an aggregate suffix, never an index —
            // leave it for parse_aggregate's tail (it can follow a `key=`/`if`
            // expression).
            if self.peek_at(1).is(Kind::Name, "semiring") {
                break;
            }
            // `name[axis=expr, …]` is a `table_lookup` (format_structural_op),
            // not an index: `=` is never an expression operator (only `==` is),
            // so a `name` `=` pair inside the brackets discriminates the two
            // unambiguously. Only a bare variable can name a table.
            if matches!(n, Expr::Variable(_))
                && self.peek_at(1).kind == Kind::Name
                && self.peek_at(2).kind == Kind::Eq
            {
                let Expr::Variable(table) = n else {
                    unreachable!("matched above")
                };
                n = self.parse_table_lookup(table)?;
                continue;
            }
            self.next(); // '['
            let mut idx = vec![self.parse_expr(0)?];
            while self.peek().kind == Kind::Comma {
                self.next();
                idx.push(self.parse_expr(0)?);
            }
            self.expect(Kind::RBrack, "']'")?;
            let mut args = vec![n];
            args.extend(idx);
            n = node("index", args);
        }
        // `D(x)` followed by `/Dt` is the derivative surface form.
        if let Expr::Operator(d) = &n
            && d.op == "D"
            && self.peek().is(Kind::Op, "/")
        {
            let name_tok = self.peek_at(1).clone();
            if name_tok.kind == Kind::Name
                && name_tok.text.chars().count() > 1
                && name_tok.text.starts_with('D')
            {
                self.next(); // '/'
                self.next(); // 'D<var>'
                let mut out = ExpressionNode {
                    op: "D".to_string(),
                    args: d.args.clone(),
                    ..Default::default()
                };
                out.wrt = Some(name_tok.text.chars().skip(1).collect());
                return Ok(Expr::operator(out));
            }
        }
        Ok(n)
    }

    fn parse_atom(&mut self) -> PResult<Expr> {
        let t = self.next();
        match t.kind {
            Kind::Num => Ok(Expr::Number(t.num)),
            Kind::LParen => {
                let e = self.parse_expr(0)?;
                self.expect(Kind::RParen, "')'")?;
                Ok(e)
            }
            // A leading `[` is a const array literal (`[1, 2, 3]`).
            Kind::LBrack => {
                let value = self.parse_array_rest()?;
                let mut n = ExpressionNode {
                    op: "const".to_string(),
                    args: Vec::new(),
                    ..Default::default()
                };
                n.value = Some(Value::Array(value));
                Ok(Expr::operator(n))
            }
            Kind::Name => {
                let name = t.text;
                if name == "true" {
                    return Ok(node("true", Vec::new()));
                }
                // `makearray(region = value, …)` — a piecewise-region array. Its
                // arguments are `[lo:hi, …] = value` pairs, not plain call args,
                // so it needs its own parse rather than the generic call path.
                if name == "makearray" && self.peek().kind == Kind::LParen {
                    return self.parse_makearray();
                }
                if self.peek().kind == Kind::LParen {
                    return self.parse_call(&name);
                }
                // Template application `name<binding = value, …>` (or empty
                // `name<>`) → apply_expression_template. The `< NAME =` / `< >`
                // lookahead distinguishes it from a `<` comparison (whose RHS is
                // never a lone `=` nor an empty `>`).
                if self.peek().is(Kind::Op, "<")
                    && (self.peek_at(1).is(Kind::Op, ">")
                        || (self.peek_at(1).kind == Kind::Name && self.peek_at(2).kind == Kind::Eq))
                {
                    return self.parse_template(&name);
                }
                // Aggregate reduction `sym[out_idx] (expr) where {…} …`. Only
                // when the bracket is followed (past its match) by `(` —
                // otherwise `sym[i]` is an ordinary index into a variable that
                // happens to be named `sum`/`max`/….
                if AGG_SYMS.contains(&name.as_str())
                    && self.peek().kind == Kind::LBrack
                    && self.aggregate_ahead()
                {
                    return self.parse_aggregate(&name);
                }
                // Arg-witness reduction `argmin[g] (expr) where {…}`.
                if ARGWITNESS_SYMS.contains(&name.as_str())
                    && self.peek().kind == Kind::LBrack
                    && self.aggregate_ahead()
                {
                    return self.parse_arg_witness(&name);
                }
                Ok(Expr::Variable(name)) // bare variable / species / qualified ref
            }
            _ => Err(ExpressionParseError::new(
                "Expected a number, name, '(', or '['",
                t.pos,
            )),
        }
    }

    /// Parse the elements of an array literal after `[` up to and including `]`.
    fn parse_array_rest(&mut self) -> PResult<Vec<Value>> {
        let mut els: Vec<Value> = Vec::new();
        if self.peek().kind != Kind::RBrack {
            loop {
                if self.peek().kind == Kind::LBrack {
                    self.next();
                    els.push(Value::Array(self.parse_array_rest()?)); // nested raw array
                } else {
                    let e = self.parse_expr(0)?;
                    els.push(expr_to_value(&e, self.peek().pos)?);
                }
                if self.peek().kind == Kind::Comma {
                    self.next();
                    continue;
                }
                break;
            }
        }
        self.expect(Kind::RBrack, "']'")?;
        Ok(els)
    }

    fn parse_call(&mut self, name: &str) -> PResult<Expr> {
        self.next(); // '('
        let mut args: Vec<Expr> = Vec::new();
        // Insertion-ordered so the "unexpected k=…" diagnostic names the first
        // offending key, exactly like the TS reference's `Object.keys(named)[0]`.
        let mut named: Vec<(String, Expr)> = Vec::new();
        if self.peek().kind != Kind::RParen {
            loop {
                // A `key = value` argument (e.g. concat `axis=0`); a lone `=`
                // (not `==`) after a bare name marks it.
                if self.peek().kind == Kind::Name && self.peek_at(1).kind == Kind::Eq {
                    let key = self.next().text;
                    self.next(); // '='
                    let v = self.parse_expr(0)?;
                    named.push((key, v));
                } else {
                    args.push(self.parse_expr(0)?);
                }
                if self.peek().kind == Kind::Comma {
                    self.next();
                    continue;
                }
                break;
            }
        }
        self.expect(Kind::RParen, &format!("',' or ')' in call to {name}(...)"))?;
        make_call(name, args, named, self.peek().pos)
    }

    // --- aggregate / template (the reduction & array-query tier) -------------

    /// True when the `[` at the current position closes with a `]` immediately
    /// followed by `(` — the signature of an aggregate `sym[…] (expr)`, as
    /// opposed to plain indexing `sym[i]`. Scans balanced brackets, no consume.
    fn aggregate_ahead(&self) -> bool {
        let mut depth = 0i32;
        for i in self.p..self.toks.len() {
            match self.toks[i].kind {
                Kind::LBrack => depth += 1,
                Kind::RBrack => {
                    depth -= 1;
                    if depth == 0 {
                        return self.toks.get(i + 1).is_some_and(|t| t.kind == Kind::LParen);
                    }
                }
                _ => {}
            }
        }
        false
    }

    /// Parse an `aggregate` reduction (esm-spec §4.2) — the inverse of the
    /// printer's `formatAggregate`:
    ///
    /// ```text
    /// sym '[' out_idx ']' '(' expr ')' ('where' '{' ranges '}')? ('join' '(' … ')')?
    ///     ('if' filter)? 'distinct'? ('key' '=' expr)? ('[' 'semiring' '=' name ']')?
    /// ```
    fn parse_aggregate(&mut self, sym: &str) -> PResult<Expr> {
        self.next(); // '['
        let mut output_idx: Vec<String> = Vec::new();
        if self.peek().kind != Kind::RBrack {
            loop {
                let t = self.next();
                if t.kind != Kind::Name {
                    return Err(ExpressionParseError::new(
                        "Expected an output index name",
                        t.pos,
                    ));
                }
                output_idx.push(t.text);
                if self.peek().kind == Kind::Comma {
                    self.next();
                    continue;
                }
                break;
            }
        }
        self.expect(Kind::RBrack, "']' after aggregate output indices")?;
        self.expect(Kind::LParen, "'(' before the aggregate body")?;
        let expr = self.parse_expr(0)?;
        self.expect(Kind::RParen, "')' after the aggregate body")?;

        let mut ranges: HashMap<String, RangeSpec> = HashMap::new();
        if self.at_word("where") {
            self.next();
            ranges = self.parse_ranges()?;
        }
        let mut join: Vec<JoinClause> = Vec::new();
        if self.at_word("join") {
            self.next();
            join = self.parse_join()?;
        }
        let mut filter: Option<Expr> = None;
        if self.at_word("if") {
            self.next();
            filter = Some(self.parse_expr(0)?);
        }
        let mut distinct = false;
        if self.at_word("distinct") {
            self.next();
            distinct = true;
        }
        let mut key: Option<Expr> = None;
        if self.at_word("key") && self.peek_at(1).kind == Kind::Eq {
            self.next(); // 'key'
            self.next(); // '='
            key = Some(self.parse_expr(0)?);
        }
        // `id=<name>` (RFC §6.1 node identity), emitted by `format_aggregate`
        // after `key=`. A bare-name clause, so it adds no bracket ambiguity.
        let id = self.parse_id_clause()?;
        let mut semiring: Option<String> = None;
        if self.peek().kind == Kind::LBrack && self.peek_at(1).is(Kind::Name, "semiring") {
            self.next(); // '['
            self.next(); // 'semiring'
            self.expect(Kind::Eq, "'=' in [semiring=…]")?;
            let nm = self.next();
            if nm.kind != Kind::Name {
                return Err(ExpressionParseError::new(
                    "Expected a semiring name",
                    nm.pos,
                ));
            }
            semiring = Some(nm.text);
            self.expect(Kind::RBrack, "']' after [semiring=…]")?;
        }
        // A join with no explicit semiring is the sum-of-products contraction.
        if semiring.is_none() && !join.is_empty() {
            semiring = Some("sum_product".to_string());
        }

        let mut n = ExpressionNode {
            op: "aggregate".to_string(),
            args: derive_aggregate_args(&expr, &join, filter.as_ref(), key.as_ref()),
            ..Default::default()
        };
        n.output_idx = Some(output_idx);
        if semiring.is_some() {
            n.semiring = semiring;
        } else {
            n.reduce = reduce_by_sym(sym).map(str::to_string);
        }
        n.ranges = Some(ranges);
        if !join.is_empty() {
            n.join = Some(join);
        }
        n.filter = filter.map(Box::new);
        if distinct {
            n.distinct = Some(true);
        }
        n.key = key.map(Box::new);
        n.id = id;
        n.expr = Some(Box::new(expr));
        Ok(Expr::operator(n))
    }

    /// Parse an `argmin` / `argmax` arg-witness — the inverse of the printer's
    /// `formatArgWitness`: `op '[' arg ']' '(' expr ')' ('where' '{' ranges '}')?`.
    fn parse_arg_witness(&mut self, op: &str) -> PResult<Expr> {
        self.next(); // '['
        let at = self.next();
        if at.kind != Kind::Name {
            return Err(ExpressionParseError::new(
                "Expected the arg-witness index name",
                at.pos,
            ));
        }
        self.expect(Kind::RBrack, "']' after the arg-witness index")?;
        self.expect(Kind::LParen, "'(' before the arg-witness body")?;
        let expr = self.parse_expr(0)?;
        self.expect(Kind::RParen, "')' after the arg-witness body")?;
        let mut ranges: HashMap<String, RangeSpec> = HashMap::new();
        if self.at_word("where") {
            self.next();
            ranges = self.parse_ranges()?;
        }
        // `id=<name>` (RFC §6.1 node identity), emitted by `format_arg_witness`
        // after the where-clause. Mirrors the aggregate tail.
        let id = self.parse_id_clause()?;
        let mut n = ExpressionNode {
            op: op.to_string(),
            args: derive_aggregate_args(&expr, &[], None, None),
            ..Default::default()
        };
        n.arg = Some(at.text);
        n.ranges = Some(ranges);
        n.expr = Some(Box::new(expr));
        n.id = id;
        Ok(Expr::operator(n))
    }

    /// Read an optional `id=<name>` clause (RFC §6.1 stable node identity) off
    /// the tail of an aggregate / arg-witness. Consumes nothing when absent.
    fn parse_id_clause(&mut self) -> PResult<Option<String>> {
        if !(self.at_word("id") && self.peek_at(1).kind == Kind::Eq) {
            return Ok(None);
        }
        self.next(); // 'id'
        self.next(); // '='
        let nm = self.next();
        if nm.kind != Kind::Name {
            return Err(ExpressionParseError::new(
                "Expected a name after id=",
                nm.pos,
            ));
        }
        Ok(Some(nm.text))
    }

    /// Parse a `table_lookup` from the surface `format_structural_op` emits:
    /// `table '[' axis '=' expr (',' axis '=' expr)* ']' (':' <integer>)?`, e.g.
    /// `visc[T=temp]` and `k_rate[T=temp, p=pres]:1`. The printer sorts the axis
    /// names, so the reconstructed `axes` map reprints identically.
    fn parse_table_lookup(&mut self, table: String) -> PResult<Expr> {
        self.expect(Kind::LBrack, "'['")?;
        let mut axes: HashMap<String, Expr> = HashMap::new();
        loop {
            let nm = self.next();
            if nm.kind != Kind::Name {
                return Err(ExpressionParseError::new(
                    "Expected an axis name in table[axis=…]",
                    nm.pos,
                ));
            }
            self.expect(Kind::Eq, "'=' in table[axis=…]")?;
            let v = self.parse_expr(0)?;
            axes.insert(nm.text, v);
            if self.peek().kind == Kind::Comma {
                self.next();
                continue;
            }
            break;
        }
        self.expect(Kind::RBrack, "']' after table[axis=…]")?;
        let mut n = ExpressionNode {
            op: "table_lookup".to_string(),
            args: Vec::new(),
            ..Default::default()
        };
        n.table = Some(table);
        n.axes = Some(axes);
        // The optional `:N` output selector picks one column of a multi-output
        // table. Emitted as a JSON integer, never a float, so the wire form is
        // byte-identical to the other bindings'.
        if self.peek().kind == Kind::Colon {
            self.next();
            let out = self.next();
            if out.kind != Kind::Num || out.num.fract() != 0.0 || !out.num.is_finite() {
                return Err(ExpressionParseError::new(
                    "Expected an integer output index after table[…]:",
                    out.pos,
                ));
            }
            n.output = Some(Value::from(out.num as i64));
        }
        Ok(Expr::operator(n))
    }

    /// Parse a `{ k in <rhs>, … }` where-body into a ranges map.
    fn parse_ranges(&mut self) -> PResult<HashMap<String, RangeSpec>> {
        self.expect(Kind::LBrace, "'{' after where")?;
        let mut ranges: HashMap<String, RangeSpec> = HashMap::new();
        if self.peek().kind != Kind::RBrace {
            loop {
                let kt = self.next();
                if kt.kind != Kind::Name {
                    return Err(ExpressionParseError::new(
                        "Expected a range index name",
                        kt.pos,
                    ));
                }
                if !self.at_word("in") {
                    return Err(self.fail_here("Expected 'in' in a range clause"));
                }
                self.next(); // 'in'
                let rhs = self.parse_range_rhs()?;
                ranges.insert(kt.text, rhs);
                if self.peek().kind == Kind::Comma {
                    self.next();
                    continue;
                }
                break;
            }
        }
        self.expect(Kind::RBrace, "'}' to close the where clause")?;
        Ok(ranges)
    }

    /// One range RHS: `set` → `{from}`; `set(a, b)` → `{from, of}`;
    /// `lo:hi` → `[lo, hi]`.
    fn parse_range_rhs(&mut self) -> PResult<RangeSpec> {
        let pos = self.peek().pos;
        let bound = self.parse_expr(0)?;
        if self.peek().kind == Kind::Colon {
            self.next();
            let hi_pos = self.peek().pos;
            let hi = self.parse_expr(0)?;
            let lo = expr_as_i64(&bound).ok_or_else(|| {
                ExpressionParseError::new("a range bound must be an integer literal", pos)
            })?;
            let hi = expr_as_i64(&hi).ok_or_else(|| {
                ExpressionParseError::new("a range bound must be an integer literal", hi_pos)
            })?;
            return Ok(RangeSpec::Interval([lo, hi]));
        }
        if let Expr::Variable(name) = &bound {
            return Ok(RangeSpec::IndexSetRef {
                from: name.clone(),
                of: None,
            });
        }
        // `k in set(of1, of2)` prints as a generic call → {from, of}.
        if let Expr::Operator(n) = &bound
            && n.op.starts_with(|c: char| c == '_' || c.is_alphabetic())
        {
            let mut of = Vec::with_capacity(n.args.len());
            for a in &n.args {
                match a {
                    Expr::Variable(s) => of.push(s.clone()),
                    _ => {
                        return Err(self.fail_here("range set arguments must be names"));
                    }
                }
            }
            return Ok(RangeSpec::IndexSetRef {
                from: n.op.clone(),
                of: Some(of),
            });
        }
        Err(self.fail_here("malformed range (expected a set name, set(of…), or lo:hi)"))
    }

    /// Parse `( a=b, c=d ; e=f )` → `[{on:[[a,b],[c,d]]}, {on:[[e,f]]}]`.
    fn parse_join(&mut self) -> PResult<Vec<JoinClause>> {
        self.expect(Kind::LParen, "'(' after join")?;
        let mut clauses: Vec<JoinClause> = Vec::new();
        let mut cur: Vec<[String; 2]> = Vec::new();
        if self.peek().kind != Kind::RParen {
            loop {
                let a = self.next();
                if a.kind != Kind::Name {
                    return Err(ExpressionParseError::new("Expected a join key name", a.pos));
                }
                self.expect(Kind::Eq, "'=' in a join pair")?;
                let b = self.next();
                if b.kind != Kind::Name {
                    return Err(ExpressionParseError::new("Expected a join key name", b.pos));
                }
                cur.push([a.text, b.text]);
                if self.peek().kind == Kind::Comma {
                    self.next();
                    continue;
                }
                if self.peek().kind == Kind::Semi {
                    self.next();
                    clauses.push(JoinClause {
                        on: std::mem::take(&mut cur),
                        overlap: None,
                    });
                    continue;
                }
                break;
            }
        }
        clauses.push(JoinClause {
            on: cur,
            overlap: None,
        });
        self.expect(Kind::RParen, "')' to close join(…)")?;
        Ok(clauses)
    }

    /// Parse `name<binding = value, …>` (or empty `name<>`) →
    /// `apply_expression_template`.
    fn parse_template(&mut self, name: &str) -> PResult<Expr> {
        self.next(); // '<'
        let mut bindings: HashMap<String, Expr> = HashMap::new();
        while !self.peek().is(Kind::Op, ">") {
            let kt = self.next();
            if kt.kind != Kind::Name {
                return Err(ExpressionParseError::new(
                    "Expected a binding name in <…>",
                    kt.pos,
                ));
            }
            self.expect(Kind::Eq, "'=' in a template binding")?;
            let v = self.parse_expr(TEMPLATE_ARG_MIN)?;
            bindings.insert(kt.text, v);
            if self.peek().kind == Kind::Comma {
                self.next();
                continue;
            }
            break;
        }
        self.expect_op(">", "'>' to close a template application")?;
        let mut n = ExpressionNode {
            op: "apply_expression_template".to_string(),
            args: Vec::new(),
            ..Default::default()
        };
        n.name = Some(name.to_string());
        n.bindings = Some(bindings);
        Ok(Expr::operator(n))
    }

    /// Parse a `makearray` piecewise-region array (esm-spec §4.3.2) — the
    /// inverse of the printer's makearray case:
    ///
    /// ```text
    /// 'makearray' '(' region '=' value ( ',' region '=' value )* ')'
    /// region := '[' bound ':' bound ( ',' bound ':' bound )* ']'
    /// ```
    ///
    /// `args` is always empty (the printer emits none); `regions` and `values`
    /// are positionally paired. Values are flattened to the canonical n-ary
    /// `+`/`*` form, like the top-level parse.
    fn parse_makearray(&mut self) -> PResult<Expr> {
        self.next(); // '('
        let mut regions: Vec<Vec<[RegionBound; 2]>> = Vec::new();
        let mut values: Vec<Expr> = Vec::new();
        if self.peek().kind != Kind::RParen {
            loop {
                self.expect(Kind::LBrack, "'[' to open a makearray region")?;
                let mut region: Vec<[RegionBound; 2]> = Vec::new();
                if self.peek().kind != Kind::RBrack {
                    loop {
                        let lo = self.parse_expr(0)?;
                        self.expect(Kind::Colon, "':' between a region's lo:hi bounds")?;
                        let hi = self.parse_expr(0)?;
                        region.push([region_bound(&lo), region_bound(&hi)]);
                        if self.peek().kind == Kind::Comma {
                            self.next();
                            continue;
                        }
                        break;
                    }
                }
                self.expect(Kind::RBrack, "']' to close a makearray region")?;
                self.expect(Kind::Eq, "'=' after a makearray region")?;
                regions.push(region);
                let v = self.parse_expr(0)?;
                values.push(flatten(&v));
                if self.peek().kind == Kind::Comma {
                    self.next();
                    continue;
                }
                break;
            }
        }
        self.expect(Kind::RParen, "')' to close makearray(...)")?;
        let mut n = ExpressionNode {
            op: "makearray".to_string(),
            args: Vec::new(),
            ..Default::default()
        };
        n.regions = Some(regions);
        n.values = Some(values);
        Ok(Expr::operator(n))
    }
}

// --- node construction helpers -----------------------------------------------

fn node(op: &str, args: Vec<Expr>) -> Expr {
    Expr::operator(ExpressionNode {
        op: op.to_string(),
        args,
        ..Default::default()
    })
}

/// The integer value of a numeric leaf, if it is one.
fn expr_as_i64(e: &Expr) -> Option<i64> {
    match e {
        Expr::Integer(i) => Some(*i),
        Expr::Number(n) if n.fract() == 0.0 && n.abs() < 9_223_372_036_854_775_808.0 => {
            Some(*n as i64)
        }
        _ => None,
    }
}

/// A `makearray` region bound: an integer literal, or an unfolded metaparameter
/// bound expression (`2:NLON - 1`), which esm-spec §9.7.6 folds to an integer at
/// load. The expression is flattened like any other, so `[1:NLON - 1 - 1]` is
/// not left in a non-canonical nested form.
fn region_bound(e: &Expr) -> RegionBound {
    match expr_as_i64(e) {
        Some(i) => RegionBound::Int(i),
        None => RegionBound::Expr(flatten(e)),
    }
}

/// Serialize a parsed element of an array literal to its JSON value.
fn expr_to_value(e: &Expr, pos: usize) -> PResult<Value> {
    serde_json::to_value(e).map_err(|err| {
        ExpressionParseError::new(format!("could not encode array element: {err}"), pos)
    })
}

/// Extract the raw element list of a parsed `const` array literal, or fail.
fn as_array_literal(e: &Expr, pos: usize) -> PResult<Vec<Value>> {
    if let Expr::Operator(n) = e
        && n.op == "const"
        && let Some(Value::Array(v)) = &n.value
    {
        return Ok(v.clone());
    }
    Err(ExpressionParseError::new(
        "expected an array literal [ ... ]",
        pos,
    ))
}

/// An array literal all of whose elements are integers (`shape` / `perm`).
fn as_int_array(e: &Expr, pos: usize) -> PResult<Vec<i64>> {
    let items = as_array_literal(e, pos)?;
    let mut out = Vec::with_capacity(items.len());
    for it in items {
        match it.as_i64() {
            Some(i) => out.push(i),
            None => {
                return Err(ExpressionParseError::new(
                    "expected an array of integers",
                    pos,
                ));
            }
        }
    }
    Ok(out)
}

fn no_named(named: &[(String, Expr)], name: &str, pos: usize) -> PResult<()> {
    match named.first() {
        None => Ok(()),
        Some((k, _)) => Err(ExpressionParseError::new(
            format!("unexpected {k}=… in {name}(...)"),
            pos,
        )),
    }
}

fn take_named(named: &[(String, Expr)], key: &str) -> Option<Expr> {
    named.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
}

fn make_call(name: &str, args: Vec<Expr>, named: Vec<(String, Expr)>, pos: usize) -> PResult<Expr> {
    // A dotted callee is a closed function — an `fn` node carrying the name.
    if name.contains('.') {
        no_named(&named, name, pos)?;
        let mut n = ExpressionNode {
            op: "fn".to_string(),
            args,
            ..Default::default()
        };
        n.name = Some(name.to_string());
        return Ok(Expr::operator(n));
    }
    // Call-shaped structural ops: reconstruct their non-`args` fields from the
    // positional / named arguments `to_ascii` renders.
    if name == "integral" && args.len() == 4 && matches!(args[1], Expr::Variable(_)) {
        no_named(&named, name, pos)?;
        let mut it = args.into_iter();
        let a0 = it.next().expect("arity checked");
        let var = match it.next().expect("arity checked") {
            Expr::Variable(s) => s,
            _ => unreachable!("matched above"),
        };
        let lower = it.next().expect("arity checked");
        let upper = it.next().expect("arity checked");
        let mut n = ExpressionNode {
            op: "integral".to_string(),
            args: vec![a0],
            ..Default::default()
        };
        n.int_var = Some(var);
        n.lower = Some(Box::new(lower));
        n.upper = Some(Box::new(upper));
        return Ok(Expr::operator(n));
    }
    if name == "reshape" && args.len() == 2 {
        no_named(&named, name, pos)?;
        let shape = as_int_array(&args[1], pos)?;
        let mut n = ExpressionNode {
            op: "reshape".to_string(),
            args: vec![args[0].clone()],
            ..Default::default()
        };
        n.shape = Some(shape);
        return Ok(Expr::operator(n));
    }
    if name == "transpose" && (args.len() == 1 || args.len() == 2) {
        no_named(&named, name, pos)?;
        let perm = if args.len() == 2 {
            Some(as_int_array(&args[1], pos)?)
        } else {
            None
        };
        let mut n = ExpressionNode {
            op: "transpose".to_string(),
            args: vec![args[0].clone()],
            ..Default::default()
        };
        n.perm = perm;
        return Ok(Expr::operator(n));
    }
    if name == "concat" {
        let Some(axis) = take_named(&named, "axis") else {
            return Err(ExpressionParseError::new(
                "concat(...) requires axis=<n>",
                pos,
            ));
        };
        let Some(axis) = expr_as_i64(&axis) else {
            return Err(ExpressionParseError::new(
                "concat(...) requires an integer axis=<n>",
                pos,
            ));
        };
        let mut n = ExpressionNode {
            op: "concat".to_string(),
            args,
            ..Default::default()
        };
        n.axis = Some(axis);
        return Ok(Expr::operator(n));
    }
    // Geometry ops `polygon_intersection_area(a, b, manifold=<name>)` and
    // `intersect_polygon(a, b, manifold=<name>[, id=<name>])`. `id` (RFC §6.1
    // node identity) is optional and only emitted by the printer when present.
    if name == "polygon_intersection_area" || name == "intersect_polygon" {
        let manifold = match take_named(&named, "manifold") {
            Some(Expr::Variable(s)) => s,
            _ => {
                return Err(ExpressionParseError::new(
                    format!("{name}(...) requires manifold=<name>"),
                    pos,
                ));
            }
        };
        if let Some((k, _)) = named.iter().find(|(k, _)| k != "manifold" && k != "id") {
            return Err(ExpressionParseError::new(
                format!("unexpected {k}=… in {name}(...)"),
                pos,
            ));
        }
        let mut n = ExpressionNode {
            op: name.to_string(),
            args,
            ..Default::default()
        };
        n.manifold = Some(manifold);
        if let Some(id) = take_named(&named, "id") {
            let Expr::Variable(id) = id else {
                return Err(ExpressionParseError::new(
                    format!("{name}(...) id=… must be a name"),
                    pos,
                ));
            };
            n.id = Some(id);
        }
        return Ok(Expr::operator(n));
    }
    no_named(&named, name, pos)?;
    if STRUCTURAL_OPS.contains(&name) {
        return Err(ExpressionParseError::new(
            format!("'{name}' is not yet expressible in the text form"),
            pos,
        ));
    }
    if name == "D" {
        // Friendly form `D(expr, t)` — wrt as an explicit second arg — in
        // addition to the `to_ascii` form `D(expr)/Dt` handled in parse_postfix.
        // Any other arity is a nonstandard / discretization `D` that the printer
        // emits via the generic call fallback; keep it a generic call.
        if args.len() == 2
            && let Expr::Variable(w) = &args[1]
        {
            let mut n = ExpressionNode {
                op: "D".to_string(),
                args: vec![args[0].clone()],
                ..Default::default()
            };
            n.wrt = Some(w.clone());
            return Ok(Expr::operator(n));
        }
        if args.len() == 1 {
            return Ok(node("D", args));
        }
    }
    Ok(node(name, args))
}

/// Best-effort reconstruction of an aggregate's `args` — its array operands.
///
/// `to_ascii` does NOT print `args` (it is a derived dependency cache), and the
/// authoritative set excludes parameter arrays by *declared role*, which needs
/// the variable table. From the printed structure alone we approximate it as:
/// the base of every `index(…)` in the body / filter / key, plus the names in
/// `join` clauses, in first-appearance order. This is reprint-neutral (the
/// printer ignores it) and a dependency superset (safe for graph / dead-code
/// analysis); an editor holding the symbol table should recompute it on save.
fn derive_aggregate_args(
    expr: &Expr,
    join: &[JoinClause],
    filter: Option<&Expr>,
    key: Option<&Expr>,
) -> Vec<Expr> {
    let mut out: Vec<String> = Vec::new();
    collect_index_bases(expr, &mut out);
    for c in join {
        for pair in &c.on {
            push_unique(&mut out, &pair[0]);
            push_unique(&mut out, &pair[1]);
        }
    }
    if let Some(f) = filter {
        collect_index_bases(f, &mut out);
    }
    if let Some(k) = key {
        collect_index_bases(k, &mut out);
    }
    out.into_iter().map(Expr::Variable).collect()
}

fn push_unique(out: &mut Vec<String>, name: &str) {
    if !out.iter().any(|n| n == name) {
        out.push(name.to_string());
    }
}

/// Pre-order walk adding the base name of every `index(base, …)` node reached.
fn collect_index_bases(e: &Expr, out: &mut Vec<String>) {
    let Expr::Operator(n) = e else { return };
    if n.op == "index"
        && let Some(Expr::Variable(base)) = n.args.first()
    {
        push_unique(out, base);
    }
    for a in &n.args {
        collect_index_bases(a, out);
    }
    for side in [n.lower.as_deref(), n.upper.as_deref(), n.expr.as_deref()]
        .into_iter()
        .flatten()
    {
        collect_index_bases(side, out);
    }
    if let Some(f) = n.filter.as_deref() {
        collect_index_bases(f, out);
    }
    if let Some(vs) = &n.values {
        for v in vs {
            collect_index_bases(v, out);
        }
    }
    if let Some(k) = n.key.as_deref() {
        collect_index_bases(k, out);
    }
    if let Some(b) = &n.bindings {
        let mut keys: Vec<&String> = b.keys().collect();
        keys.sort();
        for k in keys {
            collect_index_bases(&b[k], out);
        }
    }
    if let Some(ax) = &n.axes {
        let mut keys: Vec<&String> = ax.keys().collect();
        keys.sort();
        for k in keys {
            collect_index_bases(&ax[k], out);
        }
    }
}

// --- normalization -----------------------------------------------------------

/// Flatten nested same-op `+` / `*` in `args` into the n-ary form the printer
/// emits and authored ASTs use: `a + b + c` → one `+` with three args, not
/// left-nested pairs. (`-` and `/` are binary and stay as parsed.) Non-`args`
/// expression fields (integral bounds, aggregate bodies, …) are left as parsed.
fn flatten(e: &Expr) -> Expr {
    let Expr::Operator(nd) = e else {
        return e.clone();
    };
    let args: Vec<Expr> = nd.args.iter().map(flatten).collect();
    let mut out = (**nd).clone();
    if nd.op == "+" || nd.op == "*" {
        let mut merged: Vec<Expr> = Vec::with_capacity(args.len());
        for a in args {
            match &a {
                Expr::Operator(an) if an.op == nd.op && an.wrt.is_none() => {
                    merged.extend(an.args.iter().cloned());
                }
                _ => merged.push(a),
            }
        }
        out.args = merged;
    } else {
        out.args = args;
    }
    Expr::operator(out)
}

// --- public API --------------------------------------------------------------

/// Parse a single expression string into an AST expression — the inverse of
/// [`crate::display::to_ascii`].
///
/// # Errors
///
/// Returns an [`ExpressionParseError`] on malformed input, or on an operator
/// that has no text surface yet (`table_lookup`, `broadcast`, `enum`,
/// `intersect_polygon`).
///
/// # Examples
///
/// ```
/// use earthsci_ast::parse_expression::parse_expression;
/// use earthsci_ast::display::to_ascii;
///
/// let e = parse_expression("k1 * NO2 * O2 - k2 * O3")?;
/// assert_eq!(to_ascii(&e), "k1 * NO2 * O2 - k2 * O3");
/// # Ok::<(), earthsci_ast::parse_expression::ExpressionParseError>(())
/// ```
pub fn parse_expression(src: &str) -> Result<Expr, ExpressionParseError> {
    Parser::new(tokenize(src)?).parse_entry()
}

/// Parse `lhs = rhs` into an [`Equation`]. The top-level separator is a LONE
/// `=`; `==` (and `>=`/`<=`/`!=`) remain comparison operators within either side.
///
/// # Errors
///
/// Returns an [`ExpressionParseError`] when there is no top-level lone `=`, or
/// when either side fails to parse.
///
/// # Examples
///
/// ```
/// use earthsci_ast::parse_expression::parse_equation;
/// use earthsci_ast::display::to_ascii;
///
/// let eq = parse_equation("D(x)/Dt = k * A - x")?;
/// assert_eq!(to_ascii(&eq.lhs), "D(x)/Dt");
/// assert_eq!(to_ascii(&eq.rhs), "k * A - x");
/// # Ok::<(), earthsci_ast::parse_expression::ExpressionParseError>(())
/// ```
pub fn parse_equation(src: &str) -> Result<Equation, ExpressionParseError> {
    let toks = tokenize(src)?;
    let mut depth = 0i32;
    let mut angle = 0i32; // template `name<binding = value>` — its `=` is not a separator
    let mut split: Option<usize> = None;
    for i in 0..toks.len() {
        if split.is_some() {
            break;
        }
        let t = &toks[i];
        match t.kind {
            Kind::LParen | Kind::LBrack | Kind::LBrace => depth += 1,
            Kind::RParen | Kind::RBrack | Kind::RBrace => depth -= 1,
            Kind::Op
                if t.text == "<"
                    && toks.get(i + 1).is_some_and(|n| n.kind == Kind::Name)
                    && toks.get(i + 2).is_some_and(|n| n.kind == Kind::Eq) =>
            {
                angle += 1;
            }
            Kind::Op if t.text == ">" && angle > 0 => angle -= 1,
            // The FIRST top-level lone `=` splits lhs/rhs; a later binding /
            // `key=` `=` (legitimately present in an aggregate or template on
            // the rhs) is left intact.
            Kind::Eq if depth == 0 && angle == 0 => split = Some(i),
            _ => {}
        }
    }
    let Some(split) = split else {
        return Err(ExpressionParseError::new(
            "Expected 'lhs = rhs'",
            src.chars().count(),
        ));
    };
    let mut lhs_toks: Vec<Tok> = toks[..split].to_vec();
    lhs_toks.push(Tok::simple(Kind::Eof, toks[split].pos));
    let rhs_toks: Vec<Tok> = toks[split + 1..].to_vec();
    Ok(Equation {
        lhs: Parser::new(lhs_toks).parse_entry()?,
        rhs: Parser::new(rhs_toks).parse_entry()?,
    })
}
