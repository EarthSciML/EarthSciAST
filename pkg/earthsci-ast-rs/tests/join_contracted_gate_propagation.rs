//! Gates between two CONTRACTED dims restrict the walk — CONFORMANCE_SPEC.md
//! §5.24.2, the both-contracted bullet.
//!
//! Before this, at most one such gate (the most selective) drove the walk, from
//! whichever of its two dims came first; every other one was a per-leaf
//! `filter` test, and a Phase-1 pin on a contracted dim (from a gate to a bound
//! output index) never crossed a contracted–contracted gate. Two relational
//! shapes then enumerated close to the full product:
//!
//! * a **star** — several dims each joined to one contracted hub;
//! * a **chain** — a pin on one contracted dim that a chain of
//!   contracted–contracted gates could carry to the dims beyond it.
//!
//! Each fixture here asserts the three things the driver is only legitimate
//! if all hold:
//!
//! 1. **Bit-identical values**, against a plain-Rust oracle that folds the
//!    admitted terms in the odometer's order, against the hand-written
//!    `filter` the clauses lower to, against the same document with the gate
//!    driver switched off (`set_join_gate_enabled(false)`), and against the
//!    tape (the `native` compiler's tuple-list lowering), under every ordering
//!    of the `join` clauses. The weights mix magnitudes so that a reordered or
//!    dropped/duplicated term changes the bits.
//! 2. **Many-to-many survives**: every key repeats on both sides, so a hub row
//!    has several partners per spoke and the answer is a sum of m·n terms.
//! 3. **The conjunction drives**: the interpreter's leaf count equals the
//!    number of tuples the clauses TOGETHER admit — what the relational answer
//!    costs — which is strictly fewer than the pre-change walk visited (the
//!    numbers in each test's comment were measured on the parent commit).

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::extension::broad_phase::{
    overlap_enum_visits, reset_overlap_enum_visits, set_join_gate_enabled,
};
use earthsci_ast::{Compiler, ProblemOptions, esm_problem, observed_field};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Map, Value, json};

fn arr1(v: &[f64]) -> ArrayD<f64> {
    ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap()
}

fn ix(f: &str, i: &str) -> Value {
    json!({"op": "index", "args": [f, i]})
}

/// Every permutation of `0..n`.
fn permutations(n: usize) -> Vec<Vec<usize>> {
    let mut out = vec![vec![]];
    for _ in 0..n {
        let mut next = Vec::new();
        for p in &out {
            for v in 0..n {
                if !p.contains(&v) {
                    let mut q = p.clone();
                    q.push(v);
                    next.push(q);
                }
            }
        }
        out = next;
    }
    out
}

/// A tiny deterministic generator, so the fixtures are reproducible without a
/// dependency.
struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }
    /// `n` keys drawn from `0..k`: with `k < n` every key repeats.
    fn keys(&mut self, n: usize, k: u64) -> Vec<f64> {
        (0..n).map(|_| (self.next() % k) as f64).collect()
    }
    /// Weights of mixed magnitude, so the fold's association shows in the bits.
    fn weights(&mut self, n: usize) -> Vec<f64> {
        (0..n)
            .map(|_| {
                let m = (self.next() % 1000) as f64 / 7.0 + 0.1;
                if self.next().is_multiple_of(3) {
                    m * 1e9
                } else {
                    m
                }
            })
            .collect()
    }
}

/// One `on` clause: `lcol[lsym] == rcol[rsym]`.
struct Clause {
    lcol: &'static str,
    lsym: &'static str,
    rcol: &'static str,
    rsym: &'static str,
}

/// `E[out...] = Σ_{contracted} Π_d w_d[d]` under the conjunction of `clauses`.
/// Symbols name their own index set (`<sym>rows`) and weight (`w_<sym>`); a
/// symbol's dims are listed in odometer order (first outermost), which is also
/// alphabetical, the order the contraction runs in.
struct Fixture {
    out: Vec<(&'static str, usize)>,
    contracted: Vec<(&'static str, usize)>,
    clauses: Vec<Clause>,
    /// Key columns: name → (symbol it runs over, values).
    keys: Vec<(&'static str, &'static str, Vec<f64>)>,
    weights: HashMap<&'static str, Vec<f64>>,
}

impl Fixture {
    fn new(
        out: Vec<(&'static str, usize)>,
        contracted: Vec<(&'static str, usize)>,
        clauses: Vec<Clause>,
        nkeys: u64,
        seed: u64,
    ) -> Self {
        let mut rng = Lcg(seed);
        let size = |s: &str| -> usize {
            out.iter()
                .chain(&contracted)
                .find(|(n, _)| *n == s)
                .unwrap_or_else(|| panic!("no symbol {s}"))
                .1
        };
        let mut keys = Vec::new();
        for c in &clauses {
            for (col, sym) in [(c.lcol, c.lsym), (c.rcol, c.rsym)] {
                if !keys.iter().any(|(n, _, _)| *n == col) {
                    keys.push((col, sym, rng.keys(size(sym), nkeys)));
                }
            }
        }
        let weights = out
            .iter()
            .chain(&contracted)
            .map(|&(s, n)| (s, rng.weights(n)))
            .collect();
        Fixture {
            out,
            contracted,
            clauses,
            keys,
            weights,
        }
    }

    fn key(&self, col: &str) -> &[f64] {
        &self.keys.iter().find(|(n, _, _)| *n == col).unwrap().2
    }

    fn admits(&self, bind: &HashMap<&str, usize>) -> bool {
        self.clauses
            .iter()
            .all(|c| self.key(c.lcol)[bind[c.lsym]] == self.key(c.rcol)[bind[c.rsym]])
    }

    /// Every combination of `dims`, odometer order (last fastest).
    fn odometer(dims: &[(&'static str, usize)]) -> Vec<Vec<usize>> {
        let mut out = vec![vec![]];
        for &(_, n) in dims {
            out = out
                .into_iter()
                .flat_map(|p| {
                    (0..n).map(move |v| {
                        let mut q = p.clone();
                        q.push(v);
                        q
                    })
                })
                .collect();
        }
        out
    }

    /// `(values row-major over the output box, admitted tuple count)`.
    fn oracle(&self) -> (Vec<f64>, u64) {
        let mut vals = Vec::new();
        let mut admitted = 0;
        for o in Self::odometer(&self.out) {
            let mut acc = 0.0f64;
            for c in Self::odometer(&self.contracted) {
                let bind: HashMap<&str, usize> = self
                    .out
                    .iter()
                    .map(|d| d.0)
                    .zip(o.iter().copied())
                    .chain(self.contracted.iter().map(|d| d.0).zip(c.iter().copied()))
                    .collect();
                if self.admits(&bind) {
                    admitted += 1;
                    let mut term = 1.0f64;
                    for &(s, _) in self.out.iter().chain(&self.contracted) {
                        term *= self.weights[s][bind[s]];
                    }
                    acc += term;
                }
            }
            vals.push(acc);
        }
        (vals, admitted)
    }

    fn doc(&self, perm: &[usize], gate: bool) -> Value {
        let syms: Vec<&str> = self
            .out
            .iter()
            .chain(&self.contracted)
            .map(|d| d.0)
            .collect();
        let mut ranges = Map::new();
        for s in &syms {
            ranges.insert((*s).into(), json!({"from": format!("{s}rows")}));
        }
        let mut args: Vec<Value> = self.keys.iter().map(|(n, _, _)| json!(n)).collect();
        args.extend(syms.iter().map(|s| json!(format!("w_{s}"))));
        let mut expr = ix(&format!("w_{}", syms[0]), syms[0]);
        for s in &syms[1..] {
            expr = json!({"op": "*", "args": [expr, ix(&format!("w_{s}"), s)]});
        }
        let mut node = json!({
            "op": "faq",
            "reduce": "+",
            "output_idx": self.out.iter().map(|d| d.0).collect::<Vec<_>>(),
            "ranges": ranges,
            "args": args,
            "expr": expr,
        });
        let obj = node.as_object_mut().unwrap();
        if gate {
            obj.insert(
                "join".into(),
                Value::Array(
                    perm.iter()
                        .map(|&i| {
                            let c = &self.clauses[i];
                            json!({"on": [[c.lcol, c.rcol]]})
                        })
                        .collect(),
                ),
            );
        } else {
            let eqs: Vec<Value> = self
                .clauses
                .iter()
                .map(|c| json!({"op": "==", "args": [ix(c.lcol, c.lsym), ix(c.rcol, c.rsym)]}))
                .collect();
            obj.insert("filter".into(), json!({"op": "and", "args": eqs}));
        }
        let mut index_sets = Map::new();
        let mut variables = Map::new();
        for &(s, n) in self.out.iter().chain(&self.contracted) {
            index_sets.insert(format!("{s}rows"), json!({"kind": "interval", "size": n}));
            variables.insert(
                format!("w_{s}"),
                json!({"type": "parameter", "shape": [format!("{s}rows")]}),
            );
        }
        for (n, s, _) in &self.keys {
            variables.insert(
                (*n).into(),
                json!({"type": "parameter", "shape": [format!("{s}rows")]}),
            );
        }
        variables.insert(
            "E".into(),
            json!({"type": "unknown",
                   "shape": self.out.iter().map(|d| format!("{}rows", d.0)).collect::<Vec<_>>()}),
        );
        json!({
            "esm": "2.0.0",
            "metadata": {"name": "join_contracted_gate_propagation"},
            "index_sets": index_sets,
            "models": {"J": {"variables": variables, "equations": [{"lhs": "E", "rhs": node}]}}
        })
    }

    fn const_arrays(&self) -> HashMap<String, ArrayD<f64>> {
        self.keys
            .iter()
            .map(|(n, _, v)| ((*n).to_string(), arr1(v)))
            .chain(
                self.weights
                    .iter()
                    .map(|(s, v)| (format!("w_{s}"), arr1(v))),
            )
            .collect()
    }
}

/// Materialize `E` under `compiler`, returning `(values row-major, leaves the
/// interpreter's gate-driven walk visited)`.
fn run(
    doc: &Value,
    consts: HashMap<String, ArrayD<f64>>,
    driver: bool,
    compiler: Compiler,
) -> (Vec<f64>, u64) {
    let prev = set_join_gate_enabled(driver);
    reset_overlap_enum_visits();
    let prep = esm_problem(
        doc,
        (0.0, 0.0),
        ProblemOptions {
            compiler: Some(compiler),
            model_name: Some("J".into()),
            const_arrays: consts,
            build_providers: Vec::new(),
            ..Default::default()
        },
    )
    .expect("prepare");
    let visits = overlap_enum_visits();
    let field = observed_field(&prep, "E").expect("E materialized");
    set_join_gate_enabled(prev);
    // `observed_field` is an `ArrayD` in its logical (row-major) layout.
    (field.iter().copied().collect(), visits)
}

fn assert_bits(what: &str, got: &[f64], want: &[f64]) {
    assert_eq!(got.len(), want.len(), "{what}: wrong output length");
    for (i, (g, w)) in got.iter().zip(want).enumerate() {
        assert_eq!(
            g.to_bits(),
            w.to_bits(),
            "{what}: E[{i}] = {g} but the reference says {w}"
        );
    }
}

/// Run `f` through every check in the module docs; `old_leaves` is what the
/// pre-change interpreter visited (measured on the parent commit), which the
/// new walk must beat.
fn check(f: &Fixture, old_leaves: u64) {
    let (oracle, admitted) = f.oracle();
    assert!(admitted > 0, "the fixture admits nothing");
    assert!(
        admitted < old_leaves,
        "the fixture must separate the two walks"
    );

    let (filtered, filter_visits) = run(
        &f.doc(&[], false),
        f.const_arrays(),
        true,
        Compiler::Interpreter,
    );
    assert_eq!(
        filter_visits, 0,
        "the un-gated arm must not run the driven walk"
    );
    assert_bits("hand-written filter", &filtered, &oracle);

    for perm in permutations(f.clauses.len()) {
        let what = format!("clause order {perm:?}");
        let doc = f.doc(&perm, true);
        let (got, visits) = run(&doc, f.const_arrays(), true, Compiler::Interpreter);
        assert_bits(&what, &got, &oracle);
        assert_eq!(
            visits, admitted,
            "{what}: the walk must visit exactly the {admitted} tuples the clauses \
             TOGETHER admit (the pre-change walk visited {old_leaves})"
        );
        let (undriven, undriven_visits) = run(&doc, f.const_arrays(), false, Compiler::Interpreter);
        assert_eq!(undriven_visits, 0, "{what}: the kill-switch must not drive");
        assert_bits(&format!("{what}, driver off"), &undriven, &oracle);
        let (taped, _) = run(&doc, f.const_arrays(), true, Compiler::Native);
        assert_bits(&format!("{what}, tape"), &taped, &oracle);
    }
}

/// A STAR over a contracted hub: `E[n] = Σ_{k,m,s,x}` with `k~x`, `m~x` and
/// `s~x`, and the hub `x` last. One clause used to drive `x` from its spoke and
/// the other two were tested per leaf; now `x` walks the intersection of all
/// three spokes' partner lists. (moves.esm `run_startModeAgeVariation`:
/// 235,782,144 leaves for one scalar.)
#[test]
fn a_star_join_intersects_every_spoke() {
    let f = Fixture::new(
        vec![("n", 2)],
        vec![("k", 6), ("m", 5), ("s", 4), ("x", 30)],
        vec![
            Clause {
                lcol: "kk",
                lsym: "k",
                rcol: "xk",
                rsym: "x",
            },
            Clause {
                lcol: "mk",
                lsym: "m",
                rcol: "xm",
                rsym: "x",
            },
            Clause {
                lcol: "sk",
                lsym: "s",
                rcol: "xs",
                rsym: "x",
            },
        ],
        3,
        11,
    );
    check(&f, OLD_STAR_LEAVES);
}

/// A CHAIN through a Phase-1-pinned contracted dim: output `w`, contracted
/// `a, b, c`, with `w~c` (pins `c` per cell), `b~c` and `a~b`. The pin on `c`
/// used to stop at `c`; now it propagates to `b` and from `b` to `a` before
/// the walk. (moves.esm `tvh_soakTies` and `rpd_ratePerDistance`.)
#[test]
fn a_chain_join_carries_a_pin_across_contracted_gates() {
    let f = Fixture::new(
        vec![("w", 4)],
        vec![("a", 12), ("b", 10), ("c", 8)],
        vec![
            Clause {
                lcol: "wc",
                lsym: "w",
                rcol: "cw",
                rsym: "c",
            },
            Clause {
                lcol: "bc",
                lsym: "b",
                rcol: "cb",
                rsym: "c",
            },
            Clause {
                lcol: "ab",
                lsym: "a",
                rcol: "ba",
                rsym: "b",
            },
        ],
        4,
        23,
    );
    check(&f, OLD_CHAIN_LEAVES);
}

/// MANY-TO-MANY across the propagated restriction and the multi-gate
/// intersection at once, hand-checkable: output `o` pins hub `h` through
/// `o~h`; `p~h` and `q~h` are both-contracted spokes off the hub, which is
/// the first contracted dim, so the pin reaches `p` and `q` only by
/// propagation. Key 1 occurs twice on every column, so cell `o0` must sum
/// 2 (p) × 2 (q) × 2 (h) = 8 terms, and cell `o1` (key 5, which no `h` carries)
/// is the identity.
#[test]
fn many_to_many_emits_every_term() {
    let mut f = Fixture::new(
        vec![("o", 2)],
        vec![("h", 4), ("p", 3), ("q", 3)],
        vec![
            Clause {
                lcol: "oh",
                lsym: "o",
                rcol: "ho",
                rsym: "h",
            },
            Clause {
                lcol: "pk",
                lsym: "p",
                rcol: "hp",
                rsym: "h",
            },
            Clause {
                lcol: "qk",
                lsym: "q",
                rcol: "hq",
                rsym: "h",
            },
        ],
        2,
        5,
    );
    let set = |f: &mut Fixture, col: &str, v: Vec<f64>| {
        f.keys.iter_mut().find(|(n, _, _)| *n == col).unwrap().2 = v;
    };
    set(&mut f, "oh", vec![1.0, 5.0]);
    set(&mut f, "ho", vec![1.0, 2.0, 1.0, 3.0]);
    set(&mut f, "pk", vec![7.0, 4.0, 7.0]);
    set(&mut f, "hp", vec![7.0, 7.0, 7.0, 4.0]);
    set(&mut f, "qk", vec![9.0, 9.0, 8.0]);
    set(&mut f, "hq", vec![9.0, 8.0, 9.0, 9.0]);
    // o0 pins h ∈ {0, 2}; each has p ∈ {0, 2} and q ∈ {0, 1}: 8 terms.
    let (oracle, admitted) = f.oracle();
    assert_eq!(admitted, 8, "2 x 2 x 2 many-to-many");
    assert_eq!(oracle[1], 0.0, "o1 matches no hub row: the identity");
    check(&f, OLD_M2M_LEAVES);
}

// Leaves the interpreter visited on the parent commit (origin/main 1f4c2a928)
// for the same fixtures, under the default clause order — the driven walk with
// one both-contracted gate driving and the rest tested per leaf.
const OLD_STAR_LEAVES: u64 = 2_280;
const OLD_CHAIN_LEAVES: u64 = 288;
const OLD_M2M_LEAVES: u64 = 12;
