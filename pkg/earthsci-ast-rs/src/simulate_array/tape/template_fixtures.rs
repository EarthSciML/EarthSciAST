//! Template documents shared by the tape's test modules: the
//! standard-library templates of `lib/calendar.esm`, `lib/geometry.esm` and
//! `lib/relational.esm` expanded per cell of an index set, and the
//! `lib/interp.esm` lookups read per cell or once. The tape tests run them
//! against the per-cell oracle; the XLA tests run them through the emitted
//! program.

use super::test_support::{apply, d_lhs, document, faq, ix, konst, library, op};
use serde_json::{Value, json};

const FIELDS: [&str; 9] = [
    "year",
    "month",
    "day",
    "hour",
    "minute",
    "second",
    "day_of_year",
    "julian_day",
    "is_leap_year",
];

/// Per cell `l` of 24, `tu[l] = t0 + 3601 l + 1e5 u[l]` (the state moves it
/// across days and years), and each field relaxes a state of its own.
pub(super) fn calendar_doc(t0: f64) -> Value {
    let l = json!({"l": [1, 24]});
    let mut vars = json!({
        "u": {"type": "unknown", "shape": ["lev"], "default": 1.0},
        "tu": {"type": "unknown", "shape": ["lev"]}
    });
    let mut eqs = vec![
        json!({"lhs": "tu", "rhs": faq(&["l"], l.clone(), op("+", vec![json!(t0), op("*", vec![json!(3601), json!("l")]),
            op("*", vec![json!(1.0e5), ix("u", vec![json!("l")])])]))}),
        json!({"lhs": d_lhs("u", &["l"], l.clone()),
               "rhs": faq(&["l"], l.clone(), op("*", vec![json!(-0.1), ix("u", vec![json!("l")])]))}),
    ];
    for f in FIELDS {
        let at = ix("tu", vec![json!("l")]);
        let call = apply(f, json!({"t": at}));
        let s = format!("s_{f}");
        vars[&s] = json!({"type": "unknown", "shape": ["lev"], "default": 0.0});
        eqs.push(json!({"lhs": d_lhs(&s, &["l"], l.clone()),
            "rhs": faq(&["l"], l.clone(), op("-", vec![call, ix(&s, vec![json!("l")])]))}));
    }
    let mut model = json!({"variables": vars, "equations": eqs});
    model["operators"] = library("calendar.esm");
    document(
        "calendar_on_the_tape",
        json!({"lev": {"kind": "interval", "size": 24}}),
        model,
    )
}

/// Lat-lon cells, counter-clockwise from the south-west corner.
pub(super) fn cells(lons: &[f64], lats: &[f64]) -> Value {
    let mut out = Vec::new();
    for b in 0..lats.len() - 1 {
        for a in 0..lons.len() - 1 {
            out.push(json!([
                [lons[a], lats[b]],
                [lons[a + 1], lats[b]],
                [lons[a + 1], lats[b + 1]],
                [lons[a], lats[b + 1]]
            ]));
        }
    }
    Value::Array(out)
}

/// Every source x target pair's overlap area (2 x 2 one-degree cells onto
/// the 3 x 3 grid of 2/3-degree cells over them, with one repeated vertex in
/// a target ring), weighting a state per source cell into a state per target
/// cell.
pub(super) fn overlap_doc(spherical: bool) -> Value {
    let src = cells(&[10.0, 11.0, 12.0], &[40.0, 41.0, 42.0]);
    let th = [10.0, 10.0 + 2.0 / 3.0, 10.0 + 4.0 / 3.0, 12.0];
    let ta = [40.0, 40.0 + 2.0 / 3.0, 40.0 + 4.0 / 3.0, 42.0];
    let mut tgt = cells(&th, &ta);
    // A padded ring: its first vertex repeated in the last slot.
    let v0 = tgt[4][0].clone();
    tgt[4][3] = v0;
    let r = json!({"i": [1, 4], "j": [1, 9]});
    let (a, b, name) = if spherical {
        ("sx", "tx", "overlap_area_spherical")
    } else {
        ("src", "tgt", "overlap_area_planar")
    };
    let area = apply(
        name,
        json!({"ring_a": a, "cell_a": "i", "nv_a": 4, "ring_b": b, "cell_b": "j", "nv_b": 4}),
    );
    let mut vars = json!({
        "src": {"type": "unknown", "shape": ["sc", "cv", "co"]},
        "tgt": {"type": "unknown", "shape": ["tc", "cv", "co"]},
        "A": {"type": "unknown", "shape": ["sc", "tc"]},
        "u": {"type": "unknown", "shape": ["sc"], "default": 1.0},
        "w": {"type": "unknown", "shape": ["tc"], "default": 0.0}
    });
    let mut eqs = vec![
        json!({"lhs": "src", "rhs": {"op": "const", "args": [], "value": src}}),
        json!({"lhs": "tgt", "rhs": {"op": "const", "args": [], "value": tgt}}),
        json!({"lhs": "A", "rhs": faq(&["i", "j"], r.clone(), area)}),
        json!({"lhs": d_lhs("u", &["i"], json!({"i": [1, 4]})),
               "rhs": faq(&["i"], json!({"i": [1, 4]}), op("*", vec![json!(-0.1), ix("u", vec![json!("i")])]))}),
        json!({"lhs": d_lhs("w", &["j"], json!({"j": [1, 9]})),
               "rhs": faq(&["j"], r.clone(), op("-", vec![op("*", vec![ix("A", vec![json!("i"), json!("j")]), ix("u", vec![json!("i")])]),
                    ix("w", vec![json!("j")])]))}),
    ];
    if spherical {
        for (xyz, ring, n) in [("sx", "src", 4), ("tx", "tgt", 9)] {
            vars[xyz] =
                json!({"type": "unknown", "shape": [if n == 4 { "sc" } else { "tc" }, "cv", "d3"]});
            eqs.push(json!({"lhs": xyz, "rhs": faq(&["c", "v", "d"], json!({"c": [1, n], "v": [1, 4], "d": [1, 3]}), apply("lonlat_to_unit",
                json!({"ring": ring, "cell": "c", "vert": "v", "comp": "d"})))}));
        }
    }
    let mut model = json!({"variables": vars, "equations": eqs});
    model["operators"] = library("geometry.esm");
    document(
        "overlap_on_the_tape",
        json!({"sc": {"kind": "interval", "size": 4}, "tc": {"kind": "interval", "size": 9},
               "cv": {"kind": "interval", "size": 4}, "co": {"kind": "interval", "size": 2},
               "d3": {"kind": "interval", "size": 3}}),
        model,
    )
}

/// `assign[i] = argmin_g (x[i] - gx[g])^2`, the candidates reading the state
/// `x`; ties are real (generators at equal distances).
pub(super) fn argmin_doc() -> Value {
    let gx = json!([0.5, 1.0, 1.5, 1.0, 2.0, 2.5]);
    let dist = op(
        "*",
        vec![
            op(
                "-",
                vec![
                    ix("x", vec![json!("i")]),
                    ix("gx", vec![json!("k_argmin_1")]),
                ],
            ),
            op(
                "-",
                vec![
                    ix("x", vec![json!("i")]),
                    ix("gx", vec![json!("k_argmin_1")]),
                ],
            ),
        ],
    );
    let r = json!({"i": [1, 7]});
    let mut model = json!({
        "variables": {
            "gx": {"type": "unknown", "shape": ["g"]},
            "x": {"type": "unknown", "shape": ["p"], "default": 1.0},
            "assign": {"type": "unknown", "shape": ["p"]}
        },
        "equations": [
            {"lhs": "gx", "rhs": {"op": "const", "args": [], "value": gx}},
            {"lhs": "assign", "rhs": faq(&["i"], r.clone(), apply("argmin", json!({"f": dist, "n": 6})))},
            {"lhs": d_lhs("x", &["i"], r.clone()),
             "rhs": faq(&["i"], r.clone(), op("-", vec![op("*", vec![json!(0.1), ix("assign", vec![json!("i")])]),
                 ix("x", vec![json!("i")])]))}
        ]
    });
    model["operators"] = library("relational.esm");
    document(
        "argmin_on_the_tape",
        json!({"p": {"kind": "interval", "size": 7}, "g": {"kind": "interval", "size": 6}}),
        model,
    )
}

/// The other lib/relational.esm templates per cell of a state: a gated
/// arg-witness (`argmin_where` / `argmax_where`, a contracted `faq` with a
/// `filter`; no candidate passing gives `n + 1`), the composite keys
/// `pair_key` / `edge_key` (NaN for an out-of-range or non-integral
/// component), `rank_of` over literal members and `rank_of_set` over an
/// index set the call names.
pub(super) fn relational_doc() -> Value {
    let x = || ix("x", vec![json!("i")]);
    let g = |k: &str| ix("gx", vec![json!(k)]);
    let d = |k: &str| {
        op(
            "*",
            vec![op("-", vec![x(), g(k)]), op("-", vec![x(), g(k)])],
        )
    };
    // Candidates above the cell's own value compete (none for the largest).
    let pass = |k: &str| op(">", vec![g(k), x()]);
    let key_a = op("floor", vec![op("*", vec![json!(3), x()])]);
    let key_b = op("floor", vec![op("*", vec![json!(2), x()])]);
    let r = json!({"i": [1, 7]});
    let cell = |e: Value| faq(&["i"], r.clone(), e);
    let sum = op(
        "+",
        vec![
            apply(
                "argmin_where",
                json!({"f": d("k_argmin_where_1"), "p": pass("k_argmin_where_1"), "n": 6}),
            ),
            apply(
                "argmax_where",
                json!({"f": d("k_argmax_where_1"), "p": pass("k_argmax_where_1"), "n": 6}),
            ),
            apply(
                "pair_key",
                json!({"a": key_a, "b": key_b, "lo_a": 0, "lo_b": 1, "n_a": 8, "n_b": 5}),
            ),
            apply("edge_key", json!({"u": key_a, "v": key_b, "lo": 0, "n": 8})),
            apply(
                "rank_of",
                json!({"x": x(), "members": {"op": "const", "args": [], "value": [0.5, 1.0, 1.5, 2.25]}, "n": 4}),
            ),
            apply("rank_of_set", json!({"x": x(), "members": "gx", "S": "g"})),
        ],
    );
    let mut model = json!({
        "variables": {
            "gx": {"type": "unknown", "shape": ["g"]},
            "x": {"type": "unknown", "shape": ["p"], "default": 1.0},
            "y": {"type": "unknown", "shape": ["p"]}
        },
        "equations": [
            {"lhs": "gx", "rhs": {"op": "const", "args": [], "value": [0.5, 1.0, 1.5, 1.0, 2.0, 2.5]}},
            {"lhs": "y", "rhs": cell(sum)},
            {"lhs": d_lhs("x", &["i"], r.clone()),
             "rhs": cell(op("-", vec![op("*", vec![json!(0.01), ix("y", vec![json!("i")])]), x()]))}
        ]
    });
    model["operators"] = library("relational.esm");
    document(
        "relational_on_the_tape",
        json!({"p": {"kind": "interval", "size": 7}, "g": {"kind": "interval", "size": 6}}),
        model,
    )
}

/// The seeded states fall in [0.25, 2.5]: the axes below cover part of that
/// range, so the probes reach both clamps, every interior cell and the knots.
pub(super) const AXIS: [f64; 7] = [0.5, 0.75, 1.0, 1.5, 1.75, 2.0, 2.25];
pub(super) const TABLE: [f64; 7] = [10.0, 20.0, 40.0, 80.0, 160.0, 170.0, 171.5];
const AXIS_X: [f64; 5] = [0.5, 1.0, 1.25, 2.0, 2.2];
const AXIS_Y: [f64; 4] = [0.4, 1.1, 1.7, 2.3];
const XS: [f64; 6] = [0.5, 1.0, 1.0, 1.0, 1.75, 2.0];

fn table_2d() -> Value {
    let rows: Vec<Vec<f64>> = (0..AXIS_X.len())
        .map(|i| {
            (0..AXIS_Y.len())
                .map(|j| (i * i) as f64 * 3.0 + j as f64 * 0.5 - (i * j) as f64)
                .collect()
        })
        .collect();
    json!(rows)
}

#[derive(Clone, Copy, PartialEq)]
pub(super) enum Lookup {
    Searchsorted,
    Linear,
    Bilinear,
}

/// The lookup at queries `x` (and `y`, for bilinear).
fn lookup(which: Lookup, x: Value, y: Value) -> Value {
    let apply = |name: &str, b: Value| json!({"op": "apply_operator", "args": [], "name": name, "bindings": b});
    match which {
        Lookup::Searchsorted => apply(
            "searchsorted",
            json!({"x": x, "xs": konst(json!(XS)), "n": XS.len()}),
        ),
        Lookup::Linear => apply(
            "linear",
            json!({"table": konst(json!(TABLE)), "axis": konst(json!(AXIS)), "x": x,
                   "n": AXIS.len()}),
        ),
        Lookup::Bilinear => apply(
            "bilinear",
            json!({"table": konst(table_2d()), "axis_x": konst(json!(AXIS_X)),
                   "axis_y": konst(json!(AXIS_Y)), "x": x, "y": y,
                   "nx": AXIS_X.len(), "ny": AXIS_Y.len()}),
        ),
    }
}

/// A model reading the lookup: per cell (`cells = Some(m)`: `c[l]` over
/// `l in [1, m]` at the queries `u[l]`, `w[l]`) or once (`None`: the scalar
/// `c` at the scalar states `u`, `w`). `u` relaxes toward `c`. `nan` replaces
/// the `x` query by a NaN computed from it.
pub(super) fn lookup_model(which: Lookup, cells: Option<i64>, nan: bool) -> Value {
    let at = |v: &str| match cells {
        Some(_) => ix(v, vec![json!("l")]),
        None => json!(v),
    };
    let mut x = at("u");
    if nan {
        let d = op("-", vec![x.clone(), x.clone()]);
        x = op("/", vec![d.clone(), d]);
    }
    let body = lookup(which, x, at("w"));
    let shape = |v: Value| match cells {
        Some(_) => {
            let mut v = v;
            v["shape"] = json!(["lev"]);
            v
        }
        None => v,
    };
    let per_cell = |e: Value| match cells {
        Some(m) => json!({"op": "faq", "args": [], "output_idx": ["l"],
                          "ranges": {"l": [1, m]}, "expr": e}),
        None => e,
    };
    let d_lhs = |v: &str| match cells {
        Some(m) => json!({"op": "faq", "args": [], "output_idx": ["l"],
                          "ranges": {"l": [1, m]},
                          "expr": {"op": "D", "args": [ix(v, vec![json!("l")])], "wrt": "t"}}),
        None => json!({"op": "D", "args": [v], "wrt": "t"}),
    };
    let mut m = json!({
        "variables": {
            "u": shape(json!({"type": "unknown", "default": 1.0})),
            "w": shape(json!({"type": "unknown", "default": 1.0})),
            "c": shape(json!({"type": "unknown"}))
        },
        "equations": [
            {"lhs": "c", "rhs": per_cell(body)},
            {"lhs": d_lhs("u"), "rhs": per_cell(op("+", vec![
                op("*", vec![json!(-0.1), at("u")]),
                op("*", vec![json!(0.01), at("c")])]))},
            {"lhs": d_lhs("w"), "rhs": per_cell(op("*", vec![json!(-0.05), at("w")]))}
        ]
    });
    m["operators"] = library("interp.esm");
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "interp_template_on_the_tape"},
        "models": {"M": m}
    })
}

/// Every template-spelled lookup model: each family, per cell and scalar,
/// with and without a NaN query.
#[cfg(feature = "xla")]
pub(super) fn all_template_models() -> Vec<Value> {
    let mut out = Vec::new();
    for which in [Lookup::Searchsorted, Lookup::Linear, Lookup::Bilinear] {
        for cells in [Some(6), None] {
            for nan in [false, true] {
                out.push(lookup_model(which, cells, nan));
            }
        }
    }
    out
}
