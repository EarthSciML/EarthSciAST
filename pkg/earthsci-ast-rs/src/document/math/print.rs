//! The printer: expressions to tokens.
//!
//! Port of `formal/Esm/Document/Math/Print.lean`. [`pr`] prints an expression
//! with its precedence level; [`Out::at`] wraps it for a position that needs a
//! level at least `L`. The levels, loosest first (spec §4.1.1):
//!
//! | level | construct |
//! |---|---|
//! | 1 | `or` chain |
//! | 2 | `and` chain |
//! | 3 | a comparison |
//! | 4 | `+` chain, binary `-` |
//! | 5 | `*` chain, unary `-` |
//! | 6 | `not`; a derivative applied to a parenthesized operand |
//! | 7 | Typst fraction; a negative literal and a quantity |
//! | 8 | power |
//! | 9 | index |
//! | 10 | atoms |
//!
//! Which notation a node gets is decided from its exact JSON shape; anything
//! without a native or call notation (an annotated node, a field key that is
//! not an identifier, a shape no notation covers) prints in the generic escape
//! form.
//!
//! Not ported: `Math.AForm.json`. No executable path uses it; only the Lean
//! proofs do.

use super::expr::{
    REMOVED_OPS, Sym, is_e, is_formula, is_id_char, is_id_start, is_single, keys_sorted, look,
    name_ok, pieces, seg_ok, split_dots, sub_parts,
};
use super::token::{Kw, Sf, Tok};
use super::units::{self, Factor};
use crate::document::json::{JNum, Json};
use crate::document::number;
use crate::template_imports::NODE_HEADER_KEYS;

// ## Text pieces

/// `Math.escSet`: the characters escaped by a backslash inside `\mathit{}`,
/// `\operatorname{}`, `\esm{}` and a name subscript's `\mathrm{}`.
pub fn esc_set(c: char) -> bool {
    matches!(c, '_' | '^' | '\\' | '{' | '}')
}

/// `Math.escT`: escape the text of `\mathit{}` and the like.
pub fn esc_t(cs: &[char]) -> Vec<char> {
    let mut out = Vec::with_capacity(cs.len());
    for &c in cs {
        if esc_set(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// `Math.unescT`: undo [`esc_t`] (drop the backslash of every `\c` pair).
pub fn unesc_t(cs: &[char]) -> Vec<char> {
    let mut out = Vec::with_capacity(cs.len());
    let mut cs = cs;
    loop {
        match cs {
            ['\\', c, r @ ..] => {
                out.push(*c);
                cs = r;
            }
            [c, r @ ..] => {
                out.push(*c);
                cs = r;
            }
            [] => return out,
        }
    }
}

/// `Math.keySpecial`.
pub fn key_special(c: char) -> bool {
    matches!(c, '$' | '%' | '&' | '#' | '~' | '^' | '\\')
}

/// `Math.dig3`: three decimal digits.
pub fn dig3(n: u32) -> [char; 3] {
    [
        number::digit_char((n / 100 % 10) as u8),
        number::digit_char((n / 10 % 10) as u8),
        number::digit_char((n % 10) as u8),
    ]
}

/// `Math.escK`: escape a field key for `\mathrm{}`.
pub fn esc_k(cs: &[char]) -> Vec<char> {
    let mut out = Vec::new();
    for &c in cs {
        if key_special(c) {
            out.extend("{\\char".chars());
            out.extend(dig3(c as u32));
            out.push('}');
        } else if c == '_' || c == '{' || c == '}' {
            out.push('\\');
            out.push(c);
        } else {
            out.push(c);
        }
    }
    out
}

/// `Number.charDigit`: `c.toNat - 48`, saturating (any character, not only a
/// digit).
pub fn char_digit_nat(c: char) -> u64 {
    (c as u64).saturating_sub(48)
}

/// Lean's `Char.ofNat`: an invalid code point is `'\0'`.
pub fn char_of_nat(n: u64) -> char {
    u32::try_from(n)
        .ok()
        .and_then(char::from_u32)
        .unwrap_or('\0')
}

/// `Math.unescK`: undo [`esc_k`].
pub fn unesc_k(cs: &[char]) -> Vec<char> {
    let mut out = Vec::new();
    let mut cs = cs;
    loop {
        match cs {
            ['{', '\\', 'c', 'h', 'a', 'r', a, b, d, '}', r @ ..] => {
                out.push(char_of_nat(
                    100 * char_digit_nat(*a) + 10 * char_digit_nat(*b) + char_digit_nat(*d),
                ));
                cs = r;
            }
            ['\\', c, r @ ..] => {
                out.push(*c);
                cs = r;
            }
            [c, r @ ..] => {
                out.push(*c);
                cs = r;
            }
            [] => return out,
        }
    }
}

// ## The printing context

/// `Math.Ctx`: the surface and the symbol table.
#[derive(Clone, Copy, Debug)]
pub struct Ctx<'a> {
    pub sf: Sf,
    pub s: &'a Sym,
}

/// `Math.rpG`: the closing token of a grouping parenthesis.
pub fn rp_g(sf: Sf) -> Tok {
    Tok::Kw(if sf == Sf::Latex { Kw::Rpg } else { Kw::Rp })
}

/// `Math.grp`: grouping parentheses.
pub fn grp(sf: Sf, ts: &[Tok]) -> Vec<Tok> {
    let mut out = Vec::with_capacity(ts.len() + 2);
    out.push(Tok::Kw(Kw::Lpg));
    out.extend_from_slice(ts);
    out.push(rp_g(sf));
    out
}

/// `Math.sepBy`: items joined by a separator.
pub fn sep_by(sep: &[Tok], xs: Vec<Vec<Tok>>) -> Vec<Tok> {
    let mut out = Vec::new();
    for (i, x) in xs.into_iter().enumerate() {
        if i > 0 {
            out.extend_from_slice(sep);
        }
        out.extend(x);
    }
    out
}

fn kw(k: Kw) -> Tok {
    Tok::Kw(k)
}

fn cat(parts: &[&[Tok]]) -> Vec<Tok> {
    parts.concat()
}

fn s_of(cs: &[char]) -> String {
    cs.iter().collect()
}

// ## Names

/// `Math.baseTok`: a single letter or a Greek name as a token.
pub fn base_tok(g: &[char]) -> Tok {
    match g {
        [c] => Tok::Letter(*c),
        _ => Tok::Greek(s_of(g)),
    }
}

/// `Math.subTxt`: the subscript text of a name, upright.
pub fn sub_txt(sf: Sf, r: &[char]) -> Vec<Tok> {
    match sf {
        Sf::Latex => vec![kw(Kw::Us), kw(Kw::Lb), Tok::Rm(s_of(&esc_t(r))), kw(Kw::Rb)],
        Sf::Typst => vec![
            kw(Kw::Us),
            kw(Kw::Lpg),
            Tok::Ups(vec![(s_of(r), String::new())]),
            kw(Kw::Rp),
        ],
    }
}

/// `Math.formulaRaw`: the raw `\mathrm{}` content of a formula (counts as
/// `_{n}`).
pub fn formula_raw(g: &[char]) -> Vec<char> {
    let mut out = Vec::new();
    for (a, b) in pieces(g) {
        out.extend(a);
        if !b.is_empty() {
            out.push('_');
            out.push('{');
            out.extend(b);
            out.push('}');
        }
    }
    out
}

/// `Math.formTok`: a formula name.
pub fn form_tok(sf: Sf, g: &[char]) -> Tok {
    match sf {
        Sf::Latex => Tok::Rm(s_of(&formula_raw(g))),
        Sf::Typst => Tok::Ups(pieces(g).iter().map(|(a, b)| (s_of(a), s_of(b))).collect()),
    }
}

/// `Math.segToks`: one segment of a name, by its shape.
pub fn seg_toks(sf: Sf, g: &[char]) -> Vec<Tok> {
    if is_single(g) {
        vec![base_tok(g)]
    } else {
        match sub_parts(g) {
            Some((b, r)) => {
                let mut out = vec![base_tok(&b)];
                out.extend(sub_txt(sf, &r));
                out
            }
            None => {
                if is_formula(g) {
                    vec![form_tok(sf, g)]
                } else {
                    vec![Tok::It(s_of(g))]
                }
            }
        }
    }
}

/// `Math.explicitName`: an undeclared `e` or `d` prints in the explicit form.
pub fn explicit_name(s: &Sym, n: &str) -> bool {
    (n == "e" || n == "d") && !s.names.iter().any(|x| x == n)
}

/// `Math.nameToks`: the tokens of a name.
pub fn name_toks(c: Ctx, s: &str) -> Vec<Tok> {
    if explicit_name(c.s, s) {
        vec![Tok::It(s.to_string())]
    } else {
        let cs: Vec<char> = s.chars().collect();
        sep_by(
            &[kw(Kw::Sdot)],
            split_dots(&cs).iter().map(|g| seg_toks(c.sf, g)).collect(),
        )
    }
}

/// `Math.plainLast`: the last segment of a name prints with no subscript.
pub fn plain_last(s: &str) -> bool {
    let cs: Vec<char> = s.chars().collect();
    match split_dots(&cs).last() {
        Some(g) => is_single(g) || (sub_parts(g).is_none() && !is_formula(g)),
        None => false,
    }
}

// ## JSON inside escape nodes (LaTeX)

/// `Math.jsonToks`.
pub fn json_toks(j: &Json) -> Vec<Tok> {
    let mut out = Vec::new();
    json_toks_into(j, &mut out);
    out
}

fn json_toks_into(j: &Json, out: &mut Vec<Tok>) {
    match j {
        Json::Null => out.push(Tok::Word("null".into())),
        Json::Bool(true) => out.push(Tok::Word("true".into())),
        Json::Bool(false) => out.push(Tok::Word("false".into())),
        Json::Num(n) => out.push(Tok::Num(n.clone())),
        Json::Str(s) | Json::Math(s) => out.push(Tok::Jstr(s.clone())),
        Json::Arr(xs) => {
            out.push(kw(Kw::Lbk));
            for (i, x) in xs.iter().enumerate() {
                if i > 0 {
                    out.push(kw(Kw::Comma));
                }
                json_toks_into(x, out);
            }
            out.push(kw(Kw::Rbk));
        }
        Json::Obj(kvs) => {
            out.push(kw(Kw::Lb));
            for (i, (k, v)) in kvs.iter().enumerate() {
                if i > 0 {
                    out.push(kw(Kw::Comma));
                }
                out.push(Tok::Jstr(k.clone()));
                out.push(kw(Kw::Colon));
                json_toks_into(v, out);
            }
            out.push(kw(Kw::Rb));
        }
    }
}

// ## Operator tables

/// `Math.callOps`: core operators in the call form.
pub fn is_call_op(o: &str) -> bool {
    kind_of(o) == OpK::Call
}

/// `Math.fieldCallOps`: core operators with no notation of their own that
/// print in the call form, their fields as named arguments after `;` (when no
/// field annotates the node).
pub const FIELD_CALL_OPS: &[&str] = &[
    "broadcast",
    "reshape",
    "transpose",
    "concat",
    "faq",
    "makearray",
    "const",
];

/// `Math.reservedOpn`: names `\operatorname{…}` never means a template or an
/// open operator by.
pub fn reserved_opn(n: &str) -> bool {
    is_call_op(n) || ["D", "neg", "pow"].contains(&n) || REMOVED_OPS.contains(&n)
}

/// `Math.coreOps` (`coreOpNames` of `Notation`): the evaluable-core operators
/// other than the engine-internal precision marker and the build-time
/// `distinct`, which print in the open-operator form.
pub fn is_notation_core(o: &str) -> bool {
    use crate::op_registry::{CoreOp, OtherOp};
    CoreOp::from_name(o)
        .is_some_and(|c| !matches!(c, CoreOp::Other(OtherOp::Precision | OtherOp::Distinct)))
}

/// `Math.opnOK`: a name `\operatorname{…}` can carry: identifier characters and
/// dots.
pub fn opn_ok(s: &str) -> bool {
    let mut it = s.chars();
    match it.next() {
        None => false,
        Some(c) => is_id_start(c) && it.all(|d| is_id_char(d) || d == '.'),
    }
}

/// `Math.callFormOK`: an operator prints in the call form: an open operator,
/// or a core operator of [`FIELD_CALL_OPS`] none of whose fields is a node
/// header field (`Notation.annotatedNodeFields`; `op` is never among the
/// fields).
pub fn call_form_ok(o: &str, fs: &[(String, Json)]) -> bool {
    !is_notation_core(o)
        || (FIELD_CALL_OPS.contains(&o)
            && fs
                .iter()
                .all(|kv| !NODE_HEADER_KEYS.contains(&kv.0.as_str())))
}

/// The printer writes the node `kvs` of operator `o` and fields `fs` in the
/// call form `\operatorname{o}(…)`: the call form applies ([`call_form_ok`],
/// [`opn_ok`], no template of that name in scope) and no native spelling
/// does. Field keys are not checked: a key the printer would escape still reads
/// in the call form. The reader accepts a call written with fields only when
/// this holds.
pub fn prints_as_call(c: Ctx, o: &str, fs: &[(String, Json)], kvs: &[(String, Json)]) -> bool {
    call_form_ok(o, fs) && opn_ok(o) && tparams(c.s, o).is_none() && !native_form(c.sf, kvs)
}

/// The node prints in a native spelling of `faq`, `makearray` or a constant
/// array or quantity (the cases [`pr`] tries before the call form for a node
/// with fields).
pub fn native_form(sf: Sf, kvs: &[(String, Json)]) -> bool {
    faq_form(kvs).is_some_and(|f| faq_ok(&f))
        || mk_form(kvs).is_some_and(|m| mk_ok(&m))
        || const_native(sf, kvs)
}

/// The `const` cases of [`pr`]: an array with a native spelling, or a number or
/// such an array with a unit the surface spells.
pub fn const_native(sf: Sf, kvs: &[(String, Json)]) -> bool {
    let field = |i: usize, k: &str| kvs.get(i).filter(|kv| kv.0 == k).map(|kv| &kv.1);
    let empty_args = matches!(field(0, "args"), Some(Json::Arr(a)) if a.is_empty());
    let is_const = matches!(field(1, "op"), Some(Json::Str(o)) if o == "const");
    if !(empty_args && is_const) {
        return false;
    }
    match kvs.len() {
        3 => matches!(field(2, "value"), Some(v @ Json::Arr(_)) if arr_form(v).is_some()),
        4 => match (field(2, "units"), field(3, "value")) {
            (Some(Json::Str(u)), Some(Json::Num(_))) => units_ok(sf, u),
            (Some(Json::Str(u)), Some(v @ Json::Arr(_))) => {
                arr_form(v).is_some() && units_ok(sf, u)
            }
            _ => false,
        },
        _ => false,
    }
}

/// `Math.mathKeys`: the fields of a core operator in the call form that hold
/// an expression; the others print as JSON, even a string that is a name.
pub const MATH_KEYS: &[&str] = &["expr", "filter", "key"];

/// `Math.mathField`: a field of a call-form node prints as math: its value is
/// an expression and, for a core operator, the field holds one. An open
/// operator's fields are all read as math when they can be.
pub fn math_field(o: &str, kv: &(String, Json)) -> bool {
    is_e(&kv.1) && (!is_notation_core(o) || MATH_KEYS.contains(&kv.0.as_str()))
}

/// `Math.keyOK`: a field key printed upright in a call: an identifier.
pub fn key_ok(s: &str) -> bool {
    let cs: Vec<char> = s.chars().collect();
    seg_ok(&cs)
}

/// `Math.insKV`: sorted insertion by key.
pub fn ins_kv(kv: (String, Json), l: Vec<(String, Json)>) -> Vec<(String, Json)> {
    let mut l = l;
    let i = l.iter().position(|e| kv.0 < e.0).unwrap_or(l.len());
    l.insert(i, kv);
    l
}

/// `Math.fieldsOf`: the fields of a node other than `op` and `args`.
pub fn fields_of(kvs: &[(String, Json)]) -> Vec<(String, Json)> {
    kvs.iter()
        .filter(|kv| kv.0 != "op" && kv.0 != "args")
        .cloned()
        .collect()
}

/// `Math.mkNode`: a node from its operator, operands and other fields.
pub fn mk_node(o: &str, args: Vec<Json>, fs: Vec<(String, Json)>) -> Json {
    Json::Obj(ins_kv(
        ("args".into(), Json::Arr(args)),
        ins_kv(("op".into(), Json::Str(o.into())), fs),
    ))
}

/// `Math.node`: the plain two-field node.
pub fn node(o: &str, args: Vec<Json>) -> Json {
    Json::Obj(vec![
        ("args".into(), Json::Arr(args)),
        ("op".into(), Json::Str(o.into())),
    ])
}

/// `Math.isNegNum`.
pub fn is_neg_num(j: &Json) -> bool {
    match j {
        Json::Num(JNum::Int(z)) => *z < 0,
        Json::Num(JNum::Dec { neg, .. }) => *neg,
        _ => false,
    }
}

/// `Math.simpleTok`: Typst exponent and subscript tokens that need no
/// parentheses.
pub fn simple_tok(t: &Tok) -> bool {
    match t {
        Tok::Num(JNum::Int(z)) => 0 <= *z,
        Tok::Num(JNum::Dec { neg, e10, .. }) => !*neg && -4 <= *e10 && *e10 <= 5,
        Tok::Letter(_) | Tok::Greek(_) => true,
        _ => false,
    }
}

/// `Math.startsNum`.
pub fn starts_num(ts: &[Tok]) -> bool {
    matches!(ts.first(), Some(Tok::Num(_)))
}

/// `Math.tparams`: the template parameter list, when the symbol table knows it.
pub fn tparams<'a>(s: &'a Sym, n: &str) -> Option<&'a Vec<String>> {
    s.templates.iter().find(|t| t.0 == n).map(|t| &t.1)
}

fn nodup<T: PartialEq>(xs: &[T]) -> bool {
    xs.iter().enumerate().all(|(i, x)| !xs[..i].contains(x))
}

/// `Math.positional`: positional template arguments.
pub fn positional(s: &Sym, n: &str, bs: &[(String, Json)]) -> Option<Vec<String>> {
    let ps = tparams(s, n)?;
    if nodup(ps) && ps.len() == bs.len() && ps.iter().all(|p| look(p, bs).is_some()) {
        Some(ps.clone())
    } else {
        None
    }
}

/// `Math.rawB`: balanced text up to the `}` that closes depth 0; `\x` is one
/// unit.
pub fn raw_b(d: usize, cs: &[char]) -> Option<(Vec<char>, &[char])> {
    let mut out = Vec::new();
    let mut d = d;
    let mut cs = cs;
    loop {
        match cs {
            ['\\', c, r @ ..] => {
                out.push('\\');
                out.push(*c);
                cs = r;
            }
            ['}', r @ ..] => {
                if d == 0 {
                    return Some((out, r));
                }
                d -= 1;
                out.push('}');
                cs = r;
            }
            ['{', r @ ..] => {
                d += 1;
                out.push('{');
                cs = r;
            }
            [c, r @ ..] => {
                out.push(*c);
                cs = r;
            }
            [] => return None,
        }
    }
}

/// `Math.balOK`: raw text that [`raw_b`] reads back whole.
pub fn bal_ok(raw: &[char]) -> bool {
    let mut cs = raw.to_vec();
    cs.push('}');
    matches!(raw_b(0, &cs), Some((r, rest)) if r == raw && rest.is_empty())
}

/// `Math.factorsOf`: the two-sided factor list of a units string (`[]` when it
/// does not parse).
pub fn factors_of(u: &str) -> Vec<Factor> {
    crate::units::unit_two_sided_factors(u)
}

/// `Math.unitsOK`: the units of a quantity print typeset.
pub fn units_ok(sf: Sf, u: &str) -> bool {
    let l = factors_of(u);
    !l.is_empty()
        && crate::units::spell_unit_factors(&l) == u
        && l.iter()
            .all(|f| units::sym_ok(&f.0) && !num_traits::Zero::is_zero(&f.1))
        && match sf {
            Sf::Latex => {
                units::parse_latex(&units::latex(&l)).as_ref() == Some(&l)
                    && bal_ok(&units::latex_body(&l))
            }
            Sf::Typst => {
                let mut nd = units::num_factors(&l);
                nd.extend(units::den_factors(&l));
                nd == l
            }
        }
}

// ## The printer

/// `Math.wrap`: wrap a printed form for a position needing level `L`.
pub fn wrap(sf: Sf, l: usize, lvl: usize, ts: &[Tok]) -> Vec<Tok> {
    if l <= lvl { ts.to_vec() } else { grp(sf, ts) }
}

/// `Math.mulToks`: a `*` chain: juxtaposition, `\cdot` before a factor that
/// starts with a number.
pub fn mul_toks(xs: Vec<Vec<Tok>>) -> Vec<Tok> {
    let mut out = Vec::new();
    for (i, y) in xs.into_iter().enumerate() {
        if i > 0 && starts_num(&y) {
            out.push(kw(Kw::Cdot));
        }
        out.extend(y);
    }
    out
}

/// `Math.OpK`: the printer kind of a plain node's operator.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpK {
    Minus,
    Div,
    Pow,
    Lnot,
    Tru,
    Fls,
    Ite,
    Ic,
    Index,
    Cmp(Kw),
    Un(Kw),
    Plus,
    Times,
    Land,
    Lor,
    Mm(Kw),
    /// A `\nabla` form (`Math.OpK.nab`).
    Nab(NabK),
    Call,
    Other,
}

/// `Math.NabK`: the four defined operators with a `\nabla` form (esm-spec
/// §1.2): `grad`, `div`, `laplacian`, `curl`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NabK {
    Grad,
    Div,
    Lap,
    Curl,
}

/// `Math.kindOf` (with `Math.fnKw`, `Math.unKw`, `Math.cmpKw`,
/// `Math.kindTable` and `Math.callOps`): the notation each core operator
/// prints in. Unary functions with a native spelling get their keyword
/// (`log10` is `\log_{10}`); an open-tier name is [`OpK::Other`].
pub fn kind_of(o: &str) -> OpK {
    use crate::op_registry::{Comparison as C, CoreOp, OtherOp as O, UnaryFn as F};
    match o {
        "grad" => return OpK::Nab(NabK::Grad),
        "div" => return OpK::Nab(NabK::Div),
        "laplacian" => return OpK::Nab(NabK::Lap),
        "curl" => return OpK::Nab(NabK::Curl),
        _ => {}
    }
    let Some(core) = CoreOp::from_name(o) else {
        return OpK::Other;
    };
    match core {
        CoreOp::Unary(f) => match f {
            F::Exp => OpK::Un(Kw::Exp),
            F::Log => OpK::Un(Kw::Ln),
            F::Sin => OpK::Un(Kw::Sin),
            F::Cos => OpK::Un(Kw::Cos),
            F::Tan => OpK::Un(Kw::Tan),
            F::Asin => OpK::Un(Kw::Asin),
            F::Acos => OpK::Un(Kw::Acos),
            F::Atan => OpK::Un(Kw::Atan),
            F::Sinh => OpK::Un(Kw::Sinh),
            F::Cosh => OpK::Un(Kw::Cosh),
            F::Tanh => OpK::Un(Kw::Tanh),
            F::Log10 => OpK::Un(Kw::Log),
            F::Sqrt => OpK::Un(Kw::Sqrt),
            F::Abs => OpK::Un(Kw::Abs),
            F::Floor => OpK::Un(Kw::Floor),
            F::Ceil => OpK::Un(Kw::Ceil),
            F::Sign | F::Asinh | F::Acosh | F::Atanh => OpK::Call,
        },
        CoreOp::Compare(c) => OpK::Cmp(match c {
            C::Lt => Kw::Lt,
            C::Le => Kw::Le,
            C::Gt => Kw::Gt,
            C::Ge => Kw::Ge,
            C::Eq => Kw::Eq,
            C::Ne => Kw::Ne,
        }),
        CoreOp::Other(o) => match o {
            O::Sub => OpK::Minus,
            O::Div => OpK::Div,
            O::Pow => OpK::Pow,
            O::Not => OpK::Lnot,
            O::True => OpK::Tru,
            O::False => OpK::Fls,
            O::Ifelse => OpK::Ite,
            O::Ic => OpK::Ic,
            O::Index => OpK::Index,
            O::Add => OpK::Plus,
            O::Mul => OpK::Times,
            O::And => OpK::Land,
            O::Or => OpK::Lor,
            O::Min => OpK::Mm(Kw::Min),
            O::Max => OpK::Mm(Kw::Max),
            O::Atan2 | O::Pre | O::Enum => OpK::Call,
            O::PowWord
            | O::Neg
            | O::Precision
            | O::D
            | O::Const
            | O::ApplyExpressionTemplate
            | O::Faq
            | O::Makearray
            | O::Broadcast
            | O::Reshape
            | O::Transpose
            | O::Concat
            | O::Distinct => OpK::Other,
        },
    }
}

/// `Math.Out`: the printed form of an expression and its level. `crow` is the
/// form as the last rows of a `cases` block.
#[derive(Clone, Debug, PartialEq)]
pub struct Out {
    pub lvl: usize,
    pub toks: Vec<Tok>,
    pub crow: Vec<Tok>,
}

/// `Math.mkOut`.
pub fn mk_out(l: usize, t: Vec<Tok>) -> Out {
    let mut crow = t.clone();
    crow.push(kw(Kw::Amp));
    crow.push(Tok::Txt("otherwise".into()));
    Out {
        lvl: l,
        toks: t,
        crow,
    }
}

impl Out {
    /// `Math.Out.at`.
    pub fn at(&self, sf: Sf, l: usize) -> Vec<Tok> {
        wrap(sf, l, self.lvl, &self.toks)
    }
}

/// `Math.escToks`: the escape form: LaTeX `\esm{op}{fields}{args}`, Typst
/// `esm.node("op", #(fields), args)`.
pub fn esc_toks(sf: Sf, o: &str, fs: Vec<(String, Json)>, args: Vec<Vec<Tok>>) -> Vec<Tok> {
    match sf {
        Sf::Latex => {
            let mut out = vec![Tok::Esc(o.into()), kw(Kw::Lb)];
            out.extend(json_toks(&Json::Obj(fs)));
            out.extend([kw(Kw::Rb), kw(Kw::Lb)]);
            out.extend(sep_by(&[kw(Kw::Comma)], args));
            out.push(kw(Kw::Rb));
            out
        }
        Sf::Typst => {
            let mut out = vec![
                kw(Kw::Esmnode),
                kw(Kw::Lp),
                Tok::Txt(o.into()),
                kw(Kw::Comma),
                Tok::Code(Json::Obj(fs)),
            ];
            for a in args {
                out.push(kw(Kw::Comma));
                out.extend(a);
            }
            out.push(kw(Kw::Rp));
            out
        }
    }
}

/// `Math.lpC`: the call parenthesis.
pub fn lp_c(_sf: Sf) -> Tok {
    kw(Kw::Lp)
}

/// `Math.callToks`: `name(args)` with call parentheses.
pub fn call_toks(sf: Sf, head: Vec<Tok>, args: Vec<Vec<Tok>>) -> Vec<Tok> {
    let mut out = head;
    out.push(lp_c(sf));
    out.extend(sep_by(&[kw(Kw::Comma)], args));
    out.push(kw(Kw::Rp));
    out
}

/// `Math.unToks`: a unary function applied to the printed operand `t`.
pub fn un_toks(sf: Sf, k: Kw, t: Vec<Tok>) -> Vec<Tok> {
    match (sf, k) {
        (Sf::Latex, Kw::Sqrt) => cat(&[&[kw(Kw::Sqrt), kw(Kw::Lb)], &t, &[kw(Kw::Rb)]]),
        (Sf::Latex, Kw::Abs) => cat(&[&[kw(Kw::Labs)], &t, &[kw(Kw::Rabs)]]),
        (Sf::Latex, Kw::Floor) => cat(&[&[kw(Kw::Lfloor)], &t, &[kw(Kw::Rfloor)]]),
        (Sf::Latex, Kw::Ceil) => cat(&[&[kw(Kw::Lceil)], &t, &[kw(Kw::Rceil)]]),
        (Sf::Latex, Kw::Log) => {
            let mut out = vec![
                kw(Kw::Log),
                kw(Kw::Us),
                kw(Kw::Lb),
                Tok::Num(JNum::Int(10)),
                kw(Kw::Rb),
            ];
            out.extend(call_toks(sf, vec![], vec![t]));
            out
        }
        (Sf::Typst, Kw::Log) => {
            let mut out = vec![kw(Kw::Log), kw(Kw::Us), Tok::Num(JNum::Int(10))];
            out.extend(call_toks(sf, vec![], vec![t]));
            out
        }
        (_, k) => call_toks(sf, vec![kw(k)], vec![t]),
    }
}

/// `Math.caseRow`: one cases row, `value & \text{if } condition`, then the row
/// break.
pub fn case_row(sf: Sf, v: Vec<Tok>, cnd: Vec<Tok>) -> Vec<Tok> {
    let mut out = v;
    out.push(kw(Kw::Amp));
    out.push(Tok::Txt("if ".into()));
    out.extend(cnd);
    out.push(kw(if sf == Sf::Latex { Kw::Nl } else { Kw::Comma }));
    out
}

/// `Math.casesToks`.
pub fn cases_toks(sf: Sf, rows: &[Tok]) -> Vec<Tok> {
    match sf {
        Sf::Latex => cat(&[&[kw(Kw::Bcases)], rows, &[kw(Kw::Ecases)]]),
        Sf::Typst => cat(&[&[kw(Kw::Cases), kw(Kw::Lp)], rows, &[kw(Kw::Rp)]]),
    }
}

/// `Math.icTail`: `t_{0}` in an initial condition `N(t_{0})`.
pub fn ic_tail(sf: Sf) -> Vec<Tok> {
    match sf {
        Sf::Latex => vec![
            kw(Kw::Lp),
            Tok::Letter('t'),
            kw(Kw::Us),
            kw(Kw::Lb),
            Tok::Num(JNum::Int(0)),
            kw(Kw::Rb),
            kw(Kw::Rp),
        ],
        Sf::Typst => vec![
            kw(Kw::Lp),
            Tok::Letter('t'),
            kw(Kw::Us),
            Tok::Num(JNum::Int(0)),
            kw(Kw::Rp),
        ],
    }
}

/// `Math.subList`: a subscript list: LaTeX `_{a, b}`; Typst `_a` for one
/// simple token, else `_(a, b)`.
pub fn sub_list(sf: Sf, simp: Option<Tok>, args: Vec<Vec<Tok>>) -> Vec<Tok> {
    match sf {
        Sf::Latex => cat(&[
            &[kw(Kw::Us), kw(Kw::Lb)],
            &sep_by(&[kw(Kw::Comma)], args),
            &[kw(Kw::Rb)],
        ]),
        Sf::Typst => match simp {
            Some(t) => vec![kw(Kw::Us), t],
            None => cat(&[
                &[kw(Kw::Us), kw(Kw::Lpg)],
                &sep_by(&[kw(Kw::Comma)], args),
                &[kw(Kw::Rp)],
            ]),
        },
    }
}

/// `Math.simpleE`: the one token a Typst exponent or subscript may be written
/// as without parentheses.
pub fn simple_e(c: Ctx, j: &Json) -> Option<Tok> {
    match j {
        Json::Num(n) => {
            let t = Tok::Num(n.clone());
            if simple_tok(&t) { Some(t) } else { None }
        }
        Json::Str(s) => match name_toks(c, s).as_slice() {
            [t] if simple_tok(t) => Some(t.clone()),
            _ => None,
        },
        _ => None,
    }
}

/// `Math.simpleArg`.
pub fn simple_arg(c: Ctx, xs: &[Json]) -> Option<Tok> {
    match xs {
        [x] => simple_e(c, x),
        _ => None,
    }
}

/// `Math.subOK`: the index prints with a subscript.
pub fn sub_ok(s: &Sym, base: &Json, is: &[Json]) -> bool {
    match base {
        Json::Str(b) => {
            name_ok(b)
                && plain_last(b)
                && !explicit_name(s, b)
                && match is {
                    [Json::Str(x)] => {
                        let xc: Vec<char> = x.chars().collect();
                        !(split_dots(&xc).len() == 1 && is_formula(&xc))
                    }
                    [Json::Num(JNum::Int(n))] => {
                        let nm = format!("{b}_{n}");
                        !(0 <= *n && s.names.contains(&nm))
                    }
                    _ => true,
                }
        }
        _ => false,
    }
}

/// `Math.subPat4`: four tokens of an upright name subscript.
pub fn sub_pat4(sf: Sf, t1: &Tok, t2: &Tok, t3: &Tok, t4: &Tok) -> bool {
    match (t1, t2, t3, t4) {
        (Tok::Kw(Kw::Us), Tok::Kw(Kw::Lb), Tok::Rm(_), Tok::Kw(Kw::Rb)) => sf == Sf::Latex,
        (Tok::Kw(Kw::Us), Tok::Kw(Kw::Lpg), Tok::Ups(ps), Tok::Kw(Kw::Rp))
            if ps.len() == 1 && ps[0].1.is_empty() =>
        {
            sf == Sf::Typst
        }
        _ => false,
    }
}

/// `Math.subPat`: an upright name subscript at the front.
pub fn sub_pat(sf: Sf, ts: &[Tok]) -> bool {
    match ts {
        [t1, t2, t3, t4, ..] => sub_pat4(sf, t1, t2, t3, t4),
        _ => false,
    }
}

/// `Math.inlineD`: derivative operand printed inline.
pub fn inline_d(o: &Out) -> bool {
    9 <= o.lvl
}

/// `Math.keyToks`: a field key, upright.
pub fn key_toks(sf: Sf, k: &str) -> Vec<Tok> {
    match sf {
        Sf::Latex => {
            let cs: Vec<char> = k.chars().collect();
            vec![Tok::Rm(s_of(&esc_k(&cs)))]
        }
        Sf::Typst => vec![Tok::Ups(vec![(k.to_string(), String::new())])],
    }
}

/// `Math.jsonVal`: a field value that is not an expression, as JSON.
pub fn json_val(sf: Sf, v: &Json) -> Vec<Tok> {
    match sf {
        Sf::Latex => json_toks(v),
        Sf::Typst => vec![Tok::Code(v.clone())],
    }
}

/// `Math.openToks`: the open-operator call.
pub fn open_toks(sf: Sf, o: &str, args: Vec<Vec<Tok>>, fields: Vec<Vec<Tok>>) -> Vec<Tok> {
    let mut out = vec![Tok::Opn(o.into()), lp_c(sf)];
    out.extend(sep_by(&[kw(Kw::Comma)], args));
    if !fields.is_empty() {
        out.push(kw(Kw::Semi));
        out.extend(sep_by(&[kw(Kw::Comma)], fields));
    }
    out.push(kw(Kw::Rp));
    out
}

/// `Math.dTime`: the time derivative.
pub fn d_time(sf: Sf, a: &Out) -> Out {
    let a1 = a.at(sf, 1);
    match sf {
        Sf::Latex => {
            if inline_d(a) {
                mk_out(
                    10,
                    cat(&[
                        &[kw(Kw::Frac), kw(Kw::Lb), Tok::Rm("d".into())],
                        &a1,
                        &[
                            kw(Kw::Rb),
                            kw(Kw::Lb),
                            Tok::Rm("d".into()),
                            Tok::Letter('t'),
                            kw(Kw::Rb),
                        ],
                    ]),
                )
            } else {
                mk_out(
                    6,
                    cat(&[
                        &[
                            kw(Kw::Frac),
                            kw(Kw::Lb),
                            Tok::Rm("d".into()),
                            kw(Kw::Rb),
                            kw(Kw::Lb),
                            Tok::Rm("d".into()),
                            Tok::Letter('t'),
                            kw(Kw::Rb),
                        ],
                        &grp(sf, &a1),
                    ]),
                )
            }
        }
        Sf::Typst => {
            if inline_d(a) {
                mk_out(
                    7,
                    cat(&[
                        &[kw(Kw::Lpg), kw(Kw::Dif)],
                        &a1,
                        &[
                            kw(Kw::Rp),
                            kw(Kw::Slash),
                            kw(Kw::Lpg),
                            kw(Kw::Dif),
                            Tok::Letter('t'),
                            kw(Kw::Rp),
                        ],
                    ]),
                )
            } else {
                mk_out(
                    6,
                    cat(&[
                        &[
                            kw(Kw::Lpg),
                            kw(Kw::Dif),
                            kw(Kw::Rp),
                            kw(Kw::Slash),
                            kw(Kw::Lpg),
                            kw(Kw::Dif),
                            Tok::Letter('t'),
                            kw(Kw::Rp),
                        ],
                        &grp(sf, &a1),
                    ]),
                )
            }
        }
    }
}

/// `Math.dSpace`: the spatial derivative along the axis printed `w`.
pub fn d_space(sf: Sf, w: &[Tok], a: &Out) -> Out {
    let a1 = a.at(sf, 1);
    match sf {
        Sf::Latex => {
            if inline_d(a) {
                mk_out(
                    10,
                    cat(&[
                        &[kw(Kw::Frac), kw(Kw::Lb), kw(Kw::Pdiff)],
                        &a1,
                        &[kw(Kw::Rb), kw(Kw::Lb), kw(Kw::Pdiff)],
                        w,
                        &[kw(Kw::Rb)],
                    ]),
                )
            } else {
                mk_out(
                    6,
                    cat(&[
                        &[
                            kw(Kw::Frac),
                            kw(Kw::Lb),
                            kw(Kw::Pdiff),
                            kw(Kw::Rb),
                            kw(Kw::Lb),
                            kw(Kw::Pdiff),
                        ],
                        w,
                        &[kw(Kw::Rb)],
                        &grp(sf, &a1),
                    ]),
                )
            }
        }
        Sf::Typst => {
            if inline_d(a) {
                mk_out(
                    7,
                    cat(&[
                        &[kw(Kw::Lpg), kw(Kw::Pdiff)],
                        &a1,
                        &[kw(Kw::Rp), kw(Kw::Slash), kw(Kw::Lpg), kw(Kw::Pdiff)],
                        w,
                        &[kw(Kw::Rp)],
                    ]),
                )
            } else {
                mk_out(
                    6,
                    cat(&[
                        &[
                            kw(Kw::Lpg),
                            kw(Kw::Pdiff),
                            kw(Kw::Rp),
                            kw(Kw::Slash),
                            kw(Kw::Lpg),
                            kw(Kw::Pdiff),
                        ],
                        w,
                        &[kw(Kw::Rp)],
                        &grp(sf, &a1),
                    ]),
                )
            }
        }
    }
}

/// `Math.dCall`: `partial` with trailing operands: `\partial_{x}(u, a, b)` /
/// `partial_(x)(u, a, b)`.
pub fn d_call(sf: Sf, w: &[Tok], args: Vec<Vec<Tok>>) -> Vec<Tok> {
    let open = if sf == Sf::Latex { Kw::Lb } else { Kw::Lpg };
    let close = if sf == Sf::Latex { Kw::Rb } else { Kw::Rp };
    let mut out = vec![kw(Kw::Pdiff), kw(Kw::Us), kw(open)];
    out.extend_from_slice(w);
    out.push(kw(close));
    out.extend(call_toks(sf, vec![], args));
    out
}

/// `Math.nabHead`: what a `\nabla` form writes before its operand: `\nabla`,
/// `\nabla \cdot`, `\nabla^{2}`, `\nabla \times` (Typst `nabla`, `nabla dot`,
/// `nabla^2`, `nabla times`).
pub fn nab_head(sf: Sf, n: NabK) -> Vec<Tok> {
    match n {
        NabK::Grad => vec![kw(Kw::Nabla)],
        NabK::Div => vec![kw(Kw::Nabla), kw(Kw::Cdot)],
        NabK::Lap => match sf {
            Sf::Latex => vec![
                kw(Kw::Nabla),
                kw(Kw::Caret),
                kw(Kw::Lb),
                Tok::Num(JNum::Int(2)),
                kw(Kw::Rb),
            ],
            Sf::Typst => vec![kw(Kw::Nabla), kw(Kw::Caret), Tok::Num(JNum::Int(2))],
        },
        NabK::Curl => vec![kw(Kw::Nabla), kw(Kw::Times)],
    }
}

/// `Math.nabArg`: the operand of a `\nabla` form — another `\nabla` form as it
/// is (`\nabla \cdot \nabla u` is `div(grad(u))`), anything else at the level of
/// a power base; after the `\times` of a curl, an operand that starts with a
/// number in parentheses (`Math.nabArg9`), so that no `\times 10^{…}` follows.
pub fn nab_arg(sf: Sf, n: NabK, o: &Out) -> Vec<Tok> {
    if matches!(o.toks.first(), Some(Tok::Kw(Kw::Nabla))) && 6 <= o.lvl {
        return o.toks.clone();
    }
    let t = o.at(sf, 9);
    if n == NabK::Curl && starts_num(&t) {
        grp(sf, &t)
    } else {
        t
    }
}

/// `Math.qtyToks`: the quantity: the number, then the unit as one token.
pub fn qty_toks(n: &JNum, l: Vec<Factor>) -> Vec<Tok> {
    vec![Tok::Num(n.clone()), Tok::Units(l)]
}

// ## Constant arrays

/// `Math.numsOf`: the entries of a list that are all well-formed numbers.
pub fn nums_of(xs: &[Json]) -> Option<Vec<JNum>> {
    xs.iter()
        .map(|x| match x {
            Json::Num(n) if super::expr::num_ok(n) => Some(n.clone()),
            _ => None,
        })
        .collect()
}

/// `Math.rowsOf`: the rows of a list of number lists.
pub fn rows_of(xs: &[Json]) -> Option<Vec<Vec<JNum>>> {
    xs.iter()
        .map(|x| match x {
            Json::Arr(ys) => nums_of(ys),
            _ => None,
        })
        .collect()
}

/// `Math.AForm`: the two array shapes with a native spelling.
#[derive(Clone, Debug, PartialEq)]
pub enum AForm {
    Col(Vec<JNum>),
    Mat(Vec<Vec<JNum>>),
}

/// `Math.arrForm`: a constant array printed natively: a column for rank 1, or
/// a matrix of at least two columns, of any size, every entry a well-formed
/// number.
pub fn arr_form(j: &Json) -> Option<AForm> {
    let Json::Arr(xs) = j else { return None };
    match nums_of(xs) {
        Some(ns) => {
            if !ns.is_empty() {
                Some(AForm::Col(ns))
            } else {
                None
            }
        }
        None => match rows_of(xs) {
            Some(rs) if !rs.is_empty() => {
                let r = &rs[0];
                if 2 <= r.len() && rs[1..].iter().all(|q| q.len() == r.len()) {
                    Some(AForm::Mat(rs))
                } else {
                    None
                }
            }
            _ => None,
        },
    }
}

/// The most columns a LaTeX `bmatrix` takes (amsmath `MaxMatrixCols`); a wider
/// matrix is written as a bracketed `array`.
pub const BMAT_MAX_COLS: usize = 10;

/// `Math.numToks`.
pub fn num_toks(ns: &[JNum]) -> Vec<Vec<Tok>> {
    ns.iter().map(|n| vec![Tok::Num(n.clone())]).collect()
}

/// `Math.arrToks`: LaTeX `bmatrix`, Typst `vec(…)` / `mat(…)`.
pub fn arr_toks(sf: Sf, a: &AForm) -> Vec<Tok> {
    match (a, sf) {
        (AForm::Col(ns), Sf::Latex) => cat(&[
            &[kw(Kw::Bmat)],
            &sep_by(&[kw(Kw::Nl)], num_toks(ns)),
            &[kw(Kw::Emat)],
        ]),
        (AForm::Col(ns), Sf::Typst) => cat(&[
            &[kw(Kw::Vec), kw(Kw::Lp)],
            &sep_by(&[kw(Kw::Comma)], num_toks(ns)),
            &[kw(Kw::Rp)],
        ]),
        (AForm::Mat(rs), Sf::Latex) => {
            let body = sep_by(
                &[kw(Kw::Nl)],
                rs.iter()
                    .map(|r| sep_by(&[kw(Kw::Amp)], num_toks(r)))
                    .collect(),
            );
            let n = rs[0].len();
            if n > BMAT_MAX_COLS {
                cat(&[
                    &[kw(Kw::Lbkg), Tok::Carr(n)],
                    &body,
                    &[kw(Kw::Earr), kw(Kw::Rbkg)],
                ])
            } else {
                cat(&[&[kw(Kw::Bmat)], &body, &[kw(Kw::Emat)]])
            }
        }
        (AForm::Mat(rs), Sf::Typst) => cat(&[
            &[kw(Kw::Mat), kw(Kw::Lp)],
            &sep_by(
                &[kw(Kw::Semi)],
                rs.iter()
                    .map(|r| sep_by(&[kw(Kw::Comma)], num_toks(r)))
                    .collect(),
            ),
            &[kw(Kw::Rp)],
        ]),
    }
}

/// `Math.unitToks`: the unit after a number or an array.
pub fn unit_toks(l: Vec<Factor>) -> Vec<Tok> {
    vec![Tok::Units(l)]
}

// ## Reductions (`faq`)

/// `Math.jbeq`: structural equality of JSON values.
pub fn jbeq(a: &Json, b: &Json) -> bool {
    a == b
}

/// `Math.idxBase`: the array an `index` node reads, when it names one.
pub fn idx_base(kvs: &[(String, Json)]) -> Option<&str> {
    match (look("op", kvs), look("args", kvs)) {
        (Some(Json::Str(o)), Some(Json::Arr(xs))) if o == "index" => match xs.first() {
            Some(Json::Str(s)) => Some(s),
            _ => None,
        },
        _ => None,
    }
}

/// `Math.basesJ`: the arrays an expression indexes, in first-use order
/// (appended to `acc`).
pub fn bases_j(j: &Json, acc: &mut Vec<String>) {
    match j {
        Json::Obj(kvs) => {
            if let Some(s) = idx_base(kvs)
                && !acc.iter().any(|a| a == s)
            {
                acc.push(s.to_string());
            }
            for (_, v) in kvs {
                bases_j(v, acc);
            }
        }
        Json::Arr(xs) => {
            for x in xs {
                bases_j(x, acc);
            }
        }
        _ => {}
    }
}

/// `Math.bases`.
pub fn bases(e: &Json) -> Vec<String> {
    let mut acc = Vec::new();
    bases_j(e, &mut acc);
    acc
}

/// `Math.RedK`: the reductions with a native spelling.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RedK {
    Sum,
    Prod,
    Max,
    Min,
}

impl RedK {
    /// `Math.RedK.kw`.
    pub fn kw(self) -> Kw {
        match self {
            RedK::Sum => Kw::Sum,
            RedK::Prod => Kw::Prod,
            RedK::Max => Kw::Max,
            RedK::Min => Kw::Min,
        }
    }

    /// `Math.RedK.field`.
    pub fn field(self) -> Vec<(String, Json)> {
        match self {
            RedK::Sum => vec![],
            RedK::Prod => vec![("reduce".into(), Json::str("*"))],
            RedK::Max => vec![("reduce".into(), Json::str("max"))],
            RedK::Min => vec![("reduce".into(), Json::str("min"))],
        }
    }
}

/// `Math.FaqForm`: a `faq` node with a native spelling, by its parts.
/// `marked`: `args` lists the arrays the body indexes; otherwise `args` is
/// `set` (empty, or names printed as a superscript set).
#[derive(Clone, Debug, PartialEq)]
pub struct FaqForm {
    pub red: RedK,
    pub marked: bool,
    pub out: Vec<Json>,
    pub ranges: Vec<(String, Json)>,
    pub expr: Json,
    pub filter: Option<Json>,
    pub set: Vec<String>,
}

impl FaqForm {
    /// `Math.FaqForm.args`: the `args` of a native `faq`.
    pub fn args(&self) -> Vec<Json> {
        if self.marked {
            bases(&self.expr).into_iter().map(Json::Str).collect()
        } else {
            self.set.iter().cloned().map(Json::Str).collect()
        }
    }

    /// `Math.FaqForm.sup`: the names a superscript set shows: `set` when
    /// `args` is not the body's arrays.
    pub fn sup(&self) -> &[String] {
        if self.marked { &[] } else { &self.set }
    }
}

/// `Math.faqJson`.
pub fn faq_json(f: &FaqForm) -> Json {
    let mut kvs = vec![
        ("args".to_string(), Json::Arr(f.args())),
        ("expr".to_string(), f.expr.clone()),
    ];
    if let Some(x) = &f.filter {
        kvs.push(("filter".into(), x.clone()));
    }
    kvs.push(("op".into(), Json::str("faq")));
    kvs.push(("output_idx".into(), Json::Arr(f.out.clone())));
    if !f.ranges.is_empty() {
        kvs.push(("ranges".into(), Json::Obj(f.ranges.clone())));
    }
    kvs.extend(f.red.field());
    Json::Obj(kvs)
}

/// `Math.strsOf`: the strings of a list of JSON values, when they are all
/// strings.
pub fn strs_of(xs: &[Json]) -> Option<Vec<String>> {
    xs.iter()
        .map(|x| match x {
            Json::Str(s) => Some(s.clone()),
            _ => None,
        })
        .collect()
}

/// `Math.faqCand`: the parts a `faq` node would have.
pub fn faq_cand(kvs: &[(String, Json)]) -> Option<FaqForm> {
    match (
        look("expr", kvs),
        look("output_idx", kvs),
        look("args", kvs),
    ) {
        (Some(e), Some(Json::Arr(out)), Some(Json::Arr(args))) => {
            let red = match look("reduce", kvs) {
                None => Some(RedK::Sum),
                Some(Json::Str(s)) if s == "*" => Some(RedK::Prod),
                Some(Json::Str(s)) if s == "max" => Some(RedK::Max),
                Some(Json::Str(s)) if s == "min" => Some(RedK::Min),
                _ => None,
            }?;
            let rs = match look("ranges", kvs) {
                Some(Json::Obj(rs)) => Some(rs.clone()),
                None => Some(vec![]),
                _ => None,
            }?;
            let (marked, set) = if args.is_empty() {
                (false, vec![])
            } else if jbeq(
                &Json::Arr(args.clone()),
                &Json::Arr(bases(e).into_iter().map(Json::Str).collect()),
            ) {
                (true, vec![])
            } else {
                (false, strs_of(args)?)
            };
            Some(FaqForm {
                red,
                marked,
                out: out.clone(),
                ranges: rs,
                expr: e.clone(),
                filter: look("filter", kvs).cloned(),
                set,
            })
        }
        _ => None,
    }
}

/// `Math.faqForm`: the parts of a `faq` node, when it is exactly the node they
/// rebuild.
pub fn faq_form(kvs: &[(String, Json)]) -> Option<FaqForm> {
    let f = faq_cand(kvs)?;
    if jbeq(&faq_json(&f), &Json::Obj(kvs.to_vec())) {
        Some(f)
    } else {
        None
    }
}

/// `Math.rangeOK`: a range a row can spell.
pub fn range_ok(j: &Json) -> bool {
    match j {
        Json::Arr(xs) => matches!(xs.as_slice(), [a, b] if is_e(a) && is_e(b)),
        Json::Obj(kvs) => match kvs.as_slice() {
            [(k, Json::Str(s))] if k == "from" => name_ok(s),
            [(k, Json::Str(s)), (k2, Json::Arr(ps))] if k == "from" && k2 == "of" => {
                name_ok(s)
                    && !ps.is_empty()
                    && ps.iter().all(|p| matches!(p, Json::Str(q) if name_ok(q)))
            }
            _ => false,
        },
        _ => false,
    }
}

/// `Math.outNames`.
pub fn out_names(out: &[Json]) -> Vec<String> {
    out.iter()
        .filter_map(|j| match j {
            Json::Str(k) => Some(k.clone()),
            _ => None,
        })
        .collect()
}

/// `Math.outOK`: an output entry: a name, or the singleton dimension `1`.
pub fn out_ok(j: &Json) -> bool {
    match j {
        Json::Str(k) => name_ok(k),
        Json::Num(JNum::Int(1)) => true,
        _ => false,
    }
}

/// `Math.occursJ`: a bare name occurs in an expression.
pub fn occurs_j(k: &str, j: &Json) -> bool {
    match j {
        Json::Str(s) => s == k,
        Json::Arr(xs) => xs.iter().any(|x| occurs_j(k, x)),
        Json::Obj(kvs) => kvs.iter().any(|(_, v)| occurs_j(k, v)),
        _ => false,
    }
}

/// `Math.faqOK`: the conditions under which the native spelling reads back.
pub fn faq_ok(f: &FaqForm) -> bool {
    let names = out_names(&f.out);
    is_e(&f.expr)
        && f.filter.as_ref().is_none_or(is_e)
        && f.out.iter().all(out_ok)
        && nodup(&names)
        && f.set.iter().all(|n| name_ok(n))
        && keys_sorted(&f.ranges)
        && f.ranges.iter().all(|(k, v)| {
            name_ok(k)
                && range_ok(v)
                && (names.contains(k)
                    || occurs_j(k, &f.expr)
                    || f.filter.as_ref().is_some_and(|x| occurs_j(k, x)))
        })
}

/// `Math.upSet`: a segment of an index set's name prints upright in a Typst range row
/// when it would otherwise print `italic("…")`.
pub fn up_set(sf: Sf, g: &[char]) -> bool {
    sf == Sf::Typst && seg_ok(g) && !is_single(g) && sub_parts(g).is_none() && !is_formula(g)
}

/// `Math.setSegToks`: one segment of an index set's name.
pub fn set_seg_toks(sf: Sf, g: &[char]) -> Vec<Tok> {
    if up_set(sf, g) {
        vec![Tok::Ups(vec![(g.iter().collect(), String::new())])]
    } else {
        seg_toks(sf, g)
    }
}

/// `Math.setToks`: the tokens of an index set's name in a range row.
pub fn set_toks(c: Ctx, s: &str) -> Vec<Tok> {
    if explicit_name(c.s, s) {
        vec![Tok::It(s.to_string())]
    } else {
        let cs: Vec<char> = s.chars().collect();
        sep_by(
            &[kw(Kw::Sdot)],
            split_dots(&cs)
                .iter()
                .map(|g| set_seg_toks(c.sf, g))
                .collect(),
        )
    }
}

/// `Math.rowToks`: a range row: `a \le k \le b`, `k \in S`, `k \in S(i, j)`.
pub fn row_toks(c: Ctx, kv: (&str, &Json)) -> Vec<Tok> {
    let (k, v) = kv;
    match v {
        Json::Arr(xs) if xs.len() == 2 => cat(&[
            &pa(c, 4, &xs[0]),
            &[kw(Kw::Le)],
            &name_toks(c, k),
            &[kw(Kw::Le)],
            &pa(c, 4, &xs[1]),
        ]),
        Json::Obj(kvs) => match kvs.as_slice() {
            [(f, Json::Str(s))] if f == "from" => {
                cat(&[&name_toks(c, k), &[kw(Kw::Inn)], &set_toks(c, s)])
            }
            [(f, Json::Str(s)), (o, Json::Arr(ps))] if f == "from" && o == "of" => cat(&[
                &name_toks(c, k),
                &[kw(Kw::Inn)],
                &set_toks(c, s),
                &[kw(Kw::Lp)],
                &sep_by(
                    &[kw(Kw::Comma)],
                    ps.iter()
                        .map(|p| match p {
                            Json::Str(q) => name_toks(c, q),
                            _ => vec![],
                        })
                        .collect(),
                ),
                &[kw(Kw::Rp)],
            ]),
            _ => vec![],
        },
        _ => vec![],
    }
}

/// `Math.redRanges`: the ranges of indices that are not output indices.
pub fn red_ranges(f: &FaqForm) -> Vec<(String, Json)> {
    let names = out_names(&f.out);
    f.ranges
        .iter()
        .filter(|kv| !names.contains(&kv.0))
        .cloned()
        .collect()
}

/// `Math.subRows`: the rows of the subscript: the reduced ranges, then the
/// filter.
pub fn sub_rows(c: Ctx, f: &FaqForm) -> Vec<Vec<Tok>> {
    let mut rows: Vec<Vec<Tok>> = red_ranges(f)
        .iter()
        .map(|(k, v)| row_toks(c, (k, v)))
        .collect();
    if let Some(x) = &f.filter {
        rows.push(pa(c, 1, x));
    }
    rows
}

/// `Math.headToks`: the operator, marked when `args` is listed.
pub fn head_toks(sf: Sf, f: &FaqForm) -> Vec<Tok> {
    match sf {
        Sf::Latex => {
            let mut out = vec![kw(f.red.kw())];
            if f.marked {
                out.push(kw(Kw::LimitsL));
            }
            out
        }
        Sf::Typst => {
            if f.marked {
                vec![kw(Kw::Limits), kw(Kw::Lp), kw(f.red.kw()), kw(Kw::Rp)]
            } else {
                vec![kw(f.red.kw())]
            }
        }
    }
}

/// `Math.subToksL`: the LaTeX subscript: none, one row, a lone dense range
/// `_{k=a}^{b}` (not when `args` is a superscript set), or `\substack`.
pub fn sub_toks_l(c: Ctx, f: &FaqForm) -> Vec<Tok> {
    let rr = red_ranges(f);
    if let ([(k, Json::Arr(ab))], None, []) = (rr.as_slice(), &f.filter, f.sup())
        && ab.len() == 2
    {
        return cat(&[
            &[kw(Kw::Us), kw(Kw::Lb)],
            &name_toks(c, k),
            &[kw(Kw::Eq)],
            &pa(c, 4, &ab[0]),
            &[kw(Kw::Rb), kw(Kw::Caret), kw(Kw::Lb)],
            &pa(c, 1, &ab[1]),
            &[kw(Kw::Rb)],
        ]);
    }
    let rows = sub_rows(c, f);
    match rows.len() {
        0 => vec![],
        1 => cat(&[&[kw(Kw::Us), kw(Kw::Lb)], &rows[0], &[kw(Kw::Rb)]]),
        _ => cat(&[
            &[kw(Kw::Us), kw(Kw::Lb), kw(Kw::Substack), kw(Kw::Lb)],
            &sep_by(&[kw(Kw::Nl)], rows),
            &[kw(Kw::Rb), kw(Kw::Rb)],
        ]),
    }
}

/// `Math.subToksT`: the Typst subscript: rows in `_( … )`, stacked with `\`.
pub fn sub_toks_t(c: Ctx, f: &FaqForm) -> Vec<Tok> {
    let rows = sub_rows(c, f);
    if rows.is_empty() {
        vec![]
    } else {
        cat(&[
            &[kw(Kw::Us), kw(Kw::Lpg)],
            &sep_by(&[kw(Kw::Nl)], rows),
            &[kw(Kw::Rp)],
        ])
    }
}

/// `Math.subToks`.
pub fn sub_toks(c: Ctx, f: &FaqForm) -> Vec<Tok> {
    match c.sf {
        Sf::Latex => sub_toks_l(c, f),
        Sf::Typst => sub_toks_t(c, f),
    }
}

/// `Math.supToks`: the superscript set of names: LaTeX `^{\{f, g\}}`, Typst
/// `^({f, g})`.
pub fn sup_toks(c: Ctx, ns: &[String]) -> Vec<Tok> {
    let names = sep_by(
        &[kw(Kw::Comma)],
        ns.iter().map(|n| name_toks(c, n)).collect(),
    );
    match c.sf {
        Sf::Latex => cat(&[
            &[kw(Kw::Caret), kw(Kw::Lb), kw(Kw::Lset)],
            &names,
            &[kw(Kw::Rset), kw(Kw::Rb)],
        ]),
        Sf::Typst => cat(&[
            &[kw(Kw::Caret), kw(Kw::Lpg), kw(Kw::Lset)],
            &names,
            &[kw(Kw::Rset), kw(Kw::Rp)],
        ]),
    }
}

/// `Math.supT`: the `args` set of a `faq`, as a superscript, when it is one.
pub fn sup_t(c: Ctx, f: &FaqForm) -> Vec<Tok> {
    if f.sup().is_empty() {
        vec![]
    } else {
        sup_toks(c, f.sup())
    }
}

/// `Math.redToks`: operator, subscript, the superscript set (on the operator
/// only when there are no output indices), body at level 5.
pub fn red_toks(c: Ctx, f: &FaqForm) -> Vec<Tok> {
    let sup = if f.out.is_empty() {
        sup_t(c, f)
    } else {
        vec![]
    };
    cat(&[
        &head_toks(c.sf, f),
        &sub_toks(c, f),
        &sup,
        &pa(c, 5, &f.expr),
    ])
}

/// `Math.entryToks`: an output entry: its range row when it has one.
pub fn entry_toks(c: Ctx, f: &FaqForm, j: &Json) -> Vec<Tok> {
    match j {
        Json::Str(k) => match look(k, &f.ranges) {
            Some(v) => row_toks(c, (k, v)),
            None => name_toks(c, k),
        },
        _ => vec![Tok::Num(JNum::Int(1))],
    }
}

/// `Math.faqOut`: the native `faq`, wrapped with its output indices when it has
/// some. A superscript set goes on the bracket, before its subscript; the form
/// is then a power's level (a power of it, or an index into it, is
/// parenthesized: no double superscript).
///
/// Lean passes the printer of the sub-expressions as a table (`tableP` over
/// `faqSubs`); every lookup is of a member of `faqSubs`, so the port calls
/// [`pr`] directly.
pub fn faq_out(c: Ctx, f: &FaqForm) -> Out {
    if f.out.is_empty() {
        return mk_out(5, red_toks(c, f));
    }
    let es = sep_by(
        &[kw(Kw::Comma)],
        f.out.iter().map(|j| entry_toks(c, f, j)).collect(),
    );
    let sup = sup_t(c, f);
    let l = if sup.is_empty() { 10 } else { 8 };
    match c.sf {
        Sf::Latex => mk_out(
            l,
            cat(&[
                &[kw(Kw::Lbkg)],
                &red_toks(c, f),
                &[kw(Kw::Rbkg)],
                &sup,
                &[kw(Kw::Us), kw(Kw::Lb)],
                &es,
                &[kw(Kw::Rb)],
            ]),
        ),
        Sf::Typst => mk_out(
            l,
            cat(&[
                &[kw(Kw::Lr), kw(Kw::Lp), kw(Kw::Lbk)],
                &red_toks(c, f),
                &[kw(Kw::Rbk), kw(Kw::Rp)],
                &sup,
                &[kw(Kw::Us), kw(Kw::Lpg)],
                &es,
                &[kw(Kw::Rp)],
            ]),
        ),
    }
}

// ## Block assembly (`makearray`)

/// `Math.MkForm`: a `makearray` node with a native spelling, by its parts: the
/// output indices (empty when the node has no `output_idx`), and the regions
/// with their values.
#[derive(Clone, Debug, PartialEq)]
pub struct MkForm {
    pub out: Vec<String>,
    pub regions: Vec<Vec<(Json, Json)>>,
    pub values: Vec<Json>,
}

/// `Math.mkJson` (with `pairJson`, `regionJson`).
pub fn mk_json(m: &MkForm) -> Json {
    let mut kvs = vec![
        ("args".to_string(), Json::Arr(vec![])),
        ("op".to_string(), Json::str("makearray")),
    ];
    if !m.out.is_empty() {
        kvs.push((
            "output_idx".into(),
            Json::Arr(m.out.iter().cloned().map(Json::Str).collect()),
        ));
    }
    let regions = m
        .regions
        .iter()
        .map(|r| {
            Json::Arr(
                r.iter()
                    .map(|(a, b)| Json::Arr(vec![a.clone(), b.clone()]))
                    .collect(),
            )
        })
        .collect();
    kvs.push(("regions".into(), Json::Arr(regions)));
    kvs.push(("values".into(), Json::Arr(m.values.clone())));
    Json::Obj(kvs)
}

/// `Math.pairsOf`: the bound pairs of a region.
pub fn pairs_of(xs: &[Json]) -> Option<Vec<(Json, Json)>> {
    xs.iter()
        .map(|x| match x {
            Json::Arr(ab) => match ab.as_slice() {
                [a, b] => Some((a.clone(), b.clone())),
                _ => None,
            },
            _ => None,
        })
        .collect()
}

/// `Math.regionsOf`: the regions of a `regions` list.
pub fn regions_of(xs: &[Json]) -> Option<Vec<Vec<(Json, Json)>>> {
    xs.iter()
        .map(|x| match x {
            Json::Arr(ps) => pairs_of(ps),
            _ => None,
        })
        .collect()
}

/// `Math.mkCand`: the parts a `makearray` node would have.
pub fn mk_cand(kvs: &[(String, Json)]) -> Option<MkForm> {
    match (look("regions", kvs), look("values", kvs)) {
        (Some(Json::Arr(rs)), Some(Json::Arr(vs))) => {
            let out = match look("output_idx", kvs) {
                None => vec![],
                Some(Json::Arr(os)) => strs_of(os)?,
                Some(_) => return None,
            };
            Some(MkForm {
                out,
                regions: regions_of(rs)?,
                values: vs.clone(),
            })
        }
        _ => None,
    }
}

/// `Math.mkForm`: the parts of a `makearray` node, when it is exactly the node
/// they rebuild: `args` empty, `regions` and `values`, and an `output_idx` of
/// names or none.
pub fn mk_form(kvs: &[(String, Json)]) -> Option<MkForm> {
    let m = mk_cand(kvs)?;
    if jbeq(&mk_json(&m), &Json::Obj(kvs.to_vec())) {
        Some(m)
    } else {
        None
    }
}

/// `Math.mkOK`: the conditions under which the native spelling reads back: one
/// value per region, at least one region, each region a nonempty list of
/// bound pairs, values and bounds expressions, output indices names.
pub fn mk_ok(m: &MkForm) -> bool {
    !m.values.is_empty()
        && m.regions.len() == m.values.len()
        && m.values.iter().all(is_e)
        && m.regions
            .iter()
            .all(|r| !r.is_empty() && r.iter().all(|(a, b)| is_e(a) && is_e(b)))
        && m.out.iter().all(|n| name_ok(n))
}

/// `Math.cellSep`: the cell separator of the table.
pub fn cell_sep(sf: Sf) -> Kw {
    match sf {
        Sf::Latex => Kw::Amp,
        Sf::Typst => Kw::Comma,
    }
}

/// `Math.rowSep`: the row separator of the table.
pub fn row_sep(sf: Sf) -> Kw {
    match sf {
        Sf::Latex => Kw::Nl,
        Sf::Typst => Kw::Semi,
    }
}

/// `Math.pairToks`: a bound pair: `a, b` (its brackets are written around it).
pub fn pair_toks(c: Ctx, p: &(Json, Json)) -> Vec<Tok> {
    cat(&[&pa(c, 1, &p.0), &[kw(Kw::Comma)], &pa(c, 1, &p.1)])
}

/// `Math.regToks`: a region: `[a, b] \times [c, d]`, one bound pair per
/// dimension.
pub fn reg_toks(c: Ctx, r: &[(Json, Json)]) -> Vec<Tok> {
    let mut out = Vec::new();
    for (i, p) in r.iter().enumerate() {
        if i > 0 {
            out.push(kw(Kw::Times));
        }
        out.push(kw(Kw::Lbk));
        out.extend(pair_toks(c, p));
        out.push(kw(Kw::Rbk));
    }
    out
}

/// `Math.mkRow`: a row of the table: the value, then the region it fills.
pub fn mk_row(c: Ctx, v: &Json, r: &[(Json, Json)]) -> Vec<Tok> {
    cat(&[&pa(c, 1, v), &[kw(cell_sep(c.sf))], &reg_toks(c, r)])
}

/// `Math.matHead`: the Typst table head: `mat(delim: "[", augment: #1,`.
pub fn mat_head() -> Vec<Tok> {
    vec![
        kw(Kw::Mat),
        kw(Kw::Lp),
        Tok::Word("delim".into()),
        kw(Kw::Colon),
        Tok::Txt("[".into()),
        kw(Kw::Comma),
        Tok::Word("augment".into()),
        kw(Kw::Colon),
        Tok::Code(Json::Num(JNum::Int(1))),
        kw(Kw::Comma),
    ]
}

/// `Math.mkSub`: the output indices as the bracket's subscript.
pub fn mk_sub(c: Ctx, out: &[String]) -> Vec<Tok> {
    if out.is_empty() {
        return vec![];
    }
    let names = sep_by(
        &[kw(Kw::Comma)],
        out.iter().map(|n| name_toks(c, n)).collect(),
    );
    match c.sf {
        Sf::Latex => cat(&[&[kw(Kw::Us), kw(Kw::Lb)], &names, &[kw(Kw::Rb)]]),
        Sf::Typst => cat(&[&[kw(Kw::Us), kw(Kw::Lpg)], &names, &[kw(Kw::Rp)]]),
    }
}

/// `Math.mkOutT`: the native `makearray`: a bracketed two-column table, value
/// then region, one row per region in order; LaTeX
/// `\left[\begin{array}{l|l} v & [a, b] \\ … \end{array}\right]`, Typst
/// `mat(delim: "[", augment: #1, v, [a, b]; …)`; the output indices as its
/// subscript. As for [`faq_out`], the port calls [`pr`] directly where Lean
/// looks the sub-expressions up in a table.
pub fn mk_out_t(c: Ctx, m: &MkForm) -> Out {
    let rows = sep_by(
        &[kw(row_sep(c.sf))],
        m.values
            .iter()
            .zip(&m.regions)
            .map(|(v, r)| mk_row(c, v, r))
            .collect(),
    );
    match c.sf {
        Sf::Latex => mk_out(
            10,
            cat(&[
                &[kw(Kw::Lbkg), kw(Kw::Barr)],
                &rows,
                &[kw(Kw::Earr), kw(Kw::Rbkg)],
                &mk_sub(c, &m.out),
            ]),
        ),
        Sf::Typst => mk_out(
            10,
            cat(&[&mat_head(), &rows, &[kw(Kw::Rp)], &mk_sub(c, &m.out)]),
        ),
    }
}

/// `Math.tnameOK`.
pub fn tname_ok(n: &str) -> bool {
    opn_ok(n) && !reserved_opn(n)
}

/// `Math.pr`: the printer.
pub fn pr(c: Ctx, e: &Json) -> Out {
    let sf = c.sf;
    let kvs = match e {
        Json::Num(n) => {
            return mk_out(
                if is_neg_num(e) { 7 } else { 10 },
                vec![Tok::Num(n.clone())],
            );
        }
        Json::Str(s) => return mk_out(10, name_toks(c, s)),
        Json::Obj(kvs) => kvs,
        _ => return mk_out(10, vec![]),
    };
    let esc = || match (look("op", kvs), look("args", kvs)) {
        (Some(Json::Str(o)), Some(Json::Arr(args))) => mk_out(
            10,
            esc_toks(
                sf,
                o,
                fields_of(kvs),
                args.iter().map(|a| pa(c, 1, a)).collect(),
            ),
        ),
        _ => mk_out(10, vec![]),
    };
    let fq = || -> Option<Out> {
        let f = faq_form(kvs)?;
        if faq_ok(&f) {
            Some(faq_out(c, &f))
        } else {
            None
        }
    };
    let mk = || -> Option<Out> {
        let m = mk_form(kvs)?;
        if mk_ok(&m) {
            Some(mk_out_t(c, &m))
        } else {
            None
        }
    };
    let opn = || match (look("op", kvs), look("args", kvs)) {
        (Some(Json::Str(o)), Some(Json::Arr(args))) => {
            let fs = fields_of(kvs);
            if call_form_ok(o, &fs)
                && opn_ok(o)
                && tparams(c.s, o).is_none()
                && fs.iter().all(|kv| key_ok(&kv.0))
            {
                mk_out(
                    10,
                    open_toks(
                        sf,
                        o,
                        args.iter().map(|a| pa(c, 4, a)).collect(),
                        fs.iter()
                            .map(|kv| {
                                let (k, v) = kv;
                                cat(&[
                                    &key_toks(sf, k),
                                    &[kw(Kw::Eq)],
                                    &if math_field(o, kv) {
                                        pa(c, 4, v)
                                    } else {
                                        json_val(sf, v)
                                    },
                                ])
                            })
                            .collect(),
                    ),
                )
            } else {
                esc()
            }
        }
        _ => esc(),
    };
    let field = |i: usize, k: &str| kvs.get(i).filter(|kv| kv.0 == k).map(|kv| &kv.1);
    let str_at = |i: usize, k: &str, v: &str| matches!(field(i, k), Some(Json::Str(s)) if s == v);
    let empty_args = || matches!(field(0, "args"), Some(Json::Arr(a)) if a.is_empty());
    match kvs.len() {
        2 => {
            if let (Some(Json::Arr(args)), Some(Json::Str(o))) = (field(0, "args"), field(1, "op"))
            {
                return pr_plain(c, o, args, &opn, &esc);
            }
        }
        3 => {
            // `D` is the time derivative only; a `D` along any other axis
            // prints in the escape form (esm-spec §1.2).
            if let (Some(Json::Arr(args)), true, Some(Json::Str(w))) =
                (field(0, "args"), str_at(1, "op", "D"), field(2, "wrt"))
            {
                return match args.as_slice() {
                    [a] if w == "t" => d_time(sf, &pr(c, a)),
                    _ => esc(),
                };
            }
            if let (Some(Json::Arr(args)), true, Some(Json::Str(w))) = (
                field(0, "args"),
                str_at(1, "op", "partial"),
                field(2, "wrt"),
            ) {
                return match args.as_slice() {
                    [a] => {
                        if w != "t" && name_ok(w) {
                            d_space(sf, &name_toks(c, w), &pr(c, a))
                        } else {
                            opn()
                        }
                    }
                    [_, _, ..] => {
                        if w != "t" && name_ok(w) {
                            mk_out(
                                10,
                                d_call(
                                    sf,
                                    &name_toks(c, w),
                                    args.iter().map(|x| pa(c, 4, x)).collect(),
                                ),
                            )
                        } else {
                            opn()
                        }
                    }
                    [] => opn(),
                };
            }
            if empty_args()
                && str_at(1, "op", "const")
                && let Some(Json::Arr(xs)) = field(2, "value")
            {
                return match arr_form(&Json::Arr(xs.clone())) {
                    Some(af) => mk_out(10, arr_toks(sf, &af)),
                    None => opn(),
                };
            }
        }
        4 => {
            if empty_args()
                && str_at(1, "op", "const")
                && let Some(Json::Str(u)) = field(2, "units")
            {
                match field(3, "value") {
                    Some(Json::Num(n)) => {
                        return if units_ok(sf, u) {
                            mk_out(7, qty_toks(n, factors_of(u)))
                        } else {
                            opn()
                        };
                    }
                    Some(Json::Arr(xs)) => {
                        return match arr_form(&Json::Arr(xs.clone())) {
                            Some(af) => {
                                if units_ok(sf, u) {
                                    mk_out(7, cat(&[&arr_toks(sf, &af), &unit_toks(factors_of(u))]))
                                } else {
                                    opn()
                                }
                            }
                            None => opn(),
                        };
                    }
                    _ => {}
                }
            }
            if empty_args()
                && let (Some(Json::Obj(bs)), Some(Json::Str(n)), true) = (
                    field(1, "bindings"),
                    field(2, "name"),
                    str_at(3, "op", "apply_operator"),
                )
            {
                return pr_template(c, n, bs, &esc);
            }
        }
        _ => {}
    }
    match fq() {
        Some(o) => o,
        None => match mk() {
            Some(o) => o,
            None => opn(),
        },
    }
}

/// The `[("args", .arr as), ("op", .str o)]` case of `Math.pr`.
fn pr_plain(c: Ctx, o: &str, args: &[Json], opn: &dyn Fn() -> Out, esc: &dyn Fn() -> Out) -> Out {
    let sf = c.sf;
    let chain = |l: usize, sep: Option<Kw>, lvl: usize| -> Out {
        let parts: Vec<Vec<Tok>> = args.iter().map(|x| pa(c, l, x)).collect();
        match sep {
            Some(k) => mk_out(lvl, sep_by(&[kw(k)], parts)),
            None => mk_out(lvl, mul_toks(parts)),
        }
    };
    match (kind_of(o), args) {
        (OpK::Minus, [a]) => {
            let t = pa(c, 5, a);
            let body = if starts_num(&t) { grp(sf, &t) } else { t };
            mk_out(5, cat(&[&[kw(Kw::Minus)], &body]))
        }
        (OpK::Minus, [a, b]) => mk_out(4, cat(&[&pa(c, 4, a), &[kw(Kw::Minus)], &pa(c, 5, b)])),
        (OpK::Div, [a, b]) => match sf {
            Sf::Latex => mk_out(
                10,
                cat(&[
                    &[kw(Kw::Frac), kw(Kw::Lb)],
                    &pa(c, 1, a),
                    &[kw(Kw::Rb), kw(Kw::Lb)],
                    &pa(c, 1, b),
                    &[kw(Kw::Rb)],
                ]),
            ),
            Sf::Typst => mk_out(7, cat(&[&pa(c, 8, a), &[kw(Kw::Slash)], &pa(c, 8, b)])),
        },
        (OpK::Pow, [a, b]) => {
            let ex = match sf {
                Sf::Latex => cat(&[&[kw(Kw::Lb)], &pa(c, 1, b), &[kw(Kw::Rb)]]),
                Sf::Typst => match simple_e(c, b) {
                    Some(t) => vec![t],
                    None => grp(sf, &pr(c, b).toks),
                },
            };
            mk_out(8, cat(&[&pa(c, 9, a), &[kw(Kw::Caret)], &ex]))
        }
        (OpK::Lnot, [a]) => mk_out(6, cat(&[&[kw(Kw::Lnot)], &pa(c, 6, a)])),
        (OpK::Tru, []) => mk_out(10, vec![Tok::Txt("true".into())]),
        (OpK::Fls, []) => mk_out(10, vec![Tok::Txt("false".into())]),
        (OpK::Ite, [cnd, a, b]) => {
            let mut rows = case_row(sf, pa(c, 1, a), pa(c, 1, cnd));
            rows.extend(pr(c, b).crow);
            Out {
                lvl: 10,
                toks: cases_toks(sf, &rows),
                crow: rows,
            }
        }
        (OpK::Un(k), [a]) => mk_out(10, un_toks(sf, k, pa(c, 1, a))),
        (OpK::Ic, [Json::Str(n)]) => {
            if name_ok(n) {
                mk_out(10, cat(&[&name_toks(c, n), &ic_tail(sf)]))
            } else {
                esc()
            }
        }
        (OpK::Index, [base, is @ ..]) if !is.is_empty() => {
            let subs = || is.iter().map(|x| pa(c, 1, x)).collect::<Vec<_>>();
            let sl = sub_list(sf, simple_arg(c, is), subs());
            if sub_ok(c.s, base, is) && !sub_pat(sf, &sl) {
                let b = match base {
                    Json::Str(s) => s.as_str(),
                    _ => "",
                };
                mk_out(9, cat(&[&name_toks(c, b), &sl]))
            } else {
                mk_out(
                    9,
                    cat(&[
                        &pa(c, 10, base),
                        &[kw(Kw::Lbk)],
                        &sep_by(&[kw(Kw::Comma)], subs()),
                        &[kw(Kw::Rbk)],
                    ]),
                )
            }
        }
        (OpK::Cmp(k), [a, b]) => mk_out(3, cat(&[&pa(c, 4, a), &[kw(k)], &pa(c, 4, b)])),
        (OpK::Plus, _) => {
            if 2 <= args.len() {
                chain(5, Some(Kw::Plus), 4)
            } else {
                opn()
            }
        }
        (OpK::Times, _) => {
            if 2 <= args.len() {
                chain(6, None, 5)
            } else {
                opn()
            }
        }
        (OpK::Land, _) => {
            if 2 <= args.len() {
                chain(3, Some(Kw::Land), 2)
            } else {
                opn()
            }
        }
        (OpK::Lor, _) => {
            if 2 <= args.len() {
                chain(2, Some(Kw::Lor), 1)
            } else {
                opn()
            }
        }
        (OpK::Mm(k), _) => {
            if 2 <= args.len() {
                mk_out(
                    10,
                    call_toks(sf, vec![kw(k)], args.iter().map(|x| pa(c, 1, x)).collect()),
                )
            } else {
                opn()
            }
        }
        (OpK::Nab(n), [a]) => mk_out(6, cat(&[&nab_head(sf, n), &nab_arg(sf, n, &pr(c, a))])),
        (OpK::Call, _) => mk_out(
            10,
            call_toks(
                sf,
                vec![Tok::Opn(o.into())],
                args.iter().map(|x| pa(c, 4, x)).collect(),
            ),
        ),
        _ => opn(),
    }
}

/// The `apply_operator` case of `Math.pr`.
fn pr_template(c: Ctx, n: &str, bs: &[(String, Json)], esc: &dyn Fn() -> Out) -> Out {
    let sf = c.sf;
    if !(tname_ok(n) && keys_sorted(bs) && bs.iter().all(|kv| is_e(&kv.1))) {
        return esc();
    }
    let vals: Vec<(String, Vec<Tok>)> = bs.iter().map(|(k, v)| (k.clone(), pa(c, 4, v))).collect();
    match positional(c.s, n, bs) {
        Some(ps) => mk_out(
            10,
            call_toks(
                sf,
                vec![Tok::Opn(n.into())],
                ps.iter()
                    .map(|p| {
                        vals.iter()
                            .find(|kv| &kv.0 == p)
                            .map(|kv| kv.1.clone())
                            .unwrap_or_default()
                    })
                    .collect(),
            ),
        ),
        None => {
            if !bs.is_empty() && bs.iter().all(|kv| name_ok(&kv.0)) {
                mk_out(
                    10,
                    call_toks(
                        sf,
                        vec![Tok::Opn(n.into())],
                        vals.iter()
                            .map(|(k, v)| cat(&[&name_toks(c, k), &[kw(Kw::Eq)], v]))
                            .collect(),
                    ),
                )
            } else if bs.is_empty() {
                mk_out(5, vec![Tok::Opn(n.into())])
            } else {
                esc()
            }
        }
    }
}

/// `Math.pa`: the tokens of an expression for a position needing level `L`.
pub fn pa(c: Ctx, l: usize, e: &Json) -> Vec<Tok> {
    pr(c, e).at(c.sf, l)
}

// ## The defining form of an equation
//
// An equation whose right side is a `faq` with output indices,
// `x = [body]_(s ∈ S)`, prints with the output indices on its left side and
// their ranges after its right side, `x_s = body, s ∈ S`. The right side is the
// reduction over the remaining ranges (a `faq` with no output indices), or the
// body alone when the `faq` reduces nothing and carries nothing else. The reader
// takes a trailing `, rows` after a whole equation back to the `faq`
// ([`unlift`]); the printer uses the form only when that gives back exactly the
// equation ([`lift_ok`]), and the bracket form otherwise.

/// `Math.sortKVs`: sort bindings by key (insertion, from the end of the list).
pub fn sort_kvs(xs: Vec<(String, Json)>) -> Vec<(String, Json)> {
    let mut out = Vec::new();
    for kv in xs.into_iter().rev() {
        out = ins_kv(kv, out);
    }
    out
}

/// `Math.isRedNode`: a `faq` node with no output indices.
pub fn is_red_node(j: &Json) -> bool {
    match j {
        Json::Obj(kvs) => matches!(
            (look("op", kvs), look("output_idx", kvs)),
            (Some(Json::Str(o)), Some(Json::Arr(os))) if o == "faq" && os.is_empty()
        ),
        _ => false,
    }
}

/// The equation node `{"args": [a, b], "op": o}` with exactly these two
/// entries: its arguments.
fn node2<'a>(j: &'a Json, o: &str) -> Option<&'a [Json]> {
    match j {
        Json::Obj(kvs) => match kvs.as_slice() {
            [(ka, Json::Arr(xs)), (ko, Json::Str(op))] if ka == "args" && ko == "op" && op == o => {
                Some(xs)
            }
            _ => None,
        },
        _ => None,
    }
}

/// `Math.unlift`: the equation `x_(os) = rhs` with the ranges `rows` of its
/// output indices, as the equation it writes: `x = faq` with the output indices
/// `os` and the rows' ranges, over `rhs` read as the reduction (a `faq` with no
/// output indices) or as the body.
pub fn unlift(q: &Json, rows: &[(String, Json)]) -> Option<Json> {
    let [lhs, rhs] = node2(q, "==")? else {
        return None;
    };
    let [Json::Str(x), os @ ..] = node2(lhs, "index")? else {
        return None;
    };
    let f = match rhs {
        Json::Obj(kvs) if is_red_node(rhs) => {
            let mut rs = match look("ranges", kvs) {
                Some(Json::Obj(rs)) => rs.clone(),
                _ => Vec::new(),
            };
            rs.extend(rows.iter().cloned());
            let mut fs = vec![
                ("output_idx".to_string(), Json::Arr(os.to_vec())),
                ("ranges".to_string(), Json::Obj(sort_kvs(rs))),
            ];
            fs.extend(
                kvs.iter()
                    .filter(|kv| kv.0 != "output_idx" && kv.0 != "ranges")
                    .cloned(),
            );
            Json::Obj(sort_kvs(fs))
        }
        _ => Json::Obj(vec![
            ("args".to_string(), Json::Arr(Vec::new())),
            ("expr".to_string(), rhs.clone()),
            ("op".to_string(), Json::Str("faq".to_string())),
            ("output_idx".to_string(), Json::Arr(os.to_vec())),
            ("ranges".to_string(), Json::Obj(sort_kvs(rows.to_vec()))),
        ]),
    };
    Some(Json::Obj(vec![
        ("args".to_string(), Json::Arr(vec![Json::Str(x.clone()), f])),
        ("op".to_string(), Json::Str("==".to_string())),
    ]))
}

/// `Math.liftParts`: the parts of the defining form of an equation `x = faq`:
/// the equation `x_(os) = rhs` and the ranges of the output indices, when the
/// left side is a name that takes a subscript and the `faq` has output indices.
pub fn lift_parts(e: &Json) -> Option<(Json, Vec<(String, Json)>)> {
    let [Json::Str(x), Json::Obj(kvs)] = node2(e, "==")? else {
        return None;
    };
    let (Some(Json::Str(o)), Some(Json::Arr(os)), Some(Json::Obj(rs))) = (
        look("op", kvs),
        look("output_idx", kvs),
        look("ranges", kvs),
    ) else {
        return None;
    };
    if o != "faq" || os.is_empty() || !plain_last(x) {
        return None;
    }
    let outs: Vec<&str> = os
        .iter()
        .filter_map(|o| match o {
            Json::Str(k) => Some(k.as_str()),
            _ => None,
        })
        .collect();
    let rows: Vec<(String, Json)> = outs
        .iter()
        .filter_map(|k| look(k, rs).map(|v| (k.to_string(), v.clone())))
        .collect();
    let rest: Vec<(String, Json)> = rs
        .iter()
        .filter(|kv| !outs.contains(&kv.0.as_str()))
        .cloned()
        .collect();
    let bare = rest.is_empty()
        && kvs.iter().all(|(k, v)| {
            matches!(k.as_str(), "expr" | "op" | "output_idx" | "ranges")
                || (k == "args" && matches!(v, Json::Arr(xs) if xs.is_empty()))
        });
    let body = look("expr", kvs).cloned().unwrap_or(Json::Null);
    let rhs = if bare && !is_red_node(&body) {
        body
    } else {
        let mut fs = vec![("output_idx".to_string(), Json::Arr(Vec::new()))];
        if !rest.is_empty() {
            fs.push(("ranges".to_string(), Json::Obj(rest)));
        }
        fs.extend(
            kvs.iter()
                .filter(|kv| kv.0 != "output_idx" && kv.0 != "ranges")
                .cloned(),
        );
        let rk = sort_kvs(fs);
        // The reduction must have its native spelling (`faqForm` and `faqOK`).
        match faq_form(&rk) {
            Some(f) if faq_ok(&f) => {}
            _ => return None,
        }
        Json::Obj(rk)
    };
    let mut ia = vec![Json::Str(x.clone())];
    ia.extend(os.iter().cloned());
    let lhs = Json::Obj(vec![
        ("args".to_string(), Json::Arr(ia)),
        ("op".to_string(), Json::Str("index".to_string())),
    ]);
    let q = Json::Obj(vec![
        ("args".to_string(), Json::Arr(vec![lhs, rhs])),
        ("op".to_string(), Json::Str("==".to_string())),
    ]);
    Some((q, rows))
}

/// `Math.liftOK`: the defining form is used: it reads back as exactly `e`.
pub fn lift_ok(e: &Json, q: &Json, rows: &[(String, Json)]) -> bool {
    !rows.is_empty()
        && is_e(q)
        && rows.iter().all(|(k, v)| {
            name_ok(k)
                && range_ok(v)
                && match v {
                    Json::Arr(xs) if xs.len() == 2 => is_e(&xs[0]) && is_e(&xs[1]),
                    _ => true,
                }
        })
        && match unlift(q, rows) {
            Some(e2) => jbeq(&e2, e),
            None => false,
        }
}

/// `Math.defRowsToks`: the range rows after a defining equation, separated by
/// commas.
pub fn def_rows_toks(c: Ctx, rows: &[(String, Json)]) -> Vec<Tok> {
    sep_by(
        &[Tok::Kw(Kw::Comma)],
        rows.iter().map(|(k, v)| row_toks(c, (k, v))).collect(),
    )
}

/// `Math.print`: the tokens of a whole expression: an equation `x = faq` with
/// output indices in its defining form when that reads back, otherwise as any
/// expression.
pub fn print(sf: Sf, s: &Sym, e: &Json) -> Vec<Tok> {
    let c = Ctx { sf, s };
    if let Some((q, rows)) = lift_parts(e)
        && lift_ok(e, &q, &rows)
    {
        let mut out = pa(c, 1, &q);
        out.push(Tok::Kw(Kw::Comma));
        out.extend(def_rows_toks(c, &rows));
        return out;
    }
    pa(c, 1, e)
}
