//! Serial and split calls are bit-identical: every scaling-tier fixture,
//! evaluated with its calls split 2, 3, 4 and 7 wide (forced, whatever the
//! size), must reproduce the serial call's `dy` to the bit.

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
    let (prog, _) = compiled.build_tape(&std::collections::HashSet::new());
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
