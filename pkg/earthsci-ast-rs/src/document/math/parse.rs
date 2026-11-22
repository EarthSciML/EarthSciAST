//! The parser: tokens to expressions.
//!
//! Port of `formal/Esm/Document/Math/Parse.lean` (and `parseToks` from
//! Induct.lean). Recursive descent with one function per precedence level
//! (see [`super::print`]), each taking fuel exactly as in Lean: a function at
//! fuel 0 fails, and every call passes on the fuel its Lean definition passes.
//! The chain loops (`orLoop`, `addLoop`, …) are loops here, spending one unit
//! of fuel per iteration as the Lean recursion does. The helpers whose fuel only
//! serves termination and is given as the input length (`pNameLoop`, `pNames`,
//! `pGrid`, `pCells`) loop without it.
//!
//! Not ported: `Math.expect`, `Math.mkNodeP`. No executable path uses them;
//! only the Lean proofs do.

use super::expr::{REMOVED_OPS, is_deprecated_op, is_formula, is_greek, is_letter, op_ok, pieces};
use super::print::{
    BMAT_MAX_COLS, Ctx, FIELD_CALL_OPS, FaqForm, MkForm, RedK, faq_json, formula_raw, ins_kv,
    is_call_op, is_notation_core, mk_json, mk_node, node, prints_as_call, simple_tok, tname_ok,
    tparams, unesc_k, unesc_t,
};
use super::surface::neg_num;
use super::token::{Kw, Sf, Tok};
use super::units::{self, Factor};
use crate::document::json::{JNum, Json};
use crate::document::limits::{self, Nest};

/// A parse result: the value and the rest of the tokens.
pub type P<'a, T> = Option<(T, &'a [Tok])>;

/// Named ranges (`List (String × Json)`).
pub type Ranges = Vec<(String, Json)>;

// ## Small pieces

/// `Math.close`: close an n-ary chain: one operand is itself, more make a node.
pub fn close(o: &str, xs: Vec<Json>) -> Json {
    if xs.len() == 1 {
        xs.into_iter().next().unwrap()
    } else {
        node(o, xs)
    }
}

/// `Math.cmpOf`: the comparison a token spells.
pub fn cmp_of(k: Kw) -> Option<&'static str> {
    match k {
        Kw::Lt => Some("<"),
        Kw::Le => Some("<="),
        Kw::Gt => Some(">"),
        Kw::Ge => Some(">="),
        Kw::Eq => Some("=="),
        Kw::Ne => Some("!="),
        _ => None,
    }
}

/// `Math.fnOf`: the unary function a keyword spells.
pub fn fn_of(k: Kw) -> Option<&'static str> {
    match k {
        Kw::Exp => Some("exp"),
        Kw::Ln => Some("log"),
        Kw::Sin => Some("sin"),
        Kw::Cos => Some("cos"),
        Kw::Tan => Some("tan"),
        Kw::Asin => Some("asin"),
        Kw::Acos => Some("acos"),
        Kw::Atan => Some("atan"),
        Kw::Sinh => Some("sinh"),
        Kw::Cosh => Some("cosh"),
        Kw::Tanh => Some("tanh"),
        _ => None,
    }
}

/// `Math.atomStart`: tokens that can start an operand of a product.
pub fn atom_start(t: &Tok) -> bool {
    match t {
        Tok::Num(_)
        | Tok::Letter(_)
        | Tok::Greek(_)
        | Tok::Word(_)
        | Tok::It(_)
        | Tok::Rm(_)
        | Tok::Ups(_)
        | Tok::Opn(_)
        | Tok::Txt(_)
        | Tok::Esc(_) => true,
        Tok::Kw(k) => matches!(
            k,
            Kw::Lpg
                | Kw::Lp
                | Kw::Lbk
                | Kw::Lnot
                | Kw::Frac
                | Kw::Sqrt
                | Kw::Exp
                | Kw::Ln
                | Kw::Log
                | Kw::Sin
                | Kw::Cos
                | Kw::Tan
                | Kw::Asin
                | Kw::Acos
                | Kw::Atan
                | Kw::Sinh
                | Kw::Cosh
                | Kw::Tanh
                | Kw::Min
                | Kw::Max
                | Kw::Labs
                | Kw::Lfloor
                | Kw::Lceil
                | Kw::Abs
                | Kw::Floor
                | Kw::Ceil
                | Kw::Dotacc
                | Kw::Bcases
                | Kw::Cases
                | Kw::Esmnode
                | Kw::Bmat
                | Kw::Vec
                | Kw::Mat
                | Kw::Sum
                | Kw::Prod
                | Kw::Limits
                | Kw::Lbkg
                | Kw::Lr
        ),
        _ => false,
    }
}

/// `Math.isLp`: `(` or `\left(`.
pub fn is_lp(t: &Tok) -> bool {
    matches!(t, Tok::Kw(Kw::Lp | Kw::Lpg))
}

/// `Math.isRp`: `)` or `\right)`.
pub fn is_rp(t: &Tok) -> bool {
    matches!(t, Tok::Kw(Kw::Rp | Kw::Rpg))
}

/// `Math.isKw`: the token is the keyword `k`.
pub fn is_kw(k: Kw, t: &Tok) -> bool {
    matches!(t, Tok::Kw(k2) if *k2 == k)
}

fn s_of(cs: &[char]) -> String {
    cs.iter().collect()
}

// ## Names

/// `Math.decodeFormula`.
pub fn decode_formula(raw: &[char]) -> Vec<char> {
    raw.iter()
        .copied()
        .filter(|&c| c != '_' && c != '{' && c != '}')
        .collect()
}

/// `Math.formulaOf`: the name a formula token spells, if it is formula-shaped.
pub fn formula_of(sf: Sf, t: &Tok) -> Option<Vec<char>> {
    match t {
        Tok::Rm(raw) if sf == Sf::Latex => {
            let rc: Vec<char> = raw.chars().collect();
            let g = decode_formula(&rc);
            if is_formula(&g) && formula_raw(&g) == rc {
                Some(g)
            } else {
                None
            }
        }
        Tok::Ups(ps) if sf == Sf::Typst => {
            let g: Vec<char> = ps
                .iter()
                .flat_map(|p| p.0.chars().chain(p.1.chars()))
                .collect();
            let back: Vec<(String, String)> =
                pieces(&g).iter().map(|(a, b)| (s_of(a), s_of(b))).collect();
            if is_formula(&g) && back == *ps {
                Some(g)
            } else {
                None
            }
        }
        _ => None,
    }
}

/// `Math.subOrPlain`: a single letter or Greek base, then an optional upright
/// name subscript.
pub fn sub_or_plain(sf: Sf, b: Vec<char>, r: &[Tok]) -> (Vec<char>, &[Tok]) {
    match (sf, r) {
        (
            Sf::Latex,
            [
                Tok::Kw(Kw::Us),
                Tok::Kw(Kw::Lb),
                Tok::Rm(raw),
                Tok::Kw(Kw::Rb),
                r2 @ ..,
            ],
        ) => {
            let mut g = b;
            g.push('_');
            let rc: Vec<char> = raw.chars().collect();
            g.extend(unesc_t(&rc));
            (g, r2)
        }
        (
            Sf::Typst,
            [
                Tok::Kw(Kw::Us),
                Tok::Kw(Kw::Lpg),
                Tok::Ups(ps),
                Tok::Kw(Kw::Rp),
                r2 @ ..,
            ],
        ) if ps.len() == 1 && ps[0].1.is_empty() => {
            let mut g = b;
            g.push('_');
            g.extend(ps[0].0.chars());
            (g, r2)
        }
        _ => (b, r),
    }
}

/// `Math.pSeg`: one name segment.
pub fn p_seg(sf: Sf, ts: &[Tok]) -> P<'_, Vec<char>> {
    match ts {
        [Tok::Letter(ch), r @ ..] => {
            if is_letter(*ch) {
                Some(sub_or_plain(sf, vec![*ch], r))
            } else {
                None
            }
        }
        [Tok::Greek(g), r @ ..] => {
            let gc: Vec<char> = g.chars().collect();
            if is_greek(&gc) {
                Some(sub_or_plain(sf, gc, r))
            } else {
                None
            }
        }
        [Tok::It(s), r @ ..] => Some((s.chars().collect(), r)),
        [t, r @ ..] => formula_of(sf, t).map(|g| (g, r)),
        [] => None,
    }
}

/// `Math.pName`: a name: segments joined by the scope dot (`pNameLoop` as a
/// loop; its fuel, the input length, is never exhausted).
pub fn p_name(sf: Sf, ts: &[Tok]) -> P<'_, String> {
    let (mut acc, mut r) = p_seg(sf, ts)?;
    loop {
        match r {
            [Tok::Kw(Kw::Sdot), r1 @ ..] => {
                let (g, r2) = p_seg(sf, r1)?;
                acc.push('.');
                acc.extend(g);
                r = r2;
            }
            _ => return Some((s_of(&acc), r)),
        }
    }
}

// ## JSON inside LaTeX escape nodes

/// `Math.pJson`.
pub fn p_json(f: usize, ts: &[Tok]) -> P<'_, Json> {
    let f = f.checked_sub(1)?;
    let _nest = Nest::enter()?;
    match ts {
        [Tok::Word(w), r @ ..] if w == "null" => Some((Json::Null, r)),
        [Tok::Word(w), r @ ..] if w == "true" => Some((Json::Bool(true), r)),
        [Tok::Word(w), r @ ..] if w == "false" => Some((Json::Bool(false), r)),
        [Tok::Num(n), r @ ..] => Some((Json::Num(n.clone()), r)),
        [Tok::Jstr(s), r @ ..] => Some((Json::Str(s.clone()), r)),
        [Tok::Kw(Kw::Lbk), Tok::Kw(Kw::Rbk), r @ ..] => Some((Json::Arr(vec![]), r)),
        [Tok::Kw(Kw::Lbk), r @ ..] => match p_json_items(f, r) {
            Some((xs, [Tok::Kw(Kw::Rbk), r2 @ ..])) => Some((Json::Arr(xs), r2)),
            _ => None,
        },
        [Tok::Kw(Kw::Lb), Tok::Kw(Kw::Rb), r @ ..] => Some((Json::Obj(vec![]), r)),
        [Tok::Kw(Kw::Lb), r @ ..] => match p_json_entries(f, r) {
            Some((kvs, [Tok::Kw(Kw::Rb), r2 @ ..])) => Some((Json::Obj(kvs), r2)),
            _ => None,
        },
        _ => None,
    }
}

/// `Math.pJsonItems`.
pub fn p_json_items(f: usize, ts: &[Tok]) -> P<'_, Vec<Json>> {
    let mut out = Vec::new();
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        match p_json(f, ts)? {
            (v, [Tok::Kw(Kw::Comma), r @ ..]) => {
                out.push(v);
                ts = r;
            }
            (v, r) => {
                out.push(v);
                return Some((out, r));
            }
        }
    }
}

/// `Math.pJsonEntries`.
pub fn p_json_entries(f: usize, ts: &[Tok]) -> P<'_, Vec<(String, Json)>> {
    let mut out = Vec::new();
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        let [Tok::Jstr(k), Tok::Kw(Kw::Colon), r0 @ ..] = ts else {
            return None;
        };
        match p_json(f, r0)? {
            (v, [Tok::Kw(Kw::Comma), r @ ..]) => {
                out.push((k.clone(), v));
                ts = r;
            }
            (v, r) => {
                out.push((k.clone(), v));
                return Some((out, r));
            }
        }
    }
}

// ## Negative literals after an operand

/// `Math.negTok`: a negative literal token.
pub fn neg_tok(t: &Tok) -> bool {
    matches!(t, Tok::Num(n) if neg_num(n))
}

/// `Math.negate`: the number with the opposite sign.
pub fn negate(n: &JNum) -> JNum {
    match n {
        JNum::Int(z) => JNum::Int(-z),
        JNum::Dec { neg, digits, e10 } => JNum::Dec {
            neg: !neg,
            digits: digits.clone(),
            e10: *e10,
        },
    }
}

/// `Math.negTail`: a negative literal right after an operand is a binary minus
/// and a positive number. Returns the number without its sign; the tokens
/// after it are the input's own (Lean returns the list with the number
/// replaced).
pub fn neg_tail(ts: &[Tok]) -> Option<(JNum, &[Tok])> {
    match ts {
        [Tok::Num(n), r @ ..] => {
            let m = negate(n);
            if neg_num(n) && m.wfb() {
                Some((m, r))
            } else {
                None
            }
        }
        _ => None,
    }
}

// ## Expressions

/// `Math.CallArg`: what `pCallArgs` read.
#[derive(Clone, Debug, PartialEq)]
pub enum CallArg {
    Pos(Json),
    Named(String, Json),
}

/// `Math.allPos`.
pub fn all_pos(xs: &[CallArg]) -> Option<Vec<Json>> {
    xs.iter()
        .map(|a| match a {
            CallArg::Pos(v) => Some(v.clone()),
            CallArg::Named(..) => None,
        })
        .collect()
}

/// `Math.allNamed`.
pub fn all_named(xs: &[CallArg]) -> Option<Vec<(String, Json)>> {
    xs.iter()
        .map(|a| match a {
            CallArg::Named(k, v) => Some((k.clone(), v.clone())),
            CallArg::Pos(_) => None,
        })
        .collect()
}

/// `Math.sortKV`: sort bindings by key (insertion from the right, so equal
/// keys keep their order).
pub fn sort_kv(xs: Vec<(String, Json)>) -> Vec<(String, Json)> {
    let mut out = Vec::new();
    for kv in xs.into_iter().rev() {
        out = ins_kv(kv, out);
    }
    out
}

/// `Math.unitsOfRaw`: the unit a LaTeX `\mathrm{…}` after a number spells.
pub fn units_of_raw(raw: &[char]) -> Option<Vec<Factor>> {
    let mut s = units::MATHRM_OPEN.to_vec();
    s.extend_from_slice(raw);
    s.push('}');
    units::parse_latex(&s)
}

/// `Math.qty`: a quantity node.
pub fn qty(n: &JNum, l: &[Factor]) -> Json {
    Json::Obj(vec![
        ("args".into(), Json::Arr(vec![])),
        ("op".into(), Json::str("const")),
        (
            "units".into(),
            Json::Str(crate::units::spell_unit_factors(l)),
        ),
        ("value".into(), Json::Num(n.clone())),
    ])
}

/// `Math.dNode`: a derivative node.
pub fn d_node(x: Json, w: &str) -> Json {
    Json::Obj(vec![
        ("args".into(), Json::Arr(vec![x])),
        ("op".into(), Json::str("D")),
        ("wrt".into(), Json::str(w)),
    ])
}

/// `Math.tNode`: a template application node.
pub fn t_node(n: &str, bs: Vec<(String, Json)>) -> Json {
    Json::Obj(vec![
        ("args".into(), Json::Arr(vec![])),
        ("bindings".into(), Json::Obj(bs)),
        ("name".into(), Json::str(n)),
        ("op".into(), Json::str("apply_operator")),
    ])
}

/// `Math.constNode`: the value, and the units when there are some.
pub fn const_node(v: Json, u: Option<String>) -> Json {
    match u {
        None => Json::Obj(vec![
            ("args".into(), Json::Arr(vec![])),
            ("op".into(), Json::str("const")),
            ("value".into(), v),
        ]),
        Some(u) => Json::Obj(vec![
            ("args".into(), Json::Arr(vec![])),
            ("op".into(), Json::str("const")),
            ("units".into(), Json::Str(u)),
            ("value".into(), v),
        ]),
    }
}

/// `Math.pCells`: numbers separated by `sep`, up to the first other token.
pub fn p_cells(sep: Kw, ts: &[Tok]) -> P<'_, Vec<JNum>> {
    let mut out = Vec::new();
    let mut ts = ts;
    loop {
        match ts {
            [Tok::Num(n), Tok::Kw(k), r @ ..] => {
                out.push(n.clone());
                if *k == sep {
                    ts = r;
                } else {
                    return Some((out, &ts[1..]));
                }
            }
            [Tok::Num(n), r @ ..] => {
                out.push(n.clone());
                return Some((out, r));
            }
            _ => return None,
        }
    }
}

/// `Math.pGrid`: rows of numbers: cells separated by `csep`, rows by `rsep`,
/// closed by `close`.
pub fn p_grid(csep: Kw, rsep: Kw, close: Kw, ts: &[Tok]) -> P<'_, Vec<Vec<JNum>>> {
    let mut out = Vec::new();
    let mut ts = ts;
    loop {
        match p_cells(csep, ts) {
            Some((row, [Tok::Kw(k), r @ ..])) => {
                out.push(row);
                if *k == rsep {
                    ts = r;
                } else if *k == close {
                    return Some((out, r));
                } else {
                    return None;
                }
            }
            _ => return None,
        }
    }
}

/// `Math.gridJson`: a LaTeX `bmatrix`: one cell per row is a column (rank 1).
pub fn grid_json(rows: Vec<Vec<JNum>>) -> Json {
    if rows.iter().all(|r| r.len() == 1) {
        Json::Arr(
            rows.into_iter()
                .map(|r| Json::Num(r.into_iter().next().unwrap_or(JNum::Int(0))))
                .collect(),
        )
    } else {
        Json::Arr(
            rows.into_iter()
                .map(|r| Json::Arr(r.into_iter().map(Json::Num).collect()))
                .collect(),
        )
    }
}

/// `Math.constTail`: the unit after an array, if any.
pub fn const_tail(v: Json, r: &[Tok]) -> P<'_, Json> {
    match r {
        [Tok::Units(l), r2 @ ..] => {
            Some((const_node(v, Some(crate::units::spell_unit_factors(l))), r2))
        }
        _ => Some((const_node(v, None), r)),
    }
}

/// `Math.icTailP`: the `ic` tail `(t_{0})` / `(t_0)`.
pub fn ic_tail_p(sf: Sf, ts: &[Tok]) -> Option<&[Tok]> {
    match ts {
        [Tok::Kw(Kw::Lp), Tok::Letter('t'), Tok::Kw(Kw::Us), r @ ..] => match (sf, r) {
            (
                Sf::Latex,
                [
                    Tok::Kw(Kw::Lb),
                    Tok::Num(JNum::Int(0)),
                    Tok::Kw(Kw::Rb),
                    Tok::Kw(Kw::Rp),
                    r2 @ ..,
                ],
            ) => Some(r2),
            (Sf::Typst, [Tok::Num(JNum::Int(0)), Tok::Kw(Kw::Rp), r2 @ ..]) => Some(r2),
            _ => None,
        },
        _ => None,
    }
}

/// `Math.jsonStart`: a LaTeX field value that is JSON starts with `{`, `[`, a
/// string or a word.
pub fn json_start(ts: &[Tok]) -> bool {
    matches!(
        ts.first(),
        Some(Tok::Kw(Kw::Lb) | Tok::Kw(Kw::Lbk) | Tok::Jstr(_) | Tok::Word(_))
    )
}

/// `Math.keyOf`: a field key: LaTeX `\mathrm{key} =`, Typst `upright("key") =`.
pub fn key_of<'a>(c: Ctx, ts: &'a [Tok]) -> P<'a, String> {
    match (c.sf, ts) {
        (Sf::Latex, [Tok::Rm(raw), Tok::Kw(Kw::Eq), r @ ..]) => {
            let rc: Vec<char> = raw.chars().collect();
            Some((s_of(&unesc_k(&rc)), r))
        }
        (Sf::Typst, [Tok::Ups(ps), Tok::Kw(Kw::Eq), r @ ..])
            if ps.len() == 1 && ps[0].1.is_empty() =>
        {
            Some((ps[0].0.clone(), r))
        }
        _ => None,
    }
}

/// `Math.dCallNode`: a spatial derivative with trailing operands.
pub fn d_call_node(w: &str, xs: Vec<Json>) -> Json {
    Json::Obj(vec![
        ("args".into(), Json::Arr(xs)),
        ("op".into(), Json::str("D")),
        ("wrt".into(), Json::str(w)),
    ])
}

fn declared(c: Ctx, n: &str) -> bool {
    c.s.names.iter().any(|x| x == n)
}

/// `Math.eulerHead`: the input starts with Euler's number raised to a power.
pub fn euler_head(c: Ctx, ts: &[Tok]) -> bool {
    match ts {
        [Tok::Rm(raw), Tok::Kw(Kw::Caret), ..] => raw == "e",
        [Tok::Ups(ps), Tok::Kw(Kw::Caret), ..] => {
            ps.len() == 1 && ps[0].0 == "e" && ps[0].1.is_empty()
        }
        [Tok::Letter(ch), Tok::Kw(Kw::Caret), ..] => *ch == 'e' && !declared(c, "e"),
        _ => false,
    }
}

/// `Math.pNamePrim`: a name, or an initial condition `N(t_{0})`.
pub fn p_name_prim<'a>(c: Ctx, ts: &'a [Tok]) -> P<'a, Json> {
    let (n, r) = p_name(c.sf, ts)?;
    match ic_tail_p(c.sf, r) {
        Some(r2) => Some((node("ic", vec![Json::Str(n)]), r2)),
        None => Some((Json::Str(n), r)),
    }
}

/// `Math.pWord`: a bare run of letters: the declared name when only it is
/// declared, the product of its letters when only they are.
pub fn p_word<'a>(c: Ctx, w: &str, r: &'a [Tok]) -> P<'a, Json> {
    let whole = declared(c, w);
    let letters = w.chars().all(|ch| declared(c, &ch.to_string()));
    if whole && !letters {
        Some((Json::str(w), r))
    } else if letters && !whole {
        Some((
            node("*", w.chars().map(|ch| Json::Str(ch.to_string())).collect()),
            r,
        ))
    } else {
        None
    }
}

/// `Math.dName`: `d` then a name, up to a closing token `k`.
pub fn d_name<'a>(c: Ctx, k: Kw, ts: &'a [Tok]) -> P<'a, String> {
    match ts {
        [Tok::Word(w), Tok::Kw(k2), r @ ..] => {
            if *k2 == k && !declared(c, w) {
                let mut it = w.chars();
                match it.next() {
                    Some('d') => Some((it.collect(), r)),
                    _ => None,
                }
            } else {
                None
            }
        }
        [Tok::Letter('d'), r @ ..] => match p_name(c.sf, r) {
            Some((n, [Tok::Kw(k2), r2 @ ..])) => {
                if *k2 == k {
                    Some((n, r2))
                } else {
                    None
                }
            }
            _ => None,
        },
        _ => None,
    }
}

/// `Math.pItalicD`: the italic-d derivative variant.
pub fn p_italic_d<'a>(c: Ctx, r: &'a [Tok]) -> P<'a, Json> {
    if declared(c, "d") {
        return None;
    }
    match c.sf {
        Sf::Latex => match d_name(c, Kw::Rb, r) {
            Some((n, [Tok::Kw(Kw::Lb), r1 @ ..])) => {
                d_name(c, Kw::Rb, r1).map(|(w, r2)| (d_node(Json::Str(n), &w), r2))
            }
            _ => None,
        },
        Sf::Typst => match d_name(c, Kw::Rp, r) {
            Some((n, [Tok::Kw(Kw::Slash), Tok::Kw(Kw::Lpg), r1 @ ..])) => {
                d_name(c, Kw::Rp, r1).map(|(w, r2)| (d_node(Json::Str(n), &w), r2))
            }
            _ => None,
        },
    }
}

/// `Math.Row`: a row of a reduction's subscript, or an output entry.
#[derive(Clone, Debug, PartialEq)]
pub enum Row {
    Rng(String, Json),
    Filt(Json),
}

/// `Math.redOf`.
pub fn red_of(k: Kw) -> Option<RedK> {
    match k {
        Kw::Sum => Some(RedK::Sum),
        Kw::Prod => Some(RedK::Prod),
        Kw::Max => Some(RedK::Max),
        Kw::Min => Some(RedK::Min),
        _ => None,
    }
}

/// `Math.pRedHead`: the operator of a reduction and whether it is marked.
pub fn p_red_head(sf: Sf, ts: &[Tok]) -> Option<(RedK, bool, &[Tok])> {
    match ts {
        [
            Tok::Kw(Kw::Limits),
            Tok::Kw(Kw::Lp),
            Tok::Kw(k),
            Tok::Kw(Kw::Rp),
            r @ ..,
        ] => {
            if sf == Sf::Typst {
                red_of(*k).map(|red| (red, true, r))
            } else {
                None
            }
        }
        [Tok::Kw(k), Tok::Kw(Kw::LimitsL), r @ ..] => {
            if sf == Sf::Latex {
                red_of(*k).map(|red| (red, true, r))
            } else {
                red_of(*k).map(|red| (red, false, &ts[1..]))
            }
        }
        [Tok::Kw(k), r @ ..] => red_of(*k).map(|red| (red, false, r)),
        _ => None,
    }
}

/// `Math.pNames`: names separated by commas (fuel, the input length, dropped).
pub fn p_names(sf: Sf, ts: &[Tok]) -> P<'_, Vec<String>> {
    let mut out = Vec::new();
    let mut ts = ts;
    loop {
        match p_name(sf, ts)? {
            (n, [Tok::Kw(Kw::Comma), r @ ..]) => {
                out.push(n);
                ts = r;
            }
            (n, r) => {
                out.push(n);
                return Some((out, r));
            }
        }
    }
}

/// `Math.rowParts`: ranges, then at most one filter, last.
pub fn row_parts(rows: Vec<Row>) -> Option<(Ranges, Option<Json>)> {
    let n = rows.len();
    let mut rg = Vec::new();
    let mut fl = None;
    for (i, row) in rows.into_iter().enumerate() {
        match row {
            Row::Rng(k, v) => rg.push((k, v)),
            Row::Filt(x) => {
                if i + 1 == n {
                    fl = Some(x);
                } else {
                    return None;
                }
            }
        }
    }
    Some((rg, fl))
}

/// `Math.entryParts`: the output entries of a list of entry rows, with their
/// ranges.
pub fn entry_parts(rows: Vec<Row>) -> Option<(Vec<Json>, Ranges)> {
    let mut outs = Vec::new();
    let mut rs = Vec::new();
    for row in rows {
        match row {
            Row::Rng(k, v) => {
                outs.push(Json::Str(k.clone()));
                rs.push((k, v));
            }
            Row::Filt(Json::Str(k)) => outs.push(Json::Str(k)),
            Row::Filt(Json::Num(JNum::Int(1))) => outs.push(Json::Num(JNum::Int(1))),
            Row::Filt(_) => return None,
        }
    }
    Some((outs, rs))
}

/// `Math.withOut`: the reduction's parts with the output entries.
pub fn with_out(f: FaqForm, outs: Vec<Json>, ors: Vec<(String, Json)>) -> FaqForm {
    let mut rs = ors;
    rs.extend(f.ranges.iter().cloned());
    FaqForm {
        out: outs,
        ranges: sort_kv(rs),
        ..f
    }
}

/// `Math.withSup`: the superscript set read on the bracket of an output form
/// (the reduction inside carries none).
pub fn with_sup(f: FaqForm, st: Vec<String>) -> FaqForm {
    FaqForm { set: st, ..f }
}

/// `Math.pSup`: the superscript set of a reduction or of an output form, if
/// there is one: LaTeX `^{\{f, g\}}`, Typst `^({f, g})`.
pub fn p_sup(sf: Sf, r: &[Tok]) -> P<'_, Vec<String>> {
    match (sf, r) {
        (
            Sf::Latex,
            [
                Tok::Kw(Kw::Caret),
                Tok::Kw(Kw::Lb),
                Tok::Kw(Kw::Lset),
                r1 @ ..,
            ],
        ) => match p_names(sf, r1)? {
            (ns, [Tok::Kw(Kw::Rset), Tok::Kw(Kw::Rb), r2 @ ..]) => Some((ns, r2)),
            _ => None,
        },
        (
            Sf::Typst,
            [
                Tok::Kw(Kw::Caret),
                Tok::Kw(Kw::Lpg),
                Tok::Kw(Kw::Lset),
                r1 @ ..,
            ],
        ) => match p_names(sf, r1)? {
            (ns, [Tok::Kw(Kw::Rset), Tok::Kw(Kw::Rp), r2 @ ..]) => Some((ns, r2)),
            _ => None,
        },
        _ => Some((vec![], r)),
    }
}

/// A row of a `makearray` table: the value and the region it fills.
pub type MkRow = (Json, Vec<(Json, Json)>);

/// `Math.mkTail`: the `makearray` node of a table read back, with its
/// subscript of output indices if one follows.
pub fn mk_tail(sf: Sf, rows: Vec<MkRow>, r: &[Tok]) -> P<'_, Json> {
    let node_of = |out: Vec<String>| {
        let (values, regions): (Vec<Json>, Vec<Vec<(Json, Json)>>) = rows.into_iter().unzip();
        mk_json(&MkForm {
            out,
            regions,
            values,
        })
    };
    match (sf, r) {
        (Sf::Latex, [Tok::Kw(Kw::Us), Tok::Kw(Kw::Lb), r1 @ ..]) => match p_names(sf, r1)? {
            (ns, [Tok::Kw(Kw::Rb), r2 @ ..]) => Some((node_of(ns), r2)),
            _ => None,
        },
        (Sf::Typst, [Tok::Kw(Kw::Us), Tok::Kw(Kw::Lpg), r1 @ ..]) => match p_names(sf, r1)? {
            (ns, [Tok::Kw(Kw::Rp), r2 @ ..]) => Some((node_of(ns), r2)),
            _ => None,
        },
        _ => Some((node_of(vec![]), r)),
    }
}

// ## The level parsers

/// `Math.pOr`: level 1, an `or` chain.
pub fn p_or<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    let (x, r) = p_and(c, f, ts)?;
    or_loop(c, f, vec![x], r)
}

/// `Math.orLoop`.
pub fn or_loop<'a>(c: Ctx, f: usize, acc: Vec<Json>, ts: &'a [Tok]) -> P<'a, Json> {
    let mut acc = acc;
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        match ts {
            [Tok::Kw(Kw::Lor), r @ ..] => {
                let (y, r2) = p_and(c, f, r)?;
                acc.push(y);
                ts = r2;
            }
            _ => return Some((close("or", acc), ts)),
        }
    }
}

/// `Math.pAnd`: level 2, an `and` chain.
pub fn p_and<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    let (x, r) = p_cmp(c, f, ts)?;
    and_loop(c, f, vec![x], r)
}

/// `Math.andLoop`.
pub fn and_loop<'a>(c: Ctx, f: usize, acc: Vec<Json>, ts: &'a [Tok]) -> P<'a, Json> {
    let mut acc = acc;
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        match ts {
            [Tok::Kw(Kw::Land), r @ ..] => {
                let (y, r2) = p_cmp(c, f, r)?;
                acc.push(y);
                ts = r2;
            }
            _ => return Some((close("and", acc), ts)),
        }
    }
}

/// `Math.pCmp`: level 3, one comparison.
pub fn p_cmp<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    let (x, r) = p_add(c, f, ts)?;
    cmp_loop(c, f, x, r)
}

/// `Math.cmpLoop`.
pub fn cmp_loop<'a>(c: Ctx, f: usize, x: Json, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    match ts {
        [Tok::Kw(k), r @ ..] => match cmp_of(*k) {
            Some(o) => {
                let (y, r2) = p_add(c, f, r)?;
                Some((node(o, vec![x, y]), r2))
            }
            None => Some((x, ts)),
        },
        _ => Some((x, ts)),
    }
}

/// `Math.pAdd`: level 4, `+` chains and binary `-`.
pub fn p_add<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    let (x, r) = p_mul(c, f, ts)?;
    add_loop(c, f, vec![x], r)
}

/// `Math.addLoop`. After `negTail`, Lean parses the list with the number's
/// sign removed; here that list is built and the rest mapped back onto the
/// input (the rest is a suffix of the input's tail either way).
pub fn add_loop<'a>(c: Ctx, f: usize, acc: Vec<Json>, ts: &'a [Tok]) -> P<'a, Json> {
    let mut acc = acc;
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        match ts {
            [Tok::Kw(Kw::Plus), r @ ..] => {
                let (y, r2) = p_mul(c, f, r)?;
                acc.push(y);
                ts = r2;
            }
            [Tok::Kw(Kw::Minus), r @ ..] => {
                let (y, r2) = p_mul(c, f, r)?;
                acc = vec![limits::shallow(node("-", vec![close("+", acc), y]))?];
                ts = r2;
            }
            _ => match neg_tail(ts) {
                Some((m, r)) => {
                    let mut r1 = Vec::with_capacity(r.len() + 1);
                    r1.push(Tok::Num(m));
                    r1.extend_from_slice(r);
                    let (y, rest) = p_mul(c, f, &r1)?;
                    let n = rest.len();
                    // the parse consumed at least the number token
                    let r2 = &r[r.len() - n.min(r.len())..];
                    acc = vec![limits::shallow(node("-", vec![close("+", acc), y]))?];
                    ts = r2;
                }
                None => return Some((close("+", acc), ts)),
            },
        }
    }
}

/// `Math.pMul`: level 5, unary minus and `*` chains.
pub fn p_mul<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    let _nest = Nest::enter()?;
    match ts {
        [Tok::Kw(Kw::Minus), r @ ..] => {
            let (x, r2) = p_mul(c, f, r)?;
            Some((node("-", vec![x]), r2))
        }
        _ => {
            let (x, r) = p_not(c, f, ts)?;
            mul_loop(c, f, vec![x], r)
        }
    }
}

/// `Math.mulLoop`.
pub fn mul_loop<'a>(c: Ctx, f: usize, acc: Vec<Json>, ts: &'a [Tok]) -> P<'a, Json> {
    let mut acc = acc;
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        match ts {
            [Tok::Kw(Kw::Cdot | Kw::Times), r @ ..] => {
                let (y, r2) = p_not(c, f, r)?;
                acc.push(y);
                ts = r2;
            }
            [Tok::Kw(Kw::Slash), r @ ..] => {
                if c.sf == Sf::Latex {
                    let (y, r2) = p_not(c, f, r)?;
                    acc = vec![limits::shallow(node("/", vec![close("*", acc), y]))?];
                    ts = r2;
                } else {
                    return Some((close("*", acc), ts));
                }
            }
            [t, ..] => {
                if atom_start(t) && !neg_tok(t) {
                    let (y, r2) = p_not(c, f, ts)?;
                    acc.push(y);
                    ts = r2;
                } else {
                    return Some((close("*", acc), ts));
                }
            }
            [] => return Some((close("*", acc), ts)),
        }
    }
}

/// `Math.pNot`: level 6, `not`.
pub fn p_not<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    let _nest = Nest::enter()?;
    match ts {
        [Tok::Kw(Kw::Lnot), r @ ..] => {
            let (x, r2) = p_not(c, f, r)?;
            Some((node("not", vec![x]), r2))
        }
        _ => p_frac(c, f, ts),
    }
}

/// `Math.pFrac`: level 7, the Typst fraction, grouping to the left.
pub fn p_frac<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    let (x, r) = p_pow(c, f, ts)?;
    frac_loop(c, f, x, r)
}

/// `Math.fracLoop`.
pub fn frac_loop<'a>(c: Ctx, f: usize, x: Json, ts: &'a [Tok]) -> P<'a, Json> {
    let mut x = x;
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        match ts {
            [Tok::Kw(Kw::Slash), r @ ..] if c.sf == Sf::Typst => {
                let (y, r2) = p_pow(c, f, r)?;
                x = limits::shallow(node("/", vec![x, y]))?;
                ts = r2;
            }
            _ => return Some((x, ts)),
        }
    }
}

/// `Math.pPow`: level 8, a power.
pub fn p_pow<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    match p_post(c, f, ts)? {
        (x, [Tok::Kw(Kw::Caret), r @ ..]) => {
            let (y, r2) = p_expo(c, f, r)?;
            Some((node("^", vec![x, y]), r2))
        }
        (x, r) => Some((x, r)),
    }
}

/// `Math.pExpo`: an exponent: LaTeX `{…}`; Typst `(…)` or one simple token.
pub fn p_expo<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    match (c.sf, ts) {
        (Sf::Latex, [Tok::Kw(Kw::Lb), r @ ..]) => match p_or(c, f, r) {
            Some((y, [Tok::Kw(Kw::Rb), r2 @ ..])) => Some((y, r2)),
            _ => None,
        },
        (Sf::Typst, [Tok::Kw(Kw::Lpg), r @ ..]) => match p_or(c, f, r) {
            Some((y, [t, r2 @ ..])) => {
                if is_rp(t) {
                    Some((y, r2))
                } else {
                    None
                }
            }
            _ => None,
        },
        (Sf::Typst, [t, r @ ..]) => {
            if simple_tok(t) {
                match p_prim(c, f, std::slice::from_ref(t)) {
                    Some((y, [])) => Some((y, r)),
                    _ => None,
                }
            } else {
                None
            }
        }
        _ => None,
    }
}

/// `Math.pPost`: level 9, postfix index, `_{…}` or `[…]`.
pub fn p_post<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    let (x, r) = p_prim(c, f, ts)?;
    post_loop(c, f, x, r)
}

/// `Math.postLoop`.
pub fn post_loop<'a>(c: Ctx, f: usize, x: Json, ts: &'a [Tok]) -> P<'a, Json> {
    let mut x = x;
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        match ts {
            [Tok::Kw(Kw::Us), r @ ..] => match (c.sf, r) {
                (Sf::Latex, [Tok::Kw(Kw::Lb), r1 @ ..]) => match p_list(c, f, 1, r1) {
                    Some((is, [Tok::Kw(Kw::Rb), r2 @ ..])) => {
                        if is.is_empty() {
                            return None;
                        }
                        let mut args = vec![x];
                        args.extend(is);
                        x = node("index", args);
                        ts = r2;
                    }
                    _ => return None,
                },
                (Sf::Typst, [Tok::Kw(Kw::Lpg), r1 @ ..]) => match p_list(c, f, 1, r1) {
                    Some((is, [t, r2 @ ..])) if is_rp(t) && !is.is_empty() => {
                        let mut args = vec![x];
                        args.extend(is);
                        x = node("index", args);
                        ts = r2;
                    }
                    _ => return None,
                },
                (Sf::Typst, [t, r1 @ ..]) if simple_tok(t) => {
                    match p_prim(c, f, std::slice::from_ref(t)) {
                        Some((i, [])) => {
                            x = node("index", vec![x, i]);
                            ts = r1;
                        }
                        _ => return None,
                    }
                }
                _ => return None,
            },
            [Tok::Kw(Kw::Lbk), r @ ..] => match p_list(c, f, 1, r) {
                Some((is, [Tok::Kw(Kw::Rbk), r2 @ ..])) => {
                    if is.is_empty() {
                        return None;
                    }
                    let mut args = vec![x];
                    args.extend(is);
                    x = node("index", args);
                    ts = r2;
                }
                _ => return None,
            },
            _ => return Some((x, ts)),
        }
    }
}

/// `Math.pList`: a comma-separated list of expressions at level `L` (1 or 4),
/// possibly empty when the next token closes it.
pub fn p_list<'a>(c: Ctx, f: usize, l: usize, ts: &'a [Tok]) -> P<'a, Vec<Json>> {
    let f = f.checked_sub(1)?;
    match ts {
        [t, ..] => {
            if is_rp(t) || matches!(t, Tok::Kw(Kw::Rb | Kw::Rbk)) {
                Some((vec![], ts))
            } else {
                p_items(c, f, l, ts)
            }
        }
        [] => Some((vec![], ts)),
    }
}

/// `Math.pItems`.
pub fn p_items<'a>(c: Ctx, f: usize, l: usize, ts: &'a [Tok]) -> P<'a, Vec<Json>> {
    let mut out = Vec::new();
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        match p_lv(c, f, l, ts)? {
            (x, [Tok::Kw(Kw::Comma), r @ ..]) => {
                out.push(x);
                ts = r;
            }
            (x, r) => {
                out.push(x);
                return Some((out, r));
            }
        }
    }
}

/// `Math.pLv`: parse at level 1 or level 4.
pub fn p_lv<'a>(c: Ctx, f: usize, l: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    if l == 4 {
        p_add(c, f, ts)
    } else {
        p_or(c, f, ts)
    }
}

/// `Math.pCallArgs`: call arguments at level 4: each positional, or
/// `name = value`.
pub fn p_call_args<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Vec<CallArg>> {
    let f = f.checked_sub(1)?;
    match ts {
        [Tok::Kw(Kw::Rp | Kw::Semi), ..] => Some((vec![], ts)),
        _ => p_call_items(c, f, ts),
    }
}

/// `Math.pCallItems`.
pub fn p_call_items<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Vec<CallArg>> {
    let mut out = Vec::new();
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        match p_add(c, f, ts)? {
            (Json::Str(k), [Tok::Kw(Kw::Eq), r @ ..]) => match p_add(c, f, r)? {
                (v, [Tok::Kw(Kw::Comma), r2 @ ..]) => {
                    out.push(CallArg::Named(k, v));
                    ts = r2;
                }
                (v, r2) => {
                    out.push(CallArg::Named(k, v));
                    return Some((out, r2));
                }
            },
            (x, [Tok::Kw(Kw::Comma), r @ ..]) => {
                out.push(CallArg::Pos(x));
                ts = r;
            }
            (x, r) => {
                out.push(CallArg::Pos(x));
                return Some((out, r));
            }
        }
    }
}

/// `Math.pFields`: open-operator fields after `;`.
pub fn p_fields<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Vec<(String, Json)>> {
    let mut out = Vec::new();
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        let (k, r) = key_of(c, ts)?;
        match p_val(c, f, r)? {
            (v, [Tok::Kw(Kw::Comma), r2 @ ..]) => {
                out.push((k, v));
                ts = r2;
            }
            (v, r2) => {
                out.push((k, v));
                return Some((out, r2));
            }
        }
    }
}

/// `Math.pVal`: a field value: JSON (LaTeX JSON tokens, Typst `#value`) or an
/// expression.
pub fn p_val<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    match c.sf {
        Sf::Typst => match ts {
            [Tok::Code(v), r @ ..] => Some((v.clone(), r)),
            _ => p_add(c, f, ts),
        },
        Sf::Latex => {
            if json_start(ts) {
                p_json(f, ts)
            } else {
                p_add(c, f, ts)
            }
        }
    }
}

fn nodup_keys(xs: &[(String, Json)]) -> bool {
    xs.iter()
        .enumerate()
        .all(|(i, x)| !xs[..i].iter().any(|y| y.0 == x.0))
}

/// `Math.pOpn`: `\operatorname{n}(…)`; a bare `\operatorname{n}` (not
/// followed by `(` or `_`) is a template applied with no bindings, unless a
/// template of that name is in scope with no parameters.
pub fn p_opn<'a>(c: Ctx, f: usize, n: &str, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    // the printer writes a template known to take no parameters as `n()`
    let bare = || {
        (tname_ok(n) && tparams(c.s, n).is_none_or(|ps| !ps.is_empty()))
            .then(|| (t_node(n, vec![]), ts))
    };
    let [t0, r @ ..] = ts else {
        return bare();
    };
    if is_lp(t0) {
        match p_call_args(c, f, r) {
            Some((args, [Tok::Kw(Kw::Rp), r2 @ ..])) => {
                if is_call_op(n) {
                    all_pos(&args).map(|vs| (node(n, vs), r2))
                } else if n == "neg" {
                    match all_pos(&args).as_deref() {
                        Some([x]) => Some((node("-", vec![x.clone()]), r2)),
                        _ => None,
                    }
                } else if n == "pow" {
                    match all_pos(&args).as_deref() {
                        Some([x, y]) => Some((node("^", vec![x.clone(), y.clone()]), r2)),
                        _ => None,
                    }
                } else if REMOVED_OPS.contains(&n) || n == "D" {
                    None
                } else {
                    match (tparams(c.s, n), all_pos(&args), all_named(&args)) {
                        (Some(ps), Some(vs), _) => {
                            if ps.len() == vs.len() {
                                Some((t_node(n, sort_kv(ps.iter().cloned().zip(vs).collect())), r2))
                            } else {
                                None
                            }
                        }
                        (_, _, Some(bs)) if !bs.is_empty() => {
                            if nodup_keys(&bs) {
                                Some((t_node(n, sort_kv(bs)), r2))
                            } else {
                                None
                            }
                        }
                        (None, Some(vs), _) => Some((mk_node(n, vs, vec![]), r2)),
                        _ => None,
                    }
                }
            }
            Some((args, [Tok::Kw(Kw::Semi), r1 @ ..])) => {
                if REMOVED_OPS.contains(&n)
                    || (is_notation_core(n) && !FIELD_CALL_OPS.contains(&n))
                    || tparams(c.s, n).is_some()
                {
                    None
                } else {
                    match (all_pos(&args), p_fields(c, f, r1)) {
                        (Some(vs), Some((fs, [Tok::Kw(Kw::Rp), r2 @ ..]))) => {
                            // only what the printer writes in this form: distinct
                            // keys, none of them `op` or `args`
                            if !nodup_keys(&fs)
                                || fs.iter().any(|kv| kv.0 == "op" || kv.0 == "args")
                            {
                                return None;
                            }
                            let e = mk_node(n, vs, fs.clone());
                            match &e {
                                Json::Obj(kvs) if prints_as_call(c, n, &fs, kvs) => Some((e, r2)),
                                _ => None,
                            }
                        }
                        _ => None,
                    }
                }
            }
            _ => None,
        }
    } else if matches!(t0, Tok::Kw(Kw::Us)) {
        if n == "D" { p_d_call(c, f, r) } else { None }
    } else {
        bare()
    }
}

/// `Math.pDCall`: `\operatorname{D}_{x}(u, a, b)` after the `_`.
pub fn p_d_call<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    let w = match (c.sf, ts) {
        (Sf::Latex, [Tok::Kw(Kw::Lb), r1 @ ..]) => match p_name(c.sf, r1) {
            Some((w, [Tok::Kw(Kw::Rb), r2 @ ..])) => Some((w, r2)),
            _ => None,
        },
        (Sf::Typst, [Tok::Kw(Kw::Lpg), r1 @ ..]) => match p_name(c.sf, r1) {
            Some((w, [Tok::Kw(Kw::Rp), r2 @ ..])) => Some((w, r2)),
            _ => None,
        },
        _ => None,
    };
    match w {
        Some((w, [t3, r3 @ ..])) => {
            if is_lp(t3) {
                match p_call_args(c, f, r3) {
                    Some((args, [Tok::Kw(Kw::Rp), r4 @ ..])) => {
                        all_pos(&args).map(|xs| (d_call_node(&w, xs), r4))
                    }
                    _ => None,
                }
            } else {
                None
            }
        }
        _ => None,
    }
}

/// Record a removed operator written in the call or escape form at the front
/// of `ts`, so a refusal can name it (CONFORMANCE §7.1). Not in Lean, whose
/// reader refuses every bad input alike.
fn note_removed_op(ts: &[Tok]) {
    let name = match ts {
        [Tok::Opn(n), ..] | [Tok::Esc(n), ..] => n,
        [Tok::Kw(Kw::Esmnode), _, Tok::Txt(n), ..] => n,
        _ => return,
    };
    if let Some(op) = REMOVED_OPS.iter().find(|o| **o == name.as_str()) {
        limits::removed_op(op);
    }
}

fn op_allowed(o: &str) -> bool {
    op_ok(o) && !REMOVED_OPS.contains(&o) && !is_deprecated_op(o)
}

/// `Math.pPrim`: a primary. Where it starts and, when it reads one, where it
/// ends are recorded ([`limits::reached`]), so a refused text can say how far
/// the parser got.
pub fn p_prim<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    limits::reached(ts);
    let out = prim(c, f, ts);
    if let Some((_, r)) = &out {
        limits::reached(r);
    }
    out
}

/// The body of [`p_prim`].
fn prim<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    note_removed_op(ts);
    let paren_close = |r: &'a [Tok]| -> P<'a, Json> {
        match p_or(c, f, r) {
            Some((x, [t, r2 @ ..])) => {
                if is_rp(t) {
                    Some((x, r2))
                } else {
                    None
                }
            }
            _ => None,
        }
    };
    let closed = |r: &'a [Tok], k: Kw, o: &str| -> P<'a, Json> {
        match p_or(c, f, r) {
            Some((x, [Tok::Kw(k2), r2 @ ..])) if *k2 == k => Some((node(o, vec![x]), r2)),
            _ => None,
        }
    };
    match ts {
        [Tok::Num(n), r @ ..] => match r {
            [Tok::Units(l), r2 @ ..] => Some((qty(n, l), r2)),
            _ => Some((Json::Num(n.clone()), r)),
        },
        [Tok::Kw(Kw::Bmat), r @ ..] => {
            let (rows, r2) = p_grid(Kw::Amp, Kw::Nl, Kw::Emat, r)?;
            if rows.iter().any(|q| q.len() > BMAT_MAX_COLS) {
                return None;
            }
            const_tail(grid_json(rows), r2)
        }
        [Tok::Kw(Kw::Lbkg), Tok::Carr(n), r @ ..] => match p_grid(Kw::Amp, Kw::Nl, Kw::Earr, r)? {
            (rows, [Tok::Kw(Kw::Rbkg), r2 @ ..])
                if *n > BMAT_MAX_COLS && rows.iter().all(|q| q.len() == *n) =>
            {
                const_tail(grid_json(rows), r2)
            }
            _ => None,
        },
        [Tok::Kw(Kw::Vec), t, r @ ..] => {
            if is_lp(t) {
                match p_cells(Kw::Comma, r) {
                    Some((ns, [Tok::Kw(Kw::Rp), r2 @ ..])) => {
                        const_tail(Json::Arr(ns.into_iter().map(Json::Num).collect()), r2)
                    }
                    _ => None,
                }
            } else {
                None
            }
        }
        [
            Tok::Kw(Kw::Mat),
            Tok::Kw(Kw::Lp),
            Tok::Word(dk),
            Tok::Kw(Kw::Colon),
            Tok::Txt(d),
            Tok::Kw(Kw::Comma),
            Tok::Word(ak),
            Tok::Kw(Kw::Colon),
            Tok::Code(Json::Num(JNum::Int(1))),
            Tok::Kw(Kw::Comma),
            r @ ..,
        ] if dk == "delim" && ak == "augment" && d == "[" => {
            let (rows, r2) = p_mk_rows(c, f, Kw::Comma, Kw::Semi, Kw::Rp, r)?;
            mk_tail(c.sf, rows, r2)
        }
        [Tok::Kw(Kw::Mat), t, r @ ..] => {
            if is_lp(t) {
                let (rows, r2) = p_grid(Kw::Comma, Kw::Semi, Kw::Rp, r)?;
                const_tail(
                    Json::Arr(
                        rows.into_iter()
                            .map(|q| Json::Arr(q.into_iter().map(Json::Num).collect()))
                            .collect(),
                    ),
                    r2,
                )
            } else {
                None
            }
        }
        [Tok::Txt(s), r @ ..] if s == "true" => Some((node("true", vec![]), r)),
        [Tok::Txt(s), r @ ..] if s == "false" => Some((node("false", vec![]), r)),
        [Tok::Kw(Kw::Lpg | Kw::Lp), r @ ..] => match (c.sf, r) {
            (Sf::Typst, [Tok::Kw(Kw::Dif), r1 @ ..]) => p_dt(c, f, Kw::Dif, r1),
            (Sf::Typst, [Tok::Kw(Kw::Pdiff), r1 @ ..]) => p_dt(c, f, Kw::Pdiff, r1),
            (Sf::Typst, [Tok::Letter('d'), ..]) => match p_italic_d(c, r) {
                Some(p) => Some(p),
                None => paren_close(r),
            },
            _ => paren_close(r),
        },
        [Tok::Kw(Kw::Lbk), r @ ..] => match p_or(c, f, r) {
            Some((x, [Tok::Kw(Kw::Rbk), r2 @ ..])) => Some((x, r2)),
            _ => None,
        },
        [Tok::Kw(Kw::Frac), Tok::Kw(Kw::Lb), r @ ..] => p_frac_l(c, f, r),
        [Tok::Kw(Kw::Sqrt), r @ ..] => match (c.sf, r) {
            (Sf::Latex, [Tok::Kw(Kw::Lb), r1 @ ..]) => closed(r1, Kw::Rb, "sqrt"),
            (Sf::Typst, [t, r1 @ ..]) => {
                if is_lp(t) {
                    p_fn1(c, f, "sqrt", r1)
                } else {
                    None
                }
            }
            _ => None,
        },
        [Tok::Kw(Kw::Log), Tok::Kw(Kw::Us), r @ ..] => match (c.sf, r) {
            (
                Sf::Latex,
                [
                    Tok::Kw(Kw::Lb),
                    Tok::Num(JNum::Int(10)),
                    Tok::Kw(Kw::Rb),
                    t,
                    r1 @ ..,
                ],
            ) => {
                if is_lp(t) {
                    p_fn1(c, f, "log10", r1)
                } else {
                    None
                }
            }
            (Sf::Typst, [Tok::Num(JNum::Int(10)), t, r1 @ ..]) => {
                if is_lp(t) {
                    p_fn1(c, f, "log10", r1)
                } else {
                    None
                }
            }
            _ => None,
        },
        [Tok::Kw(Kw::Labs), r @ ..] => closed(r, Kw::Rabs, "abs"),
        [Tok::Kw(Kw::Lfloor), r @ ..] => closed(r, Kw::Rfloor, "floor"),
        [Tok::Kw(Kw::Lceil), r @ ..] => closed(r, Kw::Rceil, "ceil"),
        [Tok::Kw(k @ (Kw::Min | Kw::Max)), t, r @ ..] => {
            if matches!(t, Tok::Kw(Kw::Lp)) {
                match p_list(c, f, 1, r) {
                    Some((xs, [Tok::Kw(Kw::Rp), r2 @ ..])) => {
                        if 2 <= xs.len() {
                            let o = if *k == Kw::Min { "min" } else { "max" };
                            Some((node(o, xs), r2))
                        } else {
                            None
                        }
                    }
                    _ => None,
                }
            } else {
                p_red(c, f, ts)
            }
        }
        [Tok::Kw(Kw::Lbkg), Tok::Kw(Kw::Barr), r @ ..] => {
            match p_mk_rows(c, f, Kw::Amp, Kw::Nl, Kw::Earr, r) {
                Some((rows, [Tok::Kw(Kw::Rbkg), r2 @ ..])) => mk_tail(c.sf, rows, r2),
                _ => None,
            }
        }
        [Tok::Kw(Kw::Sum | Kw::Prod | Kw::Limits | Kw::Lbkg), ..] => p_red(c, f, ts),
        [Tok::Kw(Kw::Lr), Tok::Kw(Kw::Lp), Tok::Kw(Kw::Lbk), ..] => p_red(c, f, ts),
        [Tok::Opn(n), r @ ..] => p_opn(c, f, n, r),
        [Tok::Kw(Kw::Bcases), r @ ..] => p_cases(c, f, r),
        [Tok::Kw(Kw::Cases), t, r @ ..] => {
            if is_lp(t) {
                p_cases(c, f, r)
            } else {
                None
            }
        }
        [Tok::Esc(o), Tok::Kw(Kw::Lb), r @ ..] => match p_json(f, r) {
            Some((Json::Obj(fs), [Tok::Kw(Kw::Rb), Tok::Kw(Kw::Lb), r1 @ ..])) => {
                match p_list(c, f, 1, r1) {
                    Some((args, [Tok::Kw(Kw::Rb), r2 @ ..])) => {
                        if op_allowed(o) {
                            Some((mk_node(o, args, fs), r2))
                        } else {
                            None
                        }
                    }
                    _ => None,
                }
            }
            _ => None,
        },
        [
            Tok::Kw(Kw::Esmnode),
            t,
            Tok::Txt(o),
            Tok::Kw(Kw::Comma),
            Tok::Code(Json::Obj(fs)),
            r @ ..,
        ] => {
            if is_lp(t) {
                let (args, r2) = p_esc_args(c, f, r)?;
                if op_allowed(o) {
                    Some((mk_node(o, args, fs.clone()), r2))
                } else {
                    None
                }
            } else {
                None
            }
        }
        [Tok::Kw(Kw::Dotacc), Tok::Kw(Kw::Lb), r @ ..] => match p_or(c, f, r) {
            Some((x, [Tok::Kw(Kw::Rb), r2 @ ..])) => Some((d_node(x, "t"), r2)),
            _ => None,
        },
        [Tok::Kw(Kw::Cdot), Tok::Kw(Kw::Lp), r @ ..] => match p_or(c, f, r) {
            Some((x, [Tok::Kw(Kw::Rp), r2 @ ..])) => Some((d_node(x, "t"), r2)),
            _ => None,
        },
        [Tok::Kw(k), t, r @ ..] => {
            if is_lp(t) {
                match (k, fn_of(*k)) {
                    (Kw::Log, _) => p_fn1(c, f, "log", r),
                    (Kw::Abs, _) => p_fn1(c, f, "abs", r),
                    (Kw::Floor, _) => p_fn1(c, f, "floor", r),
                    (Kw::Ceil, _) => p_fn1(c, f, "ceil", r),
                    (_, Some(o)) => p_fn1(c, f, o, r),
                    (_, None) => None,
                }
            } else {
                None
            }
        }
        [Tok::Word(w), r @ ..] => p_word(c, w, r),
        _ => {
            if euler_head(c, ts) {
                p_euler_exp(c, f, &ts[2..])
            } else {
                p_name_prim(c, ts)
            }
        }
    }
}

/// `Math.pEulerExp`: `\exp` written as a power of e.
pub fn p_euler_exp<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    let (y, r) = p_expo(c, f, ts)?;
    Some((node("exp", vec![y]), r))
}

/// `Math.pRange`: a range row: `k \in S`, `k \in S(i, j)`, `a \le k \le b`.
pub fn p_range<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Row> {
    let f = f.checked_sub(1)?;
    match p_add(c, f, ts) {
        Some((Json::Str(k), [Tok::Kw(Kw::Inn), r @ ..])) => match p_name(c.sf, r) {
            Some((s, [Tok::Kw(Kw::Lp), r2 @ ..])) => match p_names(c.sf, r2) {
                Some((ps, [Tok::Kw(Kw::Rp), r3 @ ..])) => Some((
                    Row::Rng(
                        k,
                        Json::Obj(vec![
                            ("from".into(), Json::Str(s)),
                            (
                                "of".into(),
                                Json::Arr(ps.into_iter().map(Json::Str).collect()),
                            ),
                        ]),
                    ),
                    r3,
                )),
                _ => None,
            },
            Some((s, r2)) => Some((
                Row::Rng(k, Json::Obj(vec![("from".into(), Json::Str(s))])),
                r2,
            )),
            None => None,
        },
        Some((a, [Tok::Kw(Kw::Le), r @ ..])) => match p_add(c, f, r) {
            Some((Json::Str(k), [Tok::Kw(Kw::Le), r2 @ ..])) => {
                let (b, r3) = p_add(c, f, r2)?;
                Some((Row::Rng(k, Json::Arr(vec![a, b])), r3))
            }
            _ => None,
        },
        _ => None,
    }
}

/// `Math.pRow`: a row ending at a token `is_end` accepts: an expression read
/// whole first, else a range.
pub fn p_row<'a>(c: Ctx, f: usize, is_end: &dyn Fn(&Tok) -> bool, ts: &'a [Tok]) -> P<'a, Row> {
    let f = f.checked_sub(1)?;
    match p_or(c, f, ts) {
        Some((x, r @ [t, ..])) => {
            if is_end(t) {
                Some((Row::Filt(x), r))
            } else {
                p_range(c, f, ts)
            }
        }
        _ => p_range(c, f, ts),
    }
}

/// `Math.pRows`: rows separated by `sep`, up to `close` (consumed).
pub fn p_rows<'a>(c: Ctx, f: usize, sep: Kw, close: Kw, ts: &'a [Tok]) -> P<'a, Vec<Row>> {
    let mut out = Vec::new();
    let mut f = f;
    let mut ts = ts;
    let is_end = |t: &Tok| is_kw(sep, t) || is_kw(close, t);
    loop {
        f = f.checked_sub(1)?;
        match p_row(c, f, &is_end, ts) {
            Some((row, [Tok::Kw(k), r @ ..])) => {
                out.push(row);
                if *k == sep {
                    ts = r;
                } else if *k == close {
                    return Some((out, r));
                } else {
                    return None;
                }
            }
            _ => return None,
        }
    }
}

/// `Math.pRedBody`: a reduction after its operator: the subscript rows, then
/// the body.
pub fn p_red_body<'a>(c: Ctx, f: usize, red: RedK, marked: bool, ts: &'a [Tok]) -> P<'a, FaqForm> {
    let f = f.checked_sub(1)?;
    let rows: P<'a, Vec<Row>> = match c.sf {
        Sf::Latex => match ts {
            [
                Tok::Kw(Kw::Us),
                Tok::Kw(Kw::Lb),
                Tok::Kw(Kw::Substack),
                Tok::Kw(Kw::Lb),
                r @ ..,
            ] => match p_rows(c, f, Kw::Nl, Kw::Rb, r) {
                Some((rs, [Tok::Kw(Kw::Rb), r2 @ ..])) => Some((rs, r2)),
                _ => None,
            },
            [Tok::Kw(Kw::Us), Tok::Kw(Kw::Lb), r @ ..] => {
                match p_row(c, f, &|t| is_kw(Kw::Rb, t), r) {
                    Some((
                        Row::Filt(x),
                        [
                            Tok::Kw(Kw::Rb),
                            Tok::Kw(Kw::Caret),
                            Tok::Kw(Kw::Lb),
                            r2 @ ..,
                        ],
                    )) if lone_eq(&x).is_some() => {
                        let (k, a) = lone_eq(&x).unwrap();
                        match r2 {
                            // a superscript set follows: the row is the filter
                            [Tok::Kw(Kw::Lset), ..] => {
                                let back = &ts[ts.len() - r2.len() - 2..];
                                Some((vec![Row::Filt(x)], back))
                            }
                            _ => match p_or(c, f, r2) {
                                Some((b, [Tok::Kw(Kw::Rb), r3 @ ..])) => {
                                    Some((vec![Row::Rng(k, Json::Arr(vec![a, b]))], r3))
                                }
                                _ => None,
                            },
                        }
                    }
                    Some((row, [Tok::Kw(Kw::Rb), r2 @ ..])) => Some((vec![row], r2)),
                    _ => None,
                }
            }
            _ => Some((vec![], ts)),
        },
        Sf::Typst => match ts {
            [Tok::Kw(Kw::Us), Tok::Kw(Kw::Lpg), r @ ..] => p_rows(c, f, Kw::Nl, Kw::Rp, r),
            _ => Some((vec![], ts)),
        },
    };
    let (rs, r) = rows?;
    let (rg, fl) = row_parts(rs)?;
    let (st, r1) = p_sup(c.sf, r)?;
    // a marked head's `args` are the body's arrays: no set is written with it
    if marked && !st.is_empty() {
        return None;
    }
    let (body, r2) = p_mul(c, f, r1)?;
    Some((
        FaqForm {
            red,
            marked,
            out: vec![],
            ranges: rg,
            expr: body,
            filter: fl,
            set: st,
        },
        r2,
    ))
}

/// The `.obj [("args", .arr [.str k, a]), ("op", .str "==")]` pattern of
/// `pRedBody`.
fn lone_eq(x: &Json) -> Option<(String, Json)> {
    match x {
        Json::Obj(kvs) => match kvs.as_slice() {
            [(ka, Json::Arr(xs)), (ko, Json::Str(o))]
                if ka == "args" && ko == "op" && o == "==" =>
            {
                match xs.as_slice() {
                    [Json::Str(k), a] => Some((k.clone(), a.clone())),
                    _ => None,
                }
            }
            _ => None,
        },
        _ => None,
    }
}

/// `Math.pRed`: a rank-0 reduction, or a reduction wrapped with its output
/// entries.
pub fn p_red<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    let wrapped = |r: &'a [Tok], tail: &[Tok], sub: &[Tok], close: Kw| -> P<'a, Json> {
        let (red, marked, r1) = p_red_head(c.sf, r)?;
        let (form, r2) = p_red_body(c, f, red, marked, r1)?;
        // the set of an output form is written on its bracket only
        if !form.set.is_empty() {
            return None;
        }
        let (st, r3) = p_sup(c.sf, r2.strip_prefix(tail)?)?;
        if marked && !st.is_empty() {
            return None;
        }
        let (es, r4) = p_rows(c, f, Kw::Comma, close, r3.strip_prefix(sub)?)?;
        entry_parts(es).map(|(outs, ors)| (faq_json(&with_sup(with_out(form, outs, ors), st)), r4))
    };
    match ts {
        [Tok::Kw(Kw::Lbkg), r @ ..] => wrapped(
            r,
            &[Tok::Kw(Kw::Rbkg)],
            &[Tok::Kw(Kw::Us), Tok::Kw(Kw::Lb)],
            Kw::Rb,
        ),
        [Tok::Kw(Kw::Lr), Tok::Kw(Kw::Lp), Tok::Kw(Kw::Lbk), r @ ..] => wrapped(
            r,
            &[Tok::Kw(Kw::Rbk), Tok::Kw(Kw::Rp)],
            &[Tok::Kw(Kw::Us), Tok::Kw(Kw::Lpg)],
            Kw::Rp,
        ),
        _ => {
            let (red, marked, r1) = p_red_head(c.sf, ts)?;
            p_red_body(c, f, red, marked, r1).map(|(form, r)| (faq_json(&form), r))
        }
    }
}

/// `Math.pFn1`: `f(x)` after the opening parenthesis.
pub fn p_fn1<'a>(c: Ctx, f: usize, o: &str, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    match p_or(c, f, ts) {
        Some((x, [Tok::Kw(Kw::Rp), r @ ..])) => Some((node(o, vec![x]), r)),
        _ => None,
    }
}

fn is_rm(t: &Tok, s: &str) -> bool {
    matches!(t, Tok::Rm(r) if r == s)
}

/// `Math.pFracL`: after `\frac{`: a time or spatial derivative, the italic-d
/// variant, or a quotient.
pub fn p_frac_l<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    match ts {
        [
            d1,
            Tok::Kw(Kw::Rb),
            Tok::Kw(Kw::Lb),
            d2,
            Tok::Letter('t'),
            Tok::Kw(Kw::Rb),
            r @ ..,
        ] if is_rm(d1, "d") && is_rm(d2, "d") => p_d_apply(c, f, "t", r),
        [d1, r @ ..] if is_rm(d1, "d") => match p_or(c, f, r) {
            Some((
                x,
                [
                    Tok::Kw(Kw::Rb),
                    Tok::Kw(Kw::Lb),
                    d2,
                    Tok::Letter('t'),
                    Tok::Kw(Kw::Rb),
                    r2 @ ..,
                ],
            )) if is_rm(d2, "d") => Some((d_node(x, "t"), r2)),
            _ => None,
        },
        [
            Tok::Kw(Kw::Pdiff),
            Tok::Kw(Kw::Rb),
            Tok::Kw(Kw::Lb),
            Tok::Kw(Kw::Pdiff),
            r @ ..,
        ] => match p_name(c.sf, r) {
            Some((w, [Tok::Kw(Kw::Rb), r2 @ ..])) => p_d_apply(c, f, &w, r2),
            _ => None,
        },
        [Tok::Kw(Kw::Pdiff), r @ ..] => match p_or(c, f, r) {
            Some((
                x,
                [
                    Tok::Kw(Kw::Rb),
                    Tok::Kw(Kw::Lb),
                    Tok::Kw(Kw::Pdiff),
                    r1 @ ..,
                ],
            )) => match p_name(c.sf, r1) {
                Some((w, [Tok::Kw(Kw::Rb), r2 @ ..])) => Some((d_node(x, &w), r2)),
                _ => None,
            },
            _ => None,
        },
        _ => match p_italic_d(c, ts) {
            Some(p) => Some(p),
            None => match p_or(c, f, ts) {
                Some((x, [Tok::Kw(Kw::Rb), Tok::Kw(Kw::Lb), r1 @ ..])) => match p_or(c, f, r1) {
                    Some((y, [Tok::Kw(Kw::Rb), r2 @ ..])) => Some((node("/", vec![x, y]), r2)),
                    _ => None,
                },
                _ => None,
            },
        },
    }
}

/// `Math.pDT`: `(dif N)/(dif t)` and `(partial u)/(partial x)` after the first
/// `(dif` / `(partial`.
pub fn p_dt<'a>(c: Ctx, f: usize, k: Kw, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    match ts {
        [
            Tok::Kw(Kw::Rp),
            Tok::Kw(Kw::Slash),
            Tok::Kw(Kw::Lpg),
            Tok::Kw(k2),
            r @ ..,
        ] => {
            if *k2 == k {
                match p_name(c.sf, r) {
                    Some((w, [Tok::Kw(Kw::Rp), r2 @ ..])) => {
                        if k == Kw::Dif && w != "t" {
                            None
                        } else {
                            p_d_apply(c, f, &w, r2)
                        }
                    }
                    _ => None,
                }
            } else {
                None
            }
        }
        _ => match p_or(c, f, ts) {
            Some((
                x,
                [
                    Tok::Kw(Kw::Rp),
                    Tok::Kw(Kw::Slash),
                    Tok::Kw(Kw::Lpg),
                    Tok::Kw(k2),
                    r1 @ ..,
                ],
            )) => {
                if *k2 == k {
                    match p_name(c.sf, r1) {
                        Some((w, [Tok::Kw(Kw::Rp), r2 @ ..])) => {
                            if k == Kw::Dif && w != "t" {
                                None
                            } else {
                                Some((d_node(x, &w), r2))
                            }
                        }
                        _ => None,
                    }
                } else {
                    None
                }
            }
            _ => None,
        },
    }
}

/// `Math.pDApply`: a derivative operator applied to a parenthesized operand.
pub fn p_d_apply<'a>(c: Ctx, f: usize, w: &str, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    match ts {
        [Tok::Kw(Kw::Lpg), r @ ..] => match p_or(c, f, r) {
            Some((x, [t, r2 @ ..])) => {
                if is_rp(t) {
                    Some((d_node(x, w), r2))
                } else {
                    None
                }
            }
            _ => None,
        },
        _ => None,
    }
}

/// `Math.pCases`: `cases` rows; a chain re-nests to the right.
pub fn p_cases<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Json> {
    let f = f.checked_sub(1)?;
    let _nest = Nest::enter()?;
    match p_or(c, f, ts) {
        Some((v, [Tok::Kw(Kw::Amp), Tok::Txt(t), r @ ..])) if t == "otherwise" => match (c.sf, r) {
            (Sf::Latex, [Tok::Kw(Kw::Ecases), r2 @ ..]) => Some((v, r2)),
            (Sf::Typst, [Tok::Kw(Kw::Rp), r2 @ ..]) => Some((v, r2)),
            _ => None,
        },
        Some((v, [Tok::Kw(Kw::Amp), Tok::Txt(t), r @ ..])) if t == "if " => match p_or(c, f, r) {
            Some((cnd, [Tok::Kw(k), r2 @ ..])) => {
                let brk = if c.sf == Sf::Latex { Kw::Nl } else { Kw::Comma };
                if *k == brk {
                    p_cases(c, f, r2).map(|(e, r3)| (node("ifelse", vec![cnd, v, e]), r3))
                } else {
                    None
                }
            }
            _ => None,
        },
        _ => None,
    }
}

/// `Math.pPair`: a bound pair after its `[`: `a, b]`.
pub fn p_pair<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, (Json, Json)> {
    let f = f.checked_sub(1)?;
    match p_or(c, f, ts)? {
        (a, [Tok::Kw(Kw::Comma), r @ ..]) => match p_or(c, f, r)? {
            (b, [Tok::Kw(Kw::Rbk), r2 @ ..]) => Some(((a, b), r2)),
            _ => None,
        },
        _ => None,
    }
}

/// `Math.pRegTail`: the further bound pairs of a region, each after
/// `\times [`.
pub fn p_reg_tail<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Vec<(Json, Json)>> {
    let mut out = Vec::new();
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        match ts {
            [Tok::Kw(Kw::Times), Tok::Kw(Kw::Lbk), r @ ..] => {
                let (p, r2) = p_pair(c, f, r)?;
                out.push(p);
                ts = r2;
            }
            _ => return Some((out, ts)),
        }
    }
}

/// `Math.pMkRows`: the rows of a `makearray` table: a value, the cell
/// separator `csep`, a region; rows separated by `rsep`, up to `close`
/// (consumed).
pub fn p_mk_rows<'a>(
    c: Ctx,
    f: usize,
    csep: Kw,
    rsep: Kw,
    close: Kw,
    ts: &'a [Tok],
) -> P<'a, Vec<MkRow>> {
    let mut out = Vec::new();
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        let (v, r) = match p_or(c, f, ts)? {
            (v, [Tok::Kw(k), Tok::Kw(Kw::Lbk), r @ ..]) if *k == csep => (v, r),
            _ => return None,
        };
        let (p, r1) = p_pair(c, f, r)?;
        let (ps, r2) = p_reg_tail(c, f, r1)?;
        let mut region = vec![p];
        region.extend(ps);
        out.push((v, region));
        match r2 {
            [Tok::Kw(k2), r3 @ ..] if *k2 == rsep => ts = r3,
            [Tok::Kw(k2), r3 @ ..] if *k2 == close => return Some((out, r3)),
            _ => return None,
        }
    }
}

/// `Math.pEscArgs`: Typst escape arguments: `, a` repeated, then `)`.
pub fn p_esc_args<'a>(c: Ctx, f: usize, ts: &'a [Tok]) -> P<'a, Vec<Json>> {
    let mut out = Vec::new();
    let mut f = f;
    let mut ts = ts;
    loop {
        f = f.checked_sub(1)?;
        match ts {
            [Tok::Kw(Kw::Rp), r @ ..] => return Some((out, r)),
            [Tok::Kw(Kw::Comma), r @ ..] => {
                let (x, r2) = p_or(c, f, r)?;
                out.push(x);
                ts = r2;
            }
            _ => return None,
        }
    }
}

/// `Math.need` (RoundTrip.lean): the fuel a token list of length `len` is read
/// with at level `L`.
pub fn need(l: usize, len: usize) -> usize {
    30 * len + (12usize.saturating_sub(l))
}

/// `Math.parseToks` (Induct.lean): read a whole token list.
pub fn parse_toks(sf: Sf, s: &super::expr::Sym, ts: &[Tok]) -> Option<Json> {
    match p_or(Ctx { sf, s }, need(1, ts.len()), ts) {
        Some((e, [])) => Some(e),
        Some((_, r)) => {
            limits::reached(r);
            None
        }
        None => None,
    }
}
