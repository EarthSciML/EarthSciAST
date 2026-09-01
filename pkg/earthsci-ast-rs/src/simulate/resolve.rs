use super::*;

// ============================================================================
// Resolved expression: precomputed indices for the hot interpreter loop
// ============================================================================

/// Internal: an Expr with variable references replaced by typed integer
/// indices into the state / parameter / observed buffers.
#[derive(Debug, Clone)]
pub enum ResolvedExpr {
    /// Constant.
    Number(f64),
    /// `state[i]`
    State(usize),
    /// `param[i]`
    Param(usize),
    /// `observed[i]`
    Observed(usize),
    /// The independent variable `t`.
    Time,
    /// Operator node.
    Op {
        /// Operator name (string-tagged for v1; cheap to dispatch on).
        op: String,
        /// Resolved children.
        args: Vec<ResolvedExpr>,
    },
    /// Closed-registry function call (the `fn` op, esm-spec §9.2). Held as a
    /// distinct variant because — unlike a plain [`ResolvedExpr::Op`] — it
    /// carries the dotted function `name` and its arguments may be array
    /// literals (the `table` / `axis` of `interp.linear` / `interp.bilinear`),
    /// which the scalar `f64` interpreter otherwise has no way to represent.
    /// Array arguments are inline `const` literals, so they are materialized
    /// once at resolve time; scalar arguments stay as sub-expressions evaluated
    /// per call.
    Fn {
        /// Dotted module path of the registered function (e.g. `interp.linear`).
        name: String,
        /// Resolved arguments, each either a per-call scalar sub-expression or a
        /// materialized constant array.
        args: Vec<ResolvedFnArg>,
    },
}

/// One argument to a resolved [`ResolvedExpr::Fn`] call.
#[derive(Debug, Clone)]
pub enum ResolvedFnArg {
    /// A scalar argument, evaluated per call (e.g. the query point `x`, which
    /// may reference a parameter or state).
    Scalar(Box<ResolvedExpr>),
    /// A 1-D constant array argument (an inline `const` literal — e.g. the
    /// `table` or `axis` of `interp.linear`).
    Array(Vec<f64>),
    /// A 2-D constant array argument (the `table` of `interp.bilinear`).
    Array2D(Vec<Vec<f64>>),
}

// ============================================================================
// Name resolution and dependency ordering
// ============================================================================

/// Build a `name -> position` lookup from an ordered list of names.
pub(super) fn build_index_map(names: &[String]) -> HashMap<String, usize> {
    names
        .iter()
        .enumerate()
        .map(|(i, n)| (n.clone(), i))
        .collect()
}

/// Resolve an `Expr` against name -> index tables. If `obs_limit` is `Some(i)`,
/// observed-variable references must be to indices `< i` (forward-only
/// dependency check during topo-resolution of observed expressions).
pub(super) fn resolve_expr(
    expr: &Expr,
    state_index: &HashMap<String, usize>,
    param_index: &HashMap<String, usize>,
    observed_index: &HashMap<String, usize>,
    obs_limit: Option<usize>,
) -> Result<ResolvedExpr, CompileError> {
    match expr {
        Expr::Number(n) => Ok(ResolvedExpr::Number(*n)),
        Expr::Integer(n) => Ok(ResolvedExpr::Number(*n as f64)),
        Expr::Variable(name) => {
            if name == "t" {
                Ok(ResolvedExpr::Time)
            } else if let Some(&i) = state_index.get(name) {
                Ok(ResolvedExpr::State(i))
            } else if let Some(&i) = param_index.get(name) {
                Ok(ResolvedExpr::Param(i))
            } else if let Some(&i) = observed_index.get(name) {
                if let Some(limit) = obs_limit
                    && i >= limit
                {
                    return Err(CompileError::build_err(format!(
                        "Observed variable references not-yet-defined observed '{name}' \
                             (forward dependency)"
                    )));
                }
                Ok(ResolvedExpr::Observed(i))
            } else {
                Err(CompileError::build_err(format!(
                    "Unknown variable '{name}' referenced in expression"
                )))
            }
        }
        Expr::Operator(node) => {
            // Reject any operator that may not reach the evaluator, delegating
            // the tier decision wholesale to `op_registry` — the single source
            // of truth for the operator vocabulary (esm-spec §4.2 / §9.6.8) —
            // rather than a hand-maintained op-name list. A node it classifies
            // `Unlowered` is a rewrite target: the optional sugar ops
            // (`grad`/`div`/`laplacian`/`curl`/`∇`/`integral`), a SPATIAL `D`
            // (`wrt` != "t"), or ANY op not in the evaluable core — an
            // unregistered user discretization op is treated exactly like the
            // named sugar ops, with no privileged status. The structural time
            // derivative `D(_, t)` stays evaluable-core. A wrong arity or an
            // inverted `makearray` region is surfaced with its own diagnostic.
            // This mirrors the array path's `check_no_spatial_ops` gate.
            crate::op_registry::check_node(node).map_err(|e| match e {
                crate::op_registry::OpError::Unlowered { op } => {
                    CompileError::UnloweredOperatorError { op }
                }
                crate::op_registry::OpError::Arity { op, got, expected } => {
                    CompileError::InvalidOperatorArity { op, got, expected }
                }
                crate::op_registry::OpError::MakearrayRegion { reason } => {
                    CompileError::MakearrayRegionInvalid { reason }
                }
                crate::op_registry::OpError::BroadcastFn { reason, .. } => {
                    CompileError::InvalidBroadcastFn { reason }
                }
            })?;
            // Under `element_type: "Float32"` (esm-spec §11.3), reject the ops
            // whose numeric work happens outside the shared scalar kernels and
            // therefore cannot honour the declared precision. The array path
            // gates the same set through `check_evaluable`; this is the scalar
            // path's mirror, so neither can silently evaluate one in binary64.
            // A no-op under Float64.
            if let Some((construct, reason)) =
                crate::precision::is_f32()
                    .then(|| crate::precision::f32_unsupported_reason(&node.op, node.name.as_deref()))
                    .flatten()
            {
                return Err(CompileError::Float32Unsupported { construct, reason });
            }
            // Closed-registry function call (esm-spec §9.2): resolve to the
            // dedicated `Fn` variant so the callee `name` and any inline array
            // arguments survive to evaluation (a plain `Op` drops both — the
            // root cause of `fn` ops NaN-ing on the scalar path).
            if node.op == "fn" {
                let name =
                    node.name
                        .clone()
                        .ok_or_else(|| CompileError::InterpreterBuildError {
                            details: "`fn` op is missing its required `name` field".to_string(),
                        })?;
                let args = node
                    .args
                    .iter()
                    .map(|a| resolve_fn_arg(a, state_index, param_index, observed_index, obs_limit))
                    .collect::<Result<Vec<_>, _>>()?;
                return Ok(ResolvedExpr::Fn { name, args });
            }
            let args = node
                .args
                .iter()
                .map(|a| resolve_expr(a, state_index, param_index, observed_index, obs_limit))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(ResolvedExpr::Op {
                op: node.op.clone(),
                args,
            })
        }
    }
}

/// Resolve one argument of a `fn` op. An inline `const` literal whose value is
/// a JSON array is materialized to a constant [`ResolvedFnArg::Array`] /
/// [`ResolvedFnArg::Array2D`] (the `table` / `axis` operands of the `interp.*`
/// functions are always compile-time constants); every other argument — a
/// scalar `const`, a number, a variable, or a nested expression — resolves to a
/// per-call [`ResolvedFnArg::Scalar`] sub-expression.
fn resolve_fn_arg(
    expr: &Expr,
    state_index: &HashMap<String, usize>,
    param_index: &HashMap<String, usize>,
    observed_index: &HashMap<String, usize>,
    obs_limit: Option<usize>,
) -> Result<ResolvedFnArg, CompileError> {
    if let Expr::Operator(node) = expr
        && node.op == "const"
        && let Some(value) = &node.value
        && let Some(arg) = json_to_fn_array_arg(value)
    {
        return Ok(arg);
    }
    let resolved = resolve_expr(expr, state_index, param_index, observed_index, obs_limit)?;
    Ok(ResolvedFnArg::Scalar(Box::new(resolved)))
}

/// Materialize a `const`-op JSON value into an array `fn` argument. Returns
/// `Some(Array)` for a flat numeric list, `Some(Array2D)` for a list of
/// equal-length numeric rows, and `None` for a scalar number or any non-numeric
/// / ragged shape (a scalar `const` falls back to the per-call scalar path).
fn json_to_fn_array_arg(value: &serde_json::Value) -> Option<ResolvedFnArg> {
    let items = value.as_array()?;
    if items.iter().all(|it| it.is_array()) {
        // 2-D: every element is itself a numeric row.
        let rows: Option<Vec<Vec<f64>>> = items
            .iter()
            .map(|row| {
                row.as_array()?
                    .iter()
                    .map(|n| n.as_f64())
                    .collect::<Option<Vec<f64>>>()
            })
            .collect();
        rows.map(ResolvedFnArg::Array2D)
    } else {
        // 1-D: a flat numeric list.
        let flat: Option<Vec<f64>> = items.iter().map(|n| n.as_f64()).collect();
        flat.map(ResolvedFnArg::Array)
    }
}

/// Walk an expression and collect the indices of any observed variables it
/// references. Used by the topological sort.
pub(super) fn collect_observed_refs(
    expr: &Expr,
    observed_index: &HashMap<String, usize>,
    out: &mut HashSet<usize>,
) {
    match expr {
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Variable(name) => {
            if let Some(&i) = observed_index.get(name) {
                out.insert(i);
            }
        }
        Expr::Operator(node) => {
            for a in &node.args {
                collect_observed_refs(a, observed_index, out);
            }
        }
    }
}

/// Walk an expression and collect the indices of any *state* variables it
/// references whose state index is also a member of `members`. Used to build
/// the algebraic-state dependency graph for topo-sorting (esm-0kt).
pub(super) fn collect_state_refs(
    expr: &Expr,
    state_index: &HashMap<String, usize>,
    members: &HashSet<usize>,
    out: &mut HashSet<usize>,
) {
    match expr {
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Variable(name) => {
            if let Some(&i) = state_index.get(name)
                && members.contains(&i)
            {
                out.insert(i);
            }
        }
        Expr::Operator(node) => {
            for a in &node.args {
                collect_state_refs(a, state_index, members, out);
            }
        }
    }
}

/// Topologically sort a subset of node ids whose dependency edges live in a
/// dense `deps[id] -> set of dependency ids` array. Returns the subset in
/// dependency-respecting order. On a cycle, returns Err with the cycle path
/// for diagnostic naming.
pub(super) fn topo_sort_subset(
    members: &[usize],
    deps_dense: &[HashSet<usize>],
) -> Result<Vec<usize>, Vec<usize>> {
    let member_set: HashSet<usize> = members.iter().copied().collect();
    let mut order: Vec<usize> = Vec::with_capacity(members.len());
    let mut visited: HashSet<usize> = HashSet::new();
    let mut on_stack: HashSet<usize> = HashSet::new();
    let mut path: Vec<usize> = Vec::new();

    fn visit(
        i: usize,
        deps_dense: &[HashSet<usize>],
        member_set: &HashSet<usize>,
        visited: &mut HashSet<usize>,
        on_stack: &mut HashSet<usize>,
        path: &mut Vec<usize>,
        order: &mut Vec<usize>,
    ) -> Result<(), Vec<usize>> {
        if visited.contains(&i) {
            return Ok(());
        }
        if on_stack.contains(&i) {
            // Trim path back to the start of the cycle.
            let start = path.iter().position(|&x| x == i).unwrap_or(0);
            let mut cycle: Vec<usize> = path[start..].to_vec();
            cycle.push(i);
            return Err(cycle);
        }
        on_stack.insert(i);
        path.push(i);
        for &d in &deps_dense[i] {
            if member_set.contains(&d) {
                visit(d, deps_dense, member_set, visited, on_stack, path, order)?;
            }
        }
        path.pop();
        on_stack.remove(&i);
        visited.insert(i);
        order.push(i);
        Ok(())
    }

    for &i in members {
        visit(
            i,
            deps_dense,
            &member_set,
            &mut visited,
            &mut on_stack,
            &mut path,
            &mut order,
        )?;
    }
    Ok(order)
}

/// Topological sort over a per-node dependency set. Returns nodes in
/// dependency-respecting order (each node appears after its deps). On a
/// cycle, returns Err containing the (arbitrary) cycle node ids.
pub(super) fn topo_sort(deps: &[HashSet<usize>]) -> Result<Vec<usize>, Vec<usize>> {
    let n = deps.len();
    let mut order = Vec::with_capacity(n);
    let mut visited = vec![false; n];
    let mut on_stack = vec![false; n];

    fn visit(
        i: usize,
        deps: &[HashSet<usize>],
        visited: &mut [bool],
        on_stack: &mut [bool],
        order: &mut Vec<usize>,
    ) -> Result<(), Vec<usize>> {
        if visited[i] {
            return Ok(());
        }
        if on_stack[i] {
            return Err(vec![i]);
        }
        on_stack[i] = true;
        for &d in &deps[i] {
            visit(d, deps, visited, on_stack, order)?;
        }
        on_stack[i] = false;
        visited[i] = true;
        order.push(i);
        Ok(())
    }

    for i in 0..n {
        visit(i, deps, &mut visited, &mut on_stack, &mut order)?;
    }
    Ok(order)
}
