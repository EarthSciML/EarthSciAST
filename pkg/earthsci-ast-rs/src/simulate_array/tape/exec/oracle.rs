//! The per-cell oracle for fallback RHS rules.
//!
//! Kept out of `interp` because it is shared: the test-only reference
//! executor runs the SAME function, so the two executors cannot drift on
//! the fallback arm.

use super::*;

// ---------------------------------------------------------------------------
// The per-cell oracle for fallback RHS rules — shared with the test-only
// reference executor. A transliteration of `evaluate_rhs_with_scratch`'s
// fallback arm (without the prefix-scan rewrite, which is documented and
// pinned bit-identical to this plain loop).
// ---------------------------------------------------------------------------

pub(in crate::simulate_array::tape) fn run_rhs_oracle<'e>(
    rule: &RhsRule,
    var_shapes: &IndexMap<String, VarShape>,
    env: &EvalEnv<'e>,
    observed_arrays: &'e ArrMap,
    dy: &mut [f64],
) {
    let mut ctx = env.ctx(observed_arrays);
    match rule {
        RhsRule::Scalar { slot, body } | RhsRule::IndexedScalar { slot, body } => {
            dy[*slot] = eval(body, &mut ctx).as_scalar().unwrap_or(f64::NAN);
        }
        RhsRule::ArrayLoop {
            var_name,
            output_idx_names,
            output_ranges,
            lhs_idx_exprs,
            body,
            contract_names,
            contract_dims,
            reduce,
            filter,
        } => {
            let vs = &var_shapes[var_name];
            let filter = filter.as_deref();
            let static_ranges = static_contract_ranges(contract_dims);
            let output_origin: Vec<i64> = output_ranges.iter().map(|(lo, _)| *lo).collect();
            let cellbox = CellBox {
                names: output_idx_names,
                origin: &output_origin,
            };
            let spec = ReduceSpec {
                contract_names,
                body,
                reduce: *reduce,
                filter,
                cell: Some(&cellbox),
            };
            let mut tuples = CartesianTuples::new(output_ranges);
            while let Some(tuple) = tuples.next() {
                for (name, val) in output_idx_names.iter().zip(tuple.iter()) {
                    set_bind(&mut ctx.loop_binds, name, *val);
                }
                let v =
                    reduce_contraction(&spec, contract_dims, static_ranges.as_deref(), &mut ctx);
                let actual_multi: Vec<i64> = lhs_idx_exprs
                    .iter()
                    .map(|e| eval_simple_index(e, &ctx.loop_binds))
                    .collect();
                let flat = multi_to_flat_col_major(&actual_multi, &vs.shape, &vs.origin);
                dy[vs.flat_offset + flat] = v;
            }
        }
    }
}
