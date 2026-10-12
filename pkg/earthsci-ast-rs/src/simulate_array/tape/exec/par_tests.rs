//! Serial and split calls are bit-identical: every scaling-tier fixture,
//! evaluated with its calls split 2, 3, 4 and 7 wide (forced, whatever the
//! size), must reproduce the serial call's `dy` to the bit.

use super::super::taped;
use super::par::force_split;
use super::pool::DISPATCHES;
use crate::{Compiler, ProblemOptions, Rhs, esm_problem};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;

fn fixtures() -> Vec<PathBuf> {
    let root =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/scaling/fixtures");
    let mut out = Vec::new();
    for fam in std::fs::read_dir(&root).expect("the scaling fixtures") {
        let fam = fam.unwrap().path();
        if fam.is_dir() {
            for doc in std::fs::read_dir(&fam).unwrap() {
                let doc = doc.unwrap().path();
                if doc.extension().is_some_and(|e| e == "esm") {
                    out.push(doc);
                }
            }
        }
    }
    out.sort();
    assert!(
        out.len() >= 20,
        "expected the scaling fixtures, found {out:?}"
    );
    out
}

/// `dy` at a non-trivial state, through the production (taped) scratch,
/// twice (the second call is a steady one: primed sections, warm workers).
fn rhs(path: &Path, ways: Option<usize>) -> Vec<f64> {
    let opts = ProblemOptions {
        compiler: Some(Compiler::Native),
        rhs: Rhs::Always,
        ..Default::default()
    };
    let prob =
        esm_problem(path, (0.0, 1.0), opts).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let c = prob.debug_array_compiled().expect("a right-hand side");
    let n = c.state_variable_names().len();
    let state: Vec<f64> = (0..n)
        .map(|k| 1.0 + 0.1 * ((k as f64) * 0.37).sin())
        .collect();
    let params = c.debug_resolve_params(&HashMap::new());
    let mut scratch = c.debug_new_scratch_taped();
    let mut stats = crate::simulate_array::RhsStats::default();
    let mut dy = vec![0.0; n];
    force_split(ways);
    c.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
    let first = dy.clone();
    c.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
    force_split(None);
    assert!(
        first
            .iter()
            .zip(&dy)
            .all(|(a, b)| a.to_bits() == b.to_bits()),
        "{}: steady call differs from the first",
        path.display()
    );
    dy
}

#[test]
fn split_calls_are_bit_identical_to_serial() {
    for path in fixtures() {
        let serial = rhs(&path, Some(1));
        for ways in [2, 3, 4, 7] {
            let before = DISPATCHES.load(Ordering::Relaxed);
            let split = rhs(&path, Some(ways));
            assert!(
                DISPATCHES.load(Ordering::Relaxed) > before,
                "{}: nothing split {ways} wide",
                path.display()
            );
            for (k, (a, b)) in serial.iter().zip(&split).enumerate() {
                assert_eq!(
                    a.to_bits(),
                    b.to_bits(),
                    "{}: dy[{k}] split {ways} wide is {b:?}, serial {a:?}",
                    path.display()
                );
            }
        }
    }
}

/// The scaling regrid's apply — the gather of the source field at each
/// admitted pair, the product with its weight, the segmented sum and the
/// fused group over the target cells — is one chain, so a threaded steady
/// call splits it in one dispatch.
#[test]
fn the_regrid_apply_is_one_split_chain() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/scaling/fixtures/regrid/regrid_N100.esm");
    let text = std::fs::read_to_string(&path).expect("scaling fixture reads");
    let doc: serde_json::Value = serde_json::from_str(&text).expect("scaling fixture parses");
    let compiled = crate::simulate_array::tape::tests::compile(doc);
    let (prog, _) = taped(compiled.build_tape(&std::collections::HashSet::new()));
    let exec = super::TapeExec::new(&prog);
    assert_eq!(exec.seg_chains.len(), 1, "one chain");
    let ch = &exec.seg_chains[0];
    assert!(ch.fused.is_some(), "the target cells' fused group joins it");
    assert!(ch.start < ch.seg, "the pair gather and product join it");

    let opts = ProblemOptions {
        compiler: Some(Compiler::Native),
        rhs: Rhs::Always,
        ..Default::default()
    };
    let prob = esm_problem(path.as_path(), (0.0, 1.0), opts).expect("regrid builds");
    let c = prob.debug_array_compiled().expect("a right-hand side");
    let n = c.state_variable_names().len();
    let state: Vec<f64> = (0..n).map(|k| 1.0 + 0.1 * (k as f64).sin()).collect();
    let params = c.debug_resolve_params(&HashMap::new());
    let mut scratch = c.debug_new_scratch_taped();
    let mut stats = crate::simulate_array::RhsStats::default();
    let mut dy = vec![0.0; n];
    force_split(Some(4));
    c.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
    // The counter is process-wide and other tests split too: the fewest
    // dispatches any of a few steady calls saw is this call's own count.
    let steady = (0..10)
        .map(|_| {
            let before = DISPATCHES.load(Ordering::Relaxed);
            c.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
            DISPATCHES.load(Ordering::Relaxed) - before
        })
        .min();
    force_split(None);
    assert_eq!(steady, Some(1), "one dispatch per steady call");
}

/// The regrid's mask (`A_ij > atol`) and weights come from the CONST
/// section, so its chain folds only the admitted pairs, from a table rebuilt
/// at each prime. A parameter change that admits fewer pairs re-primes the
/// same scratch and rebuilds it: serial and split, every call matches the
/// per-cell oracle to the bit.
#[test]
fn the_regrid_chain_folds_only_admitted_pairs() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/scaling/fixtures/regrid/regrid_N100.esm");
    let text = std::fs::read_to_string(&path).expect("scaling fixture reads");
    let doc: serde_json::Value = serde_json::from_str(&text).expect("scaling fixture parses");
    let compiled = crate::simulate_array::tape::tests::compile(doc);
    let (prog, _) = compiled.build_tape(&std::collections::HashSet::new());
    let exec = super::TapeExec::new(&prog);
    assert!(
        exec.seg_chains[0].compact.is_some_and(|p| p.w.is_some()),
        "the regrid chain compacts its pairs and weights"
    );

    let opts = ProblemOptions {
        compiler: Some(Compiler::Native),
        rhs: Rhs::Always,
        ..Default::default()
    };
    let prob = esm_problem(path.as_path(), (0.0, 1.0), opts).expect("regrid builds");
    let c = prob.debug_array_compiled().expect("a right-hand side");
    let n = c.state_variable_names().len();
    let state: Vec<f64> = (0..n).map(|k| 1.0 + 0.1 * (k as f64).sin()).collect();
    let atol = c
        .parameter_names()
        .iter()
        .find(|p| p.ends_with("atol"))
        .expect("an atol parameter")
        .clone();
    for ways in [1, 3] {
        let mut scratch = c.debug_new_scratch_taped();
        let mut stats = crate::simulate_array::RhsStats::default();
        let mut dy = vec![0.0; n];
        // Target strips overlap their sources by 1.0 or 0.5: an atol of 0.6
        // drops every half overlap; going back re-admits them.
        for a in [1e-12, 0.6, 1e-12] {
            let p: HashMap<String, f64> = [(atol.clone(), a)].into_iter().collect();
            let (oracle, _) = c.debug_eval_rhs(&state, 0.0, &p, true);
            let params = c.debug_resolve_params(&p);
            force_split(Some(ways));
            for _ in 0..2 {
                c.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
                for (k, (x, y)) in oracle.iter().zip(&dy).enumerate() {
                    assert_eq!(
                        x.to_bits(),
                        y.to_bits(),
                        "atol {a}, {ways} wide: dy[{k}] is {y:?}, the oracle {x:?}"
                    );
                }
            }
            force_split(None);
        }
    }
}
