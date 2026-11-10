use criterion::{BenchmarkId, Criterion, criterion_group, criterion_main};
use earthsci_ast::{
    EsmFile, Expr, ExpressionNode, InlineValue, Metadata, Model, Reaction, ReactionSystem, Species,
    StoichiometricEntry, load_string, performance::CompactExpr, stoichiometric_matrix, to_json,
    validate,
};
use indexmap::IndexMap;
use std::collections::HashMap;
use std::hint::black_box;

fn bin_op(op: &str, left: Expr, right: Expr) -> Expr {
    Expr::operator(ExpressionNode {
        op: op.to_string(),
        args: vec![left, right],
        wrt: None,
        dim: None,
        ..Default::default()
    })
}

fn func_call(name: &str, args: Vec<Expr>) -> Expr {
    Expr::operator(ExpressionNode {
        op: name.to_string(),
        args,
        wrt: None,
        dim: None,
        ..Default::default()
    })
}

#[cfg(feature = "parallel")]
use earthsci_ast::performance::ParallelEvaluator;

#[cfg(feature = "simd")]
use earthsci_ast::performance::simd_math;

/// Create a test ESM file with varying complexity.
///
/// The fixture builders here spread `..Default::default()` rather than naming
/// every field. Naming them all is what let this file drift out of compiling
/// (#218): five structs gained a field apiece, and because `cargo test` does
/// not build bench targets, nothing noticed. Spreading the default means a new
/// OPTIONAL field no longer breaks the benches, while a new REQUIRED one (a
/// type with no `Default`, like `Reaction` below) still does — which is the
/// distinction worth keeping.
fn create_test_esm(num_models: usize, equations_per_model: usize) -> EsmFile {
    let mut models = IndexMap::new();

    for i in 0..num_models {
        let mut variables = IndexMap::new();
        let mut equations = Vec::new();

        // Create variables
        for j in 0..equations_per_model {
            let var_name = format!("x{i}_{j}");
            variables.insert(
                var_name.clone(),
                earthsci_ast::ModelVariable {
                    var_type: earthsci_ast::VariableType::Unknown,
                    units: Some("m/s".to_string()),
                    default: Some(InlineValue::Scalar(1.0)),
                    ..Default::default()
                },
            );
        }

        // Create equations: a CHAIN, not a ring. The `% equations_per_model`
        // this replaces wrapped the last observed back to the first and closed a
        // cycle in the observed dependency graph (esm-spec §4.9.6), which the
        // `validate` benchmark below would now spend its time reporting instead
        // of measuring the acyclic walk it exists to measure. Same variable
        // count, same equation count, same shape per equation.
        for j in 0..equations_per_model {
            let var_name = format!("x{i}_{j}");
            let rhs = if j == 0 {
                Expr::Variable("k".to_string())
            } else {
                bin_op(
                    "*",
                    Expr::Variable("k".to_string()),
                    Expr::Variable(format!("x{}_{}", i, j - 1)),
                )
            };
            equations.push(earthsci_ast::Equation {
                lhs: Expr::Variable(var_name),
                rhs,
                ..Default::default()
            });
        }

        let model = Model {
            name: Some(format!("model_{i}")),
            variables,
            equations,
            ..Default::default()
        };

        models.insert(format!("model_{i}"), model);
    }

    EsmFile {
        // `EsmFile::default()` sets `esm` to the current `SCHEMA_VERSION`.
        // The literal "1.0.0" this replaces was already stale -- the schema is
        // at 1.1.0 now -- so the fixture declared a version it no longer
        // matched, which is exactly the drift spreading `Default` stops.
        metadata: Metadata {
            name: Some("benchmark_test".to_string()),
            description: Some("Benchmark test file".to_string()),
            ..Default::default()
        },
        models: Some(models),
        ..Default::default()
    }
}

/// Create a test reaction system with varying complexity
fn create_test_reaction_system(num_species: usize, num_reactions: usize) -> ReactionSystem {
    let mut species = IndexMap::new();
    let mut reactions = Vec::new();

    // Create species (keyed by name in the new schema)
    for i in 0..num_species {
        species.insert(format!("S{i}"), Species::default());
    }

    // Create reactions
    for i in 0..num_reactions {
        let substrate_idx = i % num_species;
        let product_idx = (i + 1) % num_species;

        reactions.push(Reaction {
            id: Some(format!("R{i}")),
            name: Some(format!("R{i}")),
            substrates: Some(vec![StoichiometricEntry {
                species: format!("S{substrate_idx}"),
                coefficient: 1.0,
            }]),
            products: Some(vec![StoichiometricEntry {
                species: format!("S{product_idx}"),
                coefficient: 1.0,
            }]),
            rate: bin_op(
                "*",
                Expr::Number(0.1),
                Expr::Variable(format!("S{substrate_idx}")),
            ),
            reference: None,
        });
    }

    ReactionSystem {
        species,
        reactions,
        ..Default::default()
    }
}

fn benchmark_parsing(c: &mut Criterion) {
    let mut group = c.benchmark_group("parsing");

    for size in [10, 50, 100].iter() {
        let esm_file = create_test_esm(*size, 10);
        let json_str = to_json(&esm_file).unwrap();

        group.bench_with_input(
            BenchmarkId::new("standard_parse", size),
            &json_str,
            |b, json| b.iter(|| load_string(black_box(json)).unwrap()),
        );

        #[cfg(feature = "zero_copy")]
        group.bench_with_input(
            BenchmarkId::new("simd_parse", size),
            &json_str,
            |b, json| b.iter(|| earthsci_ast::performance::fast_parse(black_box(json)).unwrap()),
        );
    }

    group.finish();
}

fn benchmark_validation(c: &mut Criterion) {
    let mut group = c.benchmark_group("validation");

    for size in [10, 50, 100].iter() {
        let esm_file = create_test_esm(*size, 10);

        group.bench_with_input(BenchmarkId::new("validate", size), &esm_file, |b, esm| {
            b.iter(|| validate(black_box(esm)))
        });
    }

    group.finish();
}

fn benchmark_stoichiometric_matrix(c: &mut Criterion) {
    let mut group = c.benchmark_group("stoichiometric_matrix");

    for (species, reactions) in [(10, 20), (50, 100), (100, 200)].iter() {
        let system = create_test_reaction_system(*species, *reactions);

        group.bench_with_input(
            BenchmarkId::new("sequential", format!("{species}x{reactions}")),
            &system,
            |b, sys| b.iter(|| stoichiometric_matrix(black_box(sys))),
        );

        #[cfg(feature = "parallel")]
        {
            let evaluator = ParallelEvaluator::new(None).unwrap();
            group.bench_with_input(
                BenchmarkId::new("parallel", format!("{species}x{reactions}")),
                &system,
                |b, sys| {
                    b.iter(|| {
                        evaluator
                            .compute_stoichiometric_matrix_parallel(black_box(sys))
                            .unwrap()
                    })
                },
            );
        }
    }

    group.finish();
}

fn benchmark_expression_evaluation(c: &mut Criterion) {
    let mut group = c.benchmark_group("expression_evaluation");

    // Create test expressions of varying complexity
    let simple_expr = bin_op("+", Expr::Variable("x".to_string()), Expr::Number(1.0));

    let complex_expr = bin_op(
        "+",
        bin_op(
            "*",
            func_call("sin", vec![Expr::Variable("x".to_string())]),
            Expr::Variable("k".to_string()),
        ),
        func_call(
            "exp",
            vec![bin_op(
                "/",
                Expr::Variable("y".to_string()),
                Expr::Number(2.0),
            )],
        ),
    );

    let mut variables = HashMap::new();
    variables.insert("x".to_string(), 1.5);
    variables.insert("y".to_string(), 2.5);
    variables.insert("k".to_string(), 0.1);

    group.bench_function("simple_standard", |b| {
        b.iter(|| earthsci_ast::evaluate(black_box(&simple_expr), black_box(&variables)).unwrap())
    });

    group.bench_function("complex_standard", |b| {
        b.iter(|| earthsci_ast::evaluate(black_box(&complex_expr), black_box(&variables)).unwrap())
    });

    // Compact expression benchmarks
    let compact_simple = CompactExpr::from_expr(&simple_expr);
    let compact_complex = CompactExpr::from_expr(&complex_expr);

    #[cfg(feature = "parallel")]
    {
        group.bench_function("simple_compact", |b| {
            b.iter(|| compact_simple.evaluate_fast(black_box(&variables)).unwrap())
        });

        group.bench_function("complex_compact", |b| {
            b.iter(|| {
                compact_complex
                    .evaluate_fast(black_box(&variables))
                    .unwrap()
            })
        });
    }

    // Parallel evaluation benchmark
    #[cfg(feature = "parallel")]
    {
        let expressions = vec![simple_expr.clone(); 1000];
        let evaluator = ParallelEvaluator::new(None).unwrap();

        group.bench_function("batch_parallel", |b| {
            b.iter(|| {
                evaluator
                    .evaluate_batch(black_box(&expressions), black_box(&variables))
                    .unwrap()
            })
        });
    }

    group.finish();
}

#[cfg(feature = "simd")]
fn benchmark_simd_operations(c: &mut Criterion) {
    let mut group = c.benchmark_group("simd_operations");

    for size in [100, 1000, 10000].iter() {
        let a: Vec<f64> = (0..*size).map(|i| i as f64).collect();
        let b: Vec<f64> = (0..*size).map(|i| (i + 1) as f64).collect();
        let mut result = vec![0.0; *size];

        group.bench_with_input(
            BenchmarkId::new("add_scalar", size),
            &(*size, &a, &b),
            |bench, (_, a, b)| {
                bench.iter(|| {
                    for i in 0..a.len() {
                        result[i] = a[i] + b[i];
                    }
                    black_box(&result);
                })
            },
        );

        group.bench_with_input(
            BenchmarkId::new("add_simd", size),
            &(*size, &a, &b),
            |bench, (_, a, b)| {
                bench.iter(|| {
                    simd_math::add_vectors_simd(black_box(a), black_box(b), black_box(&mut result))
                        .unwrap();
                    black_box(&result);
                })
            },
        );

        group.bench_with_input(
            BenchmarkId::new("multiply_scalar", size),
            &(*size, &a, &b),
            |bench, (_, a, b)| {
                bench.iter(|| {
                    for i in 0..a.len() {
                        result[i] = a[i] * b[i];
                    }
                    black_box(&result);
                })
            },
        );

        group.bench_with_input(
            BenchmarkId::new("multiply_simd", size),
            &(*size, &a, &b),
            |bench, (_, a, b)| {
                bench.iter(|| {
                    simd_math::multiply_vectors_simd(
                        black_box(a),
                        black_box(b),
                        black_box(&mut result),
                    )
                    .unwrap();
                    black_box(&result);
                })
            },
        );

        group.bench_with_input(
            BenchmarkId::new("dot_scalar", size),
            &(*size, &a, &b),
            |bench, (_, a, b)| {
                bench.iter(|| {
                    let dot: f64 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
                    black_box(dot);
                })
            },
        );

        group.bench_with_input(
            BenchmarkId::new("dot_simd", size),
            &(*size, &a, &b),
            |bench, (_, a, b)| {
                bench.iter(|| {
                    let dot = simd_math::dot_product_simd(black_box(a), black_box(b)).unwrap();
                    black_box(dot);
                })
            },
        );
    }

    group.finish();
}

#[cfg(feature = "custom_alloc")]
fn benchmark_memory_allocation(c: &mut Criterion) {
    let mut group = c.benchmark_group("memory_allocation");

    for size in [1000, 10000, 100000].iter() {
        group.bench_with_input(
            BenchmarkId::new("standard_alloc", size),
            size,
            |b, &size| {
                b.iter(|| {
                    let _data: Vec<f64> = vec![0.0; size];
                    black_box(&_data);
                })
            },
        );

        group.bench_with_input(BenchmarkId::new("bump_alloc", size), size, |b, &size| {
            b.iter(|| {
                let allocator = earthsci_ast::performance::ModelAllocator::new();
                let _data = allocator.alloc_slice::<f64>(size);
                black_box(&_data);
            })
        });
    }

    group.finish();
}

// ---------------------------------------------------------------------------
// Interpolation bracket (issue #588): one right-hand side, three spellings.
// ---------------------------------------------------------------------------

/// One `native` right-hand side of a `bench/interp_bracket` document, ready to
/// call: the compiled model, its scratch, parameters and a state.
struct BracketRhs {
    prob: earthsci_ast::EsmProblem,
    scratch: earthsci_ast::simulate_array::RhsScratch,
    params: Vec<f64>,
    state: Vec<f64>,
}

impl BracketRhs {
    /// Build `bench/interp_bracket/<doc>` under `native`, with the counted
    /// bracket recognised or not ([`earthsci_ast::simulate_array::tape::CompilerRewrites`]).
    fn new(doc: &str, count_rewrite: bool) -> BracketRhs {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../bench/interp_bracket")
            .join(doc);
        let mut rewrites = earthsci_ast::simulate_array::tape::CompilerRewrites::default();
        rewrites.count_fold = count_rewrite;
        let prob = earthsci_ast::esm_problem(
            path.as_path(),
            (0.0, 1.0),
            earthsci_ast::ProblemOptions {
                compiler: Some(earthsci_ast::Compiler::Native),
                rewrites,
                rhs: earthsci_ast::Rhs::Always,
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{doc}: {e}"));
        let compiled = prob.debug_array_compiled().expect("a right-hand side");
        let scratch = compiled.debug_new_scratch_taped().expect("taped");
        let params = compiled.debug_resolve_params(prob.p());
        let state = bracket_state(compiled.state_variable_names());
        BracketRhs {
            prob,
            scratch,
            params,
            state,
        }
    }

    fn call(&mut self, dy: &mut [f64]) {
        let compiled = self.prob.debug_array_compiled().expect("a right-hand side");
        compiled.debug_eval_rhs_into(
            &self.state,
            BRACKET_T,
            &self.params,
            dy,
            &mut self.scratch,
            &mut earthsci_ast::simulate_array::RhsStats::default(),
        );
    }
}

/// The time every bracket call is made at: the forcing moves some queries
/// past each end of the axis.
const BRACKET_T: f64 = 1.3;

/// `(variable, 1-based level)` of a state slot name `u[3]`.
fn bracket_slot(name: &str) -> (String, usize) {
    let (var, rest) = name.split_once('[').expect("an array state");
    (
        var.to_string(),
        rest.trim_end_matches(']').parse().expect("a level"),
    )
}

/// A state with every level different: `u = 10 + l/7`, `v = 2 - l/50`,
/// `th = 290 + l/3`.
fn bracket_state(names: &[String]) -> Vec<f64> {
    names
        .iter()
        .map(|n| {
            let (var, l) = bracket_slot(n);
            let l = l as f64;
            match var.as_str() {
                "u" => 10.0 + l / 7.0,
                "v" => 2.0 - l / 50.0,
                _ => 290.0 + l / 3.0,
            }
        })
        .collect()
}

/// The hand-written right-hand side: the formulas of
/// `bench/interp_bracket/generate.py` evaluated once into tables at setup (the
/// axis is a run-time array: nothing here assumes it is sorted until it has
/// checked), then per call one bracket per level found by bisection and three
/// pinned blends. Writes `dy` in the compiled model's state order.
struct HandBracket {
    z: Vec<f64>,
    tables: [Vec<f64>; 3],
    zq: Vec<f64>,
    /// Per state slot: (table, level - 1).
    slots: Vec<(usize, usize)>,
    sorted: bool,
}

impl HandBracket {
    fn new(n: usize, names: &[String], dz0: f64) -> HandBracket {
        let k = |k: usize| k as f64;
        let z: Vec<f64> = (1..=n)
            .map(|i| (k(i) - 1.0) * (dz0 + (k(i) - 1.0)))
            .collect();
        let u = (1..=n)
            .map(|i| (10.0 + 0.5 * k(i)) - 0.002 * (k(i) * k(i)))
            .collect();
        let v = (1..=n).map(|i| 2.0 - 0.05 * k(i)).collect();
        let th = z.iter().map(|&zk| 290.0 + 0.004 * zk).collect();
        let zq = (1..=n)
            .map(|l| {
                let s = k(l) - 0.6;
                s * (100.0 + s)
            })
            .collect();
        let slots = names
            .iter()
            .map(|nm| {
                let (var, l) = bracket_slot(nm);
                let t = match var.as_str() {
                    "u" => 0,
                    "v" => 1,
                    _ => 2,
                };
                (t, l - 1)
            })
            .collect();
        let sorted = z.windows(2).all(|w| w[0] <= w[1]);
        HandBracket {
            z,
            tables: [u, v, th],
            zq,
            slots,
            sorted,
        }
    }

    fn call(&self, state: &[f64], t: f64, dy: &mut [f64]) {
        let n = self.z.len();
        let shift = 150.0 * (0.3 * t).sin();
        for (p, &(tab, l)) in self.slots.iter().enumerate() {
            let x = self.zq[l] + shift;
            let z = &self.z;
            let table = &self.tables[tab];
            let below = if self.sorted {
                z.partition_point(|&a| a <= x)
            } else {
                z.iter().filter(|&&a| a <= x).count()
            };
            let i = below.clamp(1, n - 1) - 1;
            let look = if x <= z[0] {
                table[0]
            } else if x >= z[n - 1] {
                table[n - 1]
            } else {
                let w = (x - z[i]) / (z[i + 1] - z[i]);
                table[i] + w * (table[i + 1] - table[i])
            };
            dy[p] = 0.5 * (look - state[p]);
        }
    }
}

fn benchmark_interp_bracket(c: &mut Criterion) {
    let mut group = c.benchmark_group("interp_bracket");
    for n in [59usize, 200] {
        let docs = [
            (
                "fn_const",
                format!("interp_bracket_const_fn_N{n}.esm"),
                true,
            ),
            (
                "compose_const_fused",
                format!("interp_bracket_const_compose_N{n}.esm"),
                true,
            ),
            (
                "compose_const_unfused",
                format!("interp_bracket_const_compose_N{n}.esm"),
                false,
            ),
            (
                "compose_runtime_fused",
                format!("interp_bracket_runtime_compose_N{n}.esm"),
                true,
            ),
            (
                "compose_runtime_unfused",
                format!("interp_bracket_runtime_compose_N{n}.esm"),
                false,
            ),
        ];
        // Every spelling, and the hand loop, writes the same bits.
        let mut reference: Option<Vec<u64>> = None;
        let mut built = Vec::new();
        for (label, doc, fused) in docs {
            let mut rhs = BracketRhs::new(&doc, fused);
            let mut dy = vec![0.0; rhs.state.len()];
            rhs.call(&mut dy);
            let bits: Vec<u64> = dy.iter().map(|x| x.to_bits()).collect();
            match &reference {
                None => reference = Some(bits),
                Some(r) => assert_eq!(r, &bits, "N={n} {label}: not the interp.linear derivative"),
            }
            built.push((label, rhs));
        }
        let names = built[0]
            .1
            .prob
            .debug_array_compiled()
            .expect("a right-hand side")
            .state_variable_names()
            .to_vec();
        let hand = HandBracket::new(n, &names, 100.0);
        let state = built[0].1.state.clone();
        let mut dy = vec![0.0; state.len()];
        hand.call(&state, BRACKET_T, &mut dy);
        let bits: Vec<u64> = dy.iter().map(|x| x.to_bits()).collect();
        assert_eq!(reference.as_ref(), Some(&bits), "N={n}: the hand loop");

        for (label, rhs) in built.iter_mut() {
            let mut dy = vec![0.0; rhs.state.len()];
            group.bench_function(BenchmarkId::new(*label, n), |b| {
                b.iter(|| {
                    rhs.call(&mut dy);
                    black_box(&dy);
                })
            });
        }
        group.bench_function(BenchmarkId::new("hand_search", n), |b| {
            b.iter(|| {
                hand.call(black_box(&state), BRACKET_T, &mut dy);
                black_box(&dy);
            })
        });
    }
    group.finish();
}

// ---------------------------------------------------------------------------
// Standard-library templates against the closed forms they replace
// (bench/closed_templates: calendar, geometry, relational).
// ---------------------------------------------------------------------------

/// One right-hand side of a `bench/closed_templates` document under `native`
/// (or the per-cell oracle), with what it cost to get there.
struct TemplateRhs {
    prob: earthsci_ast::EsmProblem,
    scratch: earthsci_ast::simulate_array::RhsScratch,
    params: Vec<f64>,
    state: Vec<f64>,
    /// Problem construction plus tape installation, and the first call.
    build_s: f64,
    first_call_s: f64,
}

/// The time the steady calls are made at.
const TEMPLATE_T: f64 = 1.3;

impl TemplateRhs {
    fn new(path: &std::path::Path, oracle: bool) -> TemplateRhs {
        let t0 = std::time::Instant::now();
        let prob = earthsci_ast::esm_problem(
            path,
            (0.0, 1.0),
            earthsci_ast::ProblemOptions {
                compiler: Some(earthsci_ast::Compiler::Native),
                rhs: earthsci_ast::Rhs::Always,
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        let compiled = prob.debug_array_compiled().expect("a right-hand side");
        let mut scratch = if oracle {
            compiled.debug_new_scratch()
        } else {
            compiled.debug_new_scratch_taped().expect("taped")
        };
        let params = compiled.debug_resolve_params(prob.p());
        // A state that differs from cell to cell, the same per name in every
        // spelling, so a regrid's derivative depends on every weight.
        let names = compiled.state_variable_names();
        let mut sorted: Vec<&String> = names.iter().collect();
        sorted.sort();
        let rank: HashMap<&String, usize> = sorted
            .iter()
            .enumerate()
            .map(|(r, n)| (*n, r + 1))
            .collect();
        let state: Vec<f64> = names
            .iter()
            .map(|n| prob.u0().get(n).copied().unwrap_or(0.0) + rank[n] as f64 / 64.0)
            .collect();
        let build_s = t0.elapsed().as_secs_f64();
        let mut dy = vec![0.0; state.len()];
        let t1 = std::time::Instant::now();
        compiled.debug_eval_rhs_into(
            &state,
            0.0,
            &params,
            &mut dy,
            &mut scratch,
            &mut earthsci_ast::simulate_array::RhsStats::default(),
        );
        let first_call_s = t1.elapsed().as_secs_f64();
        TemplateRhs {
            prob,
            scratch,
            params,
            state,
            build_s,
            first_call_s,
        }
    }

    fn call(&mut self, t: f64, dy: &mut [f64]) {
        let compiled = self.prob.debug_array_compiled().expect("a right-hand side");
        compiled.debug_eval_rhs_into(
            &self.state,
            t,
            &self.params,
            dy,
            &mut self.scratch,
            &mut earthsci_ast::simulate_array::RhsStats::default(),
        );
    }

    /// `dy` at a few times, as bits.
    fn bits(&mut self) -> Vec<u64> {
        let mut dy = vec![0.0; self.state.len()];
        let mut out = Vec::new();
        for t in [0.0, 0.7, 3.1, 1800.0] {
            self.call(t, &mut dy);
            out.extend(dy.iter().map(|x| x.to_bits()));
        }
        out
    }
}

/// Each template document of `CLOSED_TEMPLATES_DIR` (default
/// `bench/closed_templates`) beside the closed-form document it mirrors, by
/// file name: `*_fn_*` / `*_leaf_*` / `*_op_*` against `*_tpl_*`.
/// `CLOSED_TEMPLATES_FILTER` keeps the names containing it.
fn closed_template_pairs() -> Vec<(String, std::path::PathBuf, std::path::PathBuf)> {
    let dir = std::env::var("CLOSED_TEMPLATES_DIR").map_or_else(
        |_| std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../bench/closed_templates"),
        std::path::PathBuf::from,
    );
    let filter = std::env::var("CLOSED_TEMPLATES_FILTER").unwrap_or_default();
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok()?.file_name().into_string().ok())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    let mut pairs = Vec::new();
    for name in names {
        for form in ["_fn_", "_leaf_", "_op_"] {
            if name.ends_with(".esm") && name.contains(form) && name.contains(&filter) {
                let tpl = name.replacen(form, "_tpl_", 1);
                if dir.join(&tpl).exists() {
                    pairs.push((
                        form.trim_matches('_').to_string(),
                        dir.join(&name),
                        dir.join(tpl),
                    ));
                }
            }
        }
    }
    pairs
}

fn benchmark_closed_templates(c: &mut Criterion) {
    let mut group = c.benchmark_group("closed_templates");
    group.sample_size(20);
    let nan_eq = |a: &[u64], b: &[u64]| {
        a.len() == b.len()
            && a.iter().zip(b).all(|(x, y)| {
                x == y || (f64::from_bits(*x).is_nan() && f64::from_bits(*y).is_nan())
            })
    };
    for (form, closed_path, tpl_path) in closed_template_pairs() {
        let stem = tpl_path
            .file_stem()
            .unwrap()
            .to_string_lossy()
            .replace("_tpl", "");
        let mut closed = TemplateRhs::new(&closed_path, false);
        let mut tpl = TemplateRhs::new(&tpl_path, false);
        let (cb, tb) = (closed.bits(), tpl.bits());
        // The per-cell oracle is slow on the large workloads:
        // `CLOSED_TEMPLATES_ORACLE=0` skips it.
        if std::env::var("CLOSED_TEMPLATES_ORACLE").map_or(true, |v| v != "0") {
            let mut oracle = TemplateRhs::new(&tpl_path, true);
            assert!(
                nan_eq(&tb, &oracle.bits()),
                "{stem}: the template's native derivative is not the oracle's"
            );
        }
        let versus = if form == "leaf" {
            let d = cb
                .iter()
                .zip(&tb)
                .map(|(a, b)| (f64::from_bits(*a) - f64::from_bits(*b)).abs())
                .fold(0.0f64, f64::max);
            format!("max |template - leaf| {d:.3e}")
        } else {
            format!("bit-identical to {form}: {}", nan_eq(&cb, &tb))
        };
        eprintln!(
            "{stem}: states {}  build {form} {:.4}s tpl {:.4}s  first call {form} {:.6}s tpl {:.6}s  {versus}",
            closed.state.len(),
            closed.build_s,
            tpl.build_s,
            closed.first_call_s,
            tpl.first_call_s
        );
        for (label, rhs) in [(form.as_str(), &mut closed), ("tpl", &mut tpl)] {
            let mut dy = vec![0.0; rhs.state.len()];
            let mut k = 0u64;
            group.bench_function(BenchmarkId::new(label, &stem), |b| {
                b.iter(|| {
                    k += 1;
                    rhs.call(TEMPLATE_T + 1.0e-3 * (k % 1000) as f64, &mut dy);
                    black_box(&dy);
                })
            });
        }
    }
    group.finish();
}

// ---------------------------------------------------------------------------
// Templates applied elementwise over array arguments (esm-spec §9.6.11,
// bench/template_array_args): the `fn` form, the template form the build
// lifts per cell, and the per-cell `faq` written by hand.
// ---------------------------------------------------------------------------

/// Each `*_fn_*` document of `TEMPLATE_ARRAY_ARGS_DIR` with its `*_tpl_*` and
/// `*_faq_*` spellings. `TEMPLATE_ARRAY_ARGS_FILTER` keeps the names containing
/// it. The documents are not committed: with `TEMPLATE_ARRAY_ARGS_DIR` unset,
/// `bench/template_array_args/generate.py` writes its default set into
/// `template_array_args` under the temporary directory first.
fn template_array_args_triples() -> Vec<(String, [std::path::PathBuf; 3])> {
    let dir = std::env::var("TEMPLATE_ARRAY_ARGS_DIR").map_or_else(
        |_| {
            let script = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../bench/template_array_args/generate.py");
            let dir = std::env::temp_dir().join("template_array_args");
            let status = std::process::Command::new("python3")
                .arg(&script)
                .arg("--out")
                .arg(&dir)
                .status();
            assert!(
                status.is_ok_and(|s| s.success()),
                "python3 {} --out {} failed",
                script.display(),
                dir.display()
            );
            dir
        },
        std::path::PathBuf::from,
    );
    let filter = std::env::var("TEMPLATE_ARRAY_ARGS_FILTER").unwrap_or_default();
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok()?.file_name().into_string().ok())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    let mut out = Vec::new();
    for name in names {
        if !(name.ends_with(".esm") && name.contains("_fn_") && name.contains(&filter)) {
            continue;
        }
        let tpl = dir.join(name.replacen("_fn_", "_tpl_", 1));
        let faq = dir.join(name.replacen("_fn_", "_faq_", 1));
        if tpl.exists() && faq.exists() {
            let stem = name.trim_end_matches(".esm").replacen("_fn", "", 1);
            out.push((stem, [dir.join(&name), tpl, faq]));
        }
    }
    out
}

fn benchmark_template_array_args(c: &mut Criterion) {
    let mut group = c.benchmark_group("template_array_args");
    group.sample_size(20);
    for (stem, paths) in template_array_args_triples() {
        let mut rhs: Vec<TemplateRhs> = paths.iter().map(|p| TemplateRhs::new(p, false)).collect();
        let bits: Vec<Vec<u64>> = rhs.iter_mut().map(|r| r.bits()).collect();
        // The lift is the hand-written per-cell faq: the same bits, always.
        assert_eq!(
            bits[1], bits[2],
            "{stem}: the lifted template is not the per-cell faq"
        );
        eprintln!(
            "{stem}: states {}  build fn {:.4}s tpl {:.4}s faq {:.4}s  first call fn {:.6}s tpl {:.6}s faq {:.6}s  template bit-identical to fn: {}",
            rhs[0].state.len(),
            rhs[0].build_s,
            rhs[1].build_s,
            rhs[2].build_s,
            rhs[0].first_call_s,
            rhs[1].first_call_s,
            rhs[2].first_call_s,
            bits[0] == bits[1]
        );
        for (label, r) in ["fn", "tpl", "faq"].into_iter().zip(rhs.iter_mut()) {
            let mut dy = vec![0.0; r.state.len()];
            let mut k = 0u64;
            group.bench_function(BenchmarkId::new(label, &stem), |b| {
                b.iter(|| {
                    k += 1;
                    r.call(TEMPLATE_T + 1.0e-3 * (k % 1000) as f64, &mut dy);
                    black_box(&dy);
                })
            });
        }
    }
    group.finish();
}

// Define benchmark groups
criterion_group!(
    benches,
    benchmark_parsing,
    benchmark_validation,
    benchmark_stoichiometric_matrix,
    benchmark_expression_evaluation,
    benchmark_interp_bracket,
    benchmark_closed_templates,
    benchmark_template_array_args,
);

#[cfg(feature = "simd")]
criterion_group!(simd_benches, benchmark_simd_operations);

#[cfg(feature = "custom_alloc")]
criterion_group!(alloc_benches, benchmark_memory_allocation);

#[cfg(all(feature = "simd", feature = "custom_alloc"))]
criterion_main!(benches, simd_benches, alloc_benches);

#[cfg(all(feature = "simd", not(feature = "custom_alloc")))]
criterion_main!(benches, simd_benches);

#[cfg(all(not(feature = "simd"), feature = "custom_alloc"))]
criterion_main!(benches, alloc_benches);

#[cfg(all(not(feature = "simd"), not(feature = "custom_alloc")))]
criterion_main!(benches);
