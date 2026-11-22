//! Tests of the math layer: the checks of `HandWritten.lean`, and the math of
//! every expression case of the document-format golden set.

use super::latex;
use super::parse::d_node;
use super::print::{key_toks, mk_node, node};
use super::token::Sf;
use super::*;
use crate::document::json::{self, JNum, Json};

fn sym(names: &[&str]) -> Sym {
    Sym {
        names: names.iter().map(|s| s.to_string()).collect(),
        templates: vec![],
    }
}

fn int(z: i128) -> Json {
    Json::int(z)
}

fn s(x: &str) -> Json {
    Json::str(x)
}

// ## HandWritten.lean

fn hw() -> Sym {
    sym(&["x", "k", "a", "T", "n", "N"])
}

#[track_caller]
fn reads_l(sy: &Sym, text: &str, e: Json) {
    assert_eq!(parse_latex(sy, text), Some(e), "LaTeX {text:?}");
}

#[track_caller]
fn reads_t(sy: &Sym, text: &str, e: Json) {
    assert_eq!(parse_typst(sy, text), Some(e), "Typst {text:?}");
}

#[test]
fn hand_written_minus_and_negative_literals() {
    let sy = hw();
    let (x, k, a) = (s("x"), s("k"), s("a"));
    let xm1 = node("-", vec![x.clone(), int(1)]);
    reads_l(&sy, "x-1", xm1.clone());
    reads_l(&sy, "x - 1", xm1.clone());
    reads_l(&sy, "x -1", xm1.clone());
    reads_l(&sy, "-1", int(-1));
    reads_l(&sy, "2-x", node("-", vec![int(2), x.clone()]));
    reads_l(
        &sy,
        "k-1-x",
        node("-", vec![node("-", vec![k.clone(), int(1)]), x.clone()]),
    );
    reads_l(&sy, "a \\cdot -1", node("*", vec![a.clone(), int(-1)]));
    reads_l(&sy, "a\\cdot-1", node("*", vec![a.clone(), int(-1)]));
    reads_l(&sy, "x^{-1}", node("^", vec![x.clone(), int(-1)]));
    reads_l(&sy, "x = -1", node("==", vec![x.clone(), int(-1)]));
    reads_l(
        &sy,
        "k-2x",
        node("-", vec![k.clone(), node("*", vec![int(2), x.clone()])]),
    );
    reads_l(&sy, "k-0", node("-", vec![k.clone(), int(0)]));

    reads_t(&sy, "x-1", xm1.clone());
    reads_t(&sy, "x - 1", xm1);
    reads_t(&sy, "-1", int(-1));
    reads_t(&sy, "2-x", node("-", vec![int(2), x.clone()]));
    reads_t(&sy, "a dot -1", node("*", vec![a, int(-1)]));
    reads_t(&sy, "x^(-1)", node("^", vec![x, int(-1)]));
}

#[test]
fn hand_written_scientific_literals() {
    let sy = hw();
    let th = int(2000);
    let tiny = Json::Num(JNum::Dec {
        neg: false,
        digits: vec![1, 5],
        e10: -12,
    });
    for t in [
        "2 \\times 10^{3}",
        "2\\times 10^{3}",
        "2\\times10^{3}",
        "2  \\times  10^{3}",
        "2 \\times 10 ^ { 3 }",
    ] {
        reads_l(&sy, t, th.clone());
    }
    reads_l(&sy, "1.5\\times 10^{-12}", tiny.clone());
    reads_l(&sy, "1.5 \\times 10^{-12}", tiny.clone());
    let p = node("*", vec![int(3), node("^", vec![int(10), s("n")])]);
    reads_l(&sy, "3 \\times 10^{n}", p.clone());
    for t in ["2 times 10^3", "2times 10^3", "2 times 10^( 3 )"] {
        reads_t(&sy, t, th.clone());
    }
    reads_t(&sy, "1.5 times 10^(-12)", tiny.clone());
    reads_t(&sy, "1.5times 10 ^ (-12)", tiny);
    reads_t(&sy, "3 times 10^n", p);
}

#[test]
fn hand_written_thin_space() {
    let sy = hw();
    let meters = Json::Obj(vec![
        ("args".into(), Json::Arr(vec![])),
        ("op".into(), s("const")),
        ("units".into(), s("m")),
        ("value".into(), int(3)),
    ]);
    reads_l(&sy, "3\\,\\mathrm{m}", meters.clone());
    reads_l(&sy, "3 \\, \\mathrm{m}", meters.clone());
    reads_l(&sy, "k\\,T", node("*", vec![s("k"), s("T")]));
    reads_l(&sy, "k \\, T", node("*", vec![s("k"), s("T")]));
    reads_t(&sy, "3 thin upright(\"m\")", meters);
}

#[test]
fn hand_written_italic_d() {
    let sd = sym(&["x"]);
    let sdx = sym(&["x", "dx", "dt"]);
    let sdx1 = sym(&["x", "dx"]);
    let dx = d_node(s("x"), "t");
    reads_l(&sd, "\\frac{dx}{dt}", dx.clone());
    reads_l(&sd, "\\frac{d x}{d t}", dx.clone());
    reads_t(&sd, "(d x)/(d t)", dx);
    let q = node("/", vec![s("dx"), s("dt")]);
    reads_l(&sdx, "\\frac{dx}{dt}", q.clone());
    reads_t(&sdx, "(dx)/(dt)", q);
    assert_eq!(parse_latex(&sdx1, "\\frac{dx}{dt}"), None);
}

#[test]
fn hand_written_field_keys() {
    let sy = hw();
    let r: String = latex::render(&key_toks(Sf::Latex, "a%b$"))
        .into_iter()
        .collect();
    assert_eq!(r, "\\mathrm{a{\\char037}b{\\char036}}");
    reads_l(
        &sy,
        "\\operatorname{foo}(x; \\mathrm{a{\\char037}b} = 1)",
        mk_node("foo", vec![s("x")], vec![("a%b".into(), int(1))]),
    );
    let odd = Json::Obj(vec![
        ("a%b$".into(), int(1)),
        ("args".into(), Json::Arr(vec![s("x")])),
        ("op".into(), s("foo")),
    ]);
    let p = print_latex(&sy, &odd);
    assert!(!p.contains('%') && !p.contains('$'), "{p}");
    reads_l(&sy, &p, odd);
}

#[test]
fn hand_written_json_strings() {
    let sy = hw();
    let str_op = mk_node("myop", vec![s("k")], vec![("s".into(), s("a{b}"))]);
    assert_eq!(
        print_latex(&sy, &str_op),
        "\\operatorname{myop}(k; \\mathrm{s} = \\text{\"a\\{b\\}\"})"
    );
    reads_l(&sy, &print_latex(&sy, &str_op), str_op.clone());
    let odd = mk_node(
        "myop",
        vec![s("k")],
        vec![("s".into(), s("x$%é\n\"_~\\ 中"))],
    );
    assert_eq!(
        print_latex(&sy, &odd),
        "\\operatorname{myop}(k; \\mathrm{s} = \\text{\"x{\\char036}{\\char037}{\\char233}{\\char010}\"\\_{\\char126}{\\char092} {\\char0020013}\"})"
    );
    reads_l(&sy, &print_latex(&sy, &odd), odd);
    reads_l(
        &sy,
        "\\operatorname{myop}(k; \\mathrm{s} = \"a\\u007Bb\\u007D\")",
        str_op,
    );
}

#[test]
fn hand_written_array_notation() {
    let sy = hw();
    let (x, k, a) = (s("x"), s("k"), s("a"));
    // A bare `\operatorname{n}` is a template applied with no bindings; with
    // `()` it is an open operator with no operands.
    let bare = super::parse::t_node("dlon", vec![]);
    reads_l(&sy, "\\operatorname{dlon}", bare.clone());
    reads_l(&sy, "\\operatorname{dlon}()", node("dlon", vec![]));
    reads_t(&sy, "op(\"dlon\")", bare);
    reads_t(&sy, "op(\"dlon\")()", node("dlon", vec![]));
    // `\times [` outside a region is still a product with a bracket group.
    let prod = node("*", vec![a.clone(), node("+", vec![x.clone(), int(1)])]);
    reads_l(&sy, "a \\times [x + 1]", prod.clone());
    reads_l(&sy, "a \\times[x + 1]", prod.clone());
    reads_t(&sy, "a times [x + 1]", prod);
    // A `makearray` table, the region product spaced any way.
    let table = print::mk_json(&print::MkForm {
        out: vec![],
        regions: vec![
            vec![(int(1), s("N"))],
            vec![(int(1), int(1)), (int(2), int(2))],
        ],
        values: vec![x.clone(), int(0)],
    });
    reads_l(
        &sy,
        "\\left[\\begin{array}{l|l} x & [1, N] \\\\ 0 & [1, 1]\\times[2, 2] \\end{array}\\right]",
        table.clone(),
    );
    reads_t(
        &sy,
        "mat(delim: \"[\", augment: #1, x, [1, N]; 0, [1, 1] times [2, 2])",
        table.clone(),
    );
    reads_l(&sy, &print_latex(&sy, &table), table.clone());
    reads_t(&sy, &print_typst(&sy, &table), table);
    // A lone equality filter followed by a superscript set is the filter, not
    // a dense range.
    let filt_set = Json::Obj(vec![
        ("args".into(), Json::Arr(vec![a])),
        ("expr".into(), x),
        ("filter".into(), node("==", vec![k, int(1)])),
        ("op".into(), s("faq")),
        ("output_idx".into(), Json::Arr(vec![])),
    ]);
    reads_l(&sy, "\\sum_{k = 1}^{\\{a\\}} x", filt_set.clone());
    reads_l(&sy, &print_latex(&sy, &filt_set), filt_set);
}

// ## The golden set

fn keys_of(v: Option<&serde_json::Value>) -> Vec<String> {
    match v {
        Some(serde_json::Value::Object(m)) => m.keys().cloned().collect(),
        _ => vec![],
    }
}

fn templates_of(v: Option<&serde_json::Value>) -> Vec<(String, Vec<String>)> {
    match v {
        Some(serde_json::Value::Object(m)) => m
            .iter()
            .filter_map(|(k, t)| {
                let t = t.as_object()?;
                let ps = match t.get("params") {
                    Some(serde_json::Value::Array(xs)) => xs
                        .iter()
                        .filter_map(|x| x.as_str().map(str::to_string))
                        .collect(),
                    _ => vec![],
                };
                Some((k.clone(), ps))
            })
            .collect(),
        _ => vec![],
    }
}

/// The symbol table of the one component of a fixture document and its one
/// equation, as `Source.symFor` and `Source.eqExpr` build them.
fn component(doc: &serde_json::Value) -> (Sym, Json) {
    let comps: Vec<&serde_json::Value> = ["models", "reaction_systems"]
        .iter()
        .filter_map(|k| doc.get(*k).and_then(|v| v.as_object()))
        .flat_map(|m| m.values())
        .collect();
    assert_eq!(comps.len(), 1);
    let c = comps[0];
    let mut names = keys_of(c.get("variables"));
    names.extend(keys_of(c.get("species")));
    names.extend(keys_of(c.get("parameters")));
    names.extend(keys_of(doc.get("index_sets")));
    let mut templates = templates_of(doc.get("operators"));
    templates.extend(templates_of(c.get("operators")));
    let eq = &c["equations"][0];
    let e = Json::Obj(vec![
        (
            "args".into(),
            Json::Arr(vec![
                json::from_serde(&eq["lhs"]),
                json::from_serde(&eq["rhs"]),
            ]),
        ),
        ("op".into(), Json::str("==")),
    ]);
    (Sym { names, templates }, e)
}

#[test]
fn golden_set_math() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/document_format");
    let mut failures = Vec::new();
    let mut n = 0;
    for file in ["operators", "names", "units"] {
        let text = std::fs::read_to_string(dir.join(format!("{file}.json"))).unwrap();
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        for case in v["cases"].as_array().unwrap() {
            let Some(math) = case.get("math") else {
                continue;
            };
            n += 1;
            let id = case["id"].as_str().unwrap();
            let (sy, e) = component(&case["esm"]);
            let lx = math["latex"].as_str().unwrap();
            let ty = math["typst"].as_str().unwrap();
            let pl = print_latex(&sy, &e);
            if pl != lx {
                failures.push(format!("{id}: print_latex\n  got  {pl}\n  want {lx}"));
            }
            if parse_latex(&sy, lx).as_ref() != Some(&e) {
                failures.push(format!(
                    "{id}: parse_latex {lx}\n  got {:?}",
                    parse_latex(&sy, lx).map(|j| json::render(&j))
                ));
            }
            let pt = print_typst(&sy, &e);
            if pt != ty {
                failures.push(format!("{id}: print_typst\n  got  {pt}\n  want {ty}"));
            }
            if parse_typst(&sy, ty).as_ref() != Some(&e) {
                failures.push(format!(
                    "{id}: parse_typst {ty}\n  got {:?}",
                    parse_typst(&sy, ty).map(|j| json::render(&j))
                ));
            }
        }
    }
    assert!(n >= 79, "only {n} math cases found");
    assert!(
        failures.is_empty(),
        "{} of {n} cases fail:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

// ## Review fixes of the array notation

#[track_caller]
fn refuses_l(sy: &Sym, text: &str) {
    assert_eq!(
        parse_latex(sy, text),
        None,
        "LaTeX {text:?} must be refused"
    );
}

#[track_caller]
fn refuses_t(sy: &Sym, text: &str) {
    assert_eq!(
        parse_typst(sy, text),
        None,
        "Typst {text:?} must be refused"
    );
}

#[track_caller]
fn round_trips(sy: &Sym, e: &Json) {
    reads_l(sy, &print_latex(sy, e), e.clone());
    reads_t(sy, &print_typst(sy, e), e.clone());
}

fn fsym() -> Sym {
    sym(&["a", "f", "g", "i", "k", "x", "N", "S"])
}

#[test]
fn marked_reduction_refuses_a_set() {
    let sy = fsym();
    // rank 0: the head's own set
    assert!(parse_latex(&sy, "\\sum\\limits_{1 \\le k \\le N} a_{k}").is_some());
    refuses_l(&sy, "\\sum\\limits_{1 \\le k \\le N}^{\\{f\\}} a_{k}");
    assert!(parse_typst(&sy, "limits(sum)_(1 <= k <= N) a_k").is_some());
    refuses_t(&sy, "limits(sum)_(1 <= k <= N)^({f}) a_k");
    // output form: the bracket's set
    let out_l = "\\left[\\sum\\limits_{1 \\le k \\le N} a_{k} x_{i}\\right]_{1 \\le i \\le N}";
    assert!(parse_latex(&sy, out_l).is_some());
    refuses_l(
        &sy,
        "\\left[\\sum\\limits_{1 \\le k \\le N} a_{k} x_{i}\\right]^{\\{f\\}}_{1 \\le i \\le N}",
    );
    let out_t = "lr([limits(sum)_(1 <= k <= N) a_k x_i])_(1 <= i <= N)";
    assert!(parse_typst(&sy, out_t).is_some());
    refuses_t(
        &sy,
        "lr([limits(sum)_(1 <= k <= N) a_k x_i])^({f})_(1 <= i <= N)",
    );
}

#[test]
fn output_form_set_only_on_the_bracket() {
    let sy = fsym();
    let canon_l =
        "\\left[\\sum\\left(f_{i + 1} - f_{i}\\right)\\right]^{\\{f, g\\}}_{2 \\le i \\le N - 1}";
    let e = parse_latex(&sy, canon_l).expect("canonical output form reads");
    assert_eq!(print_latex(&sy, &e), canon_l);
    round_trips(&sy, &e);
    // a set inside the bracket is refused, with or without one outside
    refuses_l(
        &sy,
        "\\left[\\sum^{\\{f, g\\}}\\left(f_{i + 1} - f_{i}\\right)\\right]_{2 \\le i \\le N - 1}",
    );
    refuses_l(
        &sy,
        "\\left[\\sum^{\\{a\\}}\\left(f_{i + 1} - f_{i}\\right)\\right]^{\\{f, g\\}}_{2 \\le i \\le N - 1}",
    );
    refuses_t(
        &sy,
        "lr([sum^({f, g}) (f_(i + 1) - f_i)])_(2 <= i <= N - 1)",
    );
    refuses_t(
        &sy,
        "lr([sum^({a}) (f_(i + 1) - f_i)])^({f, g})_(2 <= i <= N - 1)",
    );
    // rank 0 keeps its own set
    assert!(parse_latex(&sy, "\\sum^{\\{f\\}}_{1 \\le i \\le N} f_{i}").is_none());
    assert!(parse_latex(&sy, "\\sum_{1 \\le i \\le N}^{\\{a\\}} f_{i}").is_some());
}

#[test]
fn delim_and_augment_are_names_in_typst() {
    let sy = sym(&["x", "delim", "augment"]);
    reads_t(
        &sy,
        "x = delim + 1",
        node("==", vec![s("x"), node("+", vec![s("delim"), int(1)])]),
    );
    round_trips(&sy, &d_node(s("augment"), "t"));
    round_trips(&sy, &node("+", vec![s("delim"), int(1)]));
    let e = node("*", vec![s("delim"), s("augment")]);
    round_trips(&sy, &e);
    // the makearray table head still reads and prints the same
    let table = print::mk_json(&print::MkForm {
        out: vec![],
        regions: vec![vec![(int(1), int(2))]],
        values: vec![s("delim")],
    });
    assert_eq!(
        print_typst(&sy, &table),
        "mat(delim: \"[\", augment: #1, italic(\"delim\"), [1, 2])"
    );
    round_trips(&sy, &table);
}

#[test]
fn call_form_reads_only_what_the_printer_writes() {
    let sy = sym(&["a", "x"]);
    // an annotation on a core operator goes to the escape form
    refuses_l(
        &sy,
        "\\operatorname{broadcast}(a, x; \\mathrm{id} = \\text{\"q\"})",
    );
    refuses_t(&sy, "op(\"broadcast\")(a, x; upright(\"id\") = #\"q\")");
    refuses_l(
        &sy,
        "\\operatorname{broadcast}(a, x; \\mathrm{expect\\_cadence} = \\text{\"const\"}, \\mathrm{fn} = \\text{\"+\"})",
    );
    // ... an open operator keeps it in the call form
    let open = mk_node("myop", vec![s("x")], vec![("id".into(), s("q"))]);
    reads_l(
        &sy,
        "\\operatorname{myop}(x; \\mathrm{id} = \\text{\"q\"})",
        open.clone(),
    );
    assert!(print_latex(&sy, &open).starts_with("\\operatorname{myop}(x; \\mathrm{id} = "));
    round_trips(&sy, &open);
    // repeated keys, `op`, `args`
    refuses_l(
        &sy,
        "\\operatorname{myop}(x; \\mathrm{s} = 1, \\mathrm{s} = 2)",
    );
    refuses_l(&sy, "\\operatorname{myop}(x; \\mathrm{op} = 1)");
    refuses_l(&sy, "\\operatorname{myop}(x; \\mathrm{args} = 1)");
    // a node with a native spelling
    refuses_l(&sy, "\\operatorname{const}(; \\mathrm{value} = [1, 2])");
    refuses_t(&sy, "op(\"const\")(; upright(\"value\") = #(1, 2))");
    reads_l(&sy, "\\begin{bmatrix}1 \\\\ 2\\end{bmatrix}", {
        Json::Obj(vec![
            ("args".into(), Json::Arr(vec![])),
            ("op".into(), s("const")),
            ("value".into(), Json::Arr(vec![int(1), int(2)])),
        ])
    });
    let rank3 = "\\operatorname{const}(; \\mathrm{value} = [[[1, 2], [3, 4]], [[5, 6], [7, 8]]])";
    assert!(parse_latex(&sy, rank3).is_some());
    let mk = print::mk_json(&print::MkForm {
        out: vec![],
        regions: vec![vec![(int(1), int(2))]],
        values: vec![s("x")],
    });
    let Json::Obj(kvs) = &mk else { unreachable!() };
    assert!(print::native_form(Sf::Latex, kvs));
    // a key the printer would escape still reads in the call form
    reads_l(
        &sy,
        "\\operatorname{myop}(x; \\mathrm{a{\\char037}b} = 1)",
        mk_node("myop", vec![s("x")], vec![("a%b".into(), int(1))]),
    );
}

#[test]
fn bare_template_name() {
    let sy = Sym {
        names: vec!["x".into()],
        templates: vec![("zero".into(), vec![]), ("one".into(), vec!["u".into()])],
    };
    let t = super::parse::t_node;
    // a template known to take no parameters prints `n()`, so bare is refused
    let z = t("zero", vec![]);
    assert_eq!(print_latex(&sy, &z), "\\operatorname{zero}()");
    assert_eq!(print_typst(&sy, &z), "op(\"zero\")()");
    refuses_l(&sy, "\\operatorname{zero}");
    refuses_l(&sy, "\\operatorname{zero} + x");
    refuses_t(&sy, "op(\"zero\")");
    round_trips(&sy, &z);
    // with parameters, or out of scope, the bare name stays
    for n in ["one", "elsewhere"] {
        let e = t(n, vec![]);
        assert_eq!(print_latex(&sy, &e), format!("\\operatorname{{{n}}}"));
        round_trips(&sy, &e);
        reads_l(
            &sy,
            &format!("\\operatorname{{{n}}} + x"),
            node("+", vec![e, s("x")]),
        );
    }
}

#[test]
fn region_product_is_two_tokens() {
    use super::token::{Kw, Tok};
    let cs: Vec<char> = "[1, N] \\times [2, 2]".chars().collect();
    let toks = latex::lex(&cs).unwrap();
    assert_eq!(toks[5], Tok::Kw(Kw::Times));
    assert_eq!(toks[6], Tok::Kw(Kw::Lbk));
    let cs: Vec<char> = "[1, N] times [2, 2]".chars().collect();
    let toks = super::typst::lex(&cs).unwrap();
    assert_eq!(toks[5], Tok::Kw(Kw::Times));
    assert_eq!(toks[6], Tok::Kw(Kw::Lbk));
    let sy = hw();
    // after a pair's `]`, `\times [` continues the region; a product in the
    // value stays a product
    let table = print::mk_json(&print::MkForm {
        out: vec![],
        regions: vec![vec![(int(1), s("N")), (int(1), int(2))]],
        values: vec![node("*", vec![s("a"), s("x")])],
    });
    reads_l(
        &sy,
        "\\left[\\begin{array}{l|l} a \\times [x] & [1, N]\n\\times\n[1, 2] \\end{array}\\right]",
        table.clone(),
    );
    reads_t(
        &sy,
        "mat(delim: \"[\", augment: #1, a times [x], [1, N] times [1, 2])",
        table.clone(),
    );
    assert_eq!(
        print_latex(&sy, &table),
        "\\left[\\begin{array}{l|l} a x & [1, N] \\times [1, 2] \\end{array}\\right]"
    );
    assert_eq!(
        print_typst(&sy, &table),
        "mat(delim: \"[\", augment: #1, a x, [1, N] times [1, 2])"
    );
    round_trips(&sy, &table);
}

#[test]
fn wide_constant_matrix() {
    let sy = hw();
    let cnst = |rows: Vec<Vec<i128>>| {
        Json::Obj(vec![
            ("args".into(), Json::Arr(vec![])),
            ("op".into(), s("const")),
            (
                "value".into(),
                Json::Arr(
                    rows.into_iter()
                        .map(|r| Json::Arr(r.into_iter().map(int).collect()))
                        .collect(),
                ),
            ),
        ])
    };
    let wide = cnst(vec![(1..=11).collect(), (12..=22).collect()]);
    let row = |a: i128, b: i128| {
        (a..=b)
            .map(|v| v.to_string())
            .collect::<Vec<_>>()
            .join(" & ")
    };
    let want = format!(
        "\\left[\\begin{{array}}{{ccccccccccc}}{} \\\\ {} \\end{{array}}\\right]",
        row(1, 11),
        row(12, 22)
    );
    assert_eq!(print_latex(&sy, &wide), want);
    round_trips(&sy, &wide);
    assert!(print_typst(&sy, &wide).starts_with("mat(1, 2,"));
    // ten columns stay a bmatrix
    let ten = cnst(vec![(1..=10).collect(), (11..=20).collect()]);
    assert!(print_latex(&sy, &ten).starts_with("\\begin{bmatrix}"));
    round_trips(&sy, &ten);
    // a long column stays a bmatrix
    let col = Json::Obj(vec![
        ("args".into(), Json::Arr(vec![])),
        ("op".into(), s("const")),
        ("value".into(), Json::Arr((1..=12).map(int).collect())),
    ]);
    assert!(print_latex(&sy, &col).starts_with("\\begin{bmatrix}"));
    round_trips(&sy, &col);
    // canonical only: a wide bmatrix, a narrow array, a wrong count
    refuses_l(
        &sy,
        &format!(
            "\\begin{{bmatrix}}{} \\\\ {}\\end{{bmatrix}}",
            row(1, 11),
            row(12, 22)
        ),
    );
    refuses_l(
        &sy,
        "\\left[\\begin{array}{cc}1 & 2 \\\\ 3 & 4 \\end{array}\\right]",
    );
    refuses_l(
        &sy,
        &format!(
            "\\left[\\begin{{array}}{{cccccccccccc}}{} \\\\ {} \\end{{array}}\\right]",
            row(1, 11),
            row(12, 22)
        ),
    );
    refuses_l(
        &sy,
        &format!(
            "\\left[\\begin{{array}}{{ccccccccccc}}{} \\\\ {} \\end{{array}}\\right]",
            row(1, 11),
            row(12, 21)
        ),
    );
    // the makearray table head is a separate token
    use super::token::{Kw, Tok};
    let cs: Vec<char> = "\\begin{array}{l|l}".chars().collect();
    assert_eq!(latex::lex(&cs), Some(vec![Tok::Kw(Kw::Barr)]));
    let cs: Vec<char> = "\\begin{array}{ccc}".chars().collect();
    assert_eq!(latex::lex(&cs), Some(vec![Tok::Carr(3)]));
    let cs: Vec<char> = "\\begin{array}{}".chars().collect();
    assert_eq!(latex::lex(&cs), None);
}
