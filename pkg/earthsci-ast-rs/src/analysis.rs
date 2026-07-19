//! Pure structural/expression analysis helpers used by the `esm` CLI.
//!
//! These are the I/O-free analysis primitives that previously lived inline in
//! `src/bin/esm.rs`: expression metrics (depth, node/operation counts),
//! structural/numerical expression comparison, unit collection, and the graph
//! algorithms (Tarjan strongly-connected-components and the longest dependency
//! chain). Moving them into the library makes them unit-testable independently
//! of the command-line front end; the CLI's printing routines call into these.

use crate::graph::ComponentGraph;
use crate::{EsmFile, Expr};
use std::collections::HashSet;

/// Collect the distinct unit strings declared across all model variables and
/// reaction-system species, sorted for stable output.
pub fn collect_unit_types(esm_file: &EsmFile) -> Vec<String> {
    let mut units = HashSet::new();

    if let Some(ref models) = esm_file.models {
        for model in models.values() {
            for var in model.variables.values() {
                if let Some(ref unit_str) = var.units {
                    units.insert(unit_str.clone());
                }
            }
        }
    }

    if let Some(ref reaction_systems) = esm_file.reaction_systems {
        for rs in reaction_systems.values() {
            for species in rs.species.values() {
                if let Some(ref unit_str) = species.units {
                    units.insert(unit_str.clone());
                }
            }
        }
    }

    let mut unit_list: Vec<String> = units.into_iter().collect();
    unit_list.sort();
    unit_list
}

/// Maximum nesting depth of an expression tree (a leaf has depth 1).
pub fn expression_depth(expr: &Expr) -> usize {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => 1,
        Expr::Operator(node) => 1 + node.args.iter().map(expression_depth).max().unwrap_or(0),
    }
}

/// Total number of AST nodes in an expression tree.
pub fn count_expression_nodes(expr: &Expr) -> usize {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => 1,
        Expr::Operator(node) => 1 + node.args.iter().map(count_expression_nodes).sum::<usize>(),
    }
}

/// Heuristic detection of no-op arithmetic (x+0, x*1, x^1, …) anywhere in the
/// tree.
pub fn contains_redundant_operations(expr: &Expr) -> bool {
    match expr {
        Expr::Operator(node) => {
            // Check for operations like x + 0, x * 1, x^1, etc.
            match node.op.as_str() {
                "+" | "-" => node.args.iter().any(|arg| {
                    if let Expr::Number(n) = arg {
                        *n == 0.0
                    } else {
                        false
                    }
                }),
                "*" | "/" => node.args.iter().any(|arg| {
                    if let Expr::Number(n) = arg {
                        *n == 1.0
                    } else {
                        false
                    }
                }),
                "^" => {
                    if node.args.len() >= 2 {
                        if let Expr::Number(n) = &node.args[1] {
                            *n == 1.0
                        } else {
                            false
                        }
                    } else {
                        false
                    }
                }
                _ => node.args.iter().any(contains_redundant_operations),
            }
        }
        _ => false,
    }
}

/// Heuristic: does a non-trivial subexpression appear on both sides of an
/// equation (a candidate for common-subexpression elimination)?
pub fn contains_common_subexpressions(lhs: &Expr, rhs: &Expr) -> bool {
    let mut lhs_subexprs = Vec::new();
    let mut rhs_subexprs = Vec::new();

    collect_subexpressions(lhs, &mut lhs_subexprs);
    collect_subexpressions(rhs, &mut rhs_subexprs);

    // Simple heuristic: check if any complex subexpressions appear in both sides
    lhs_subexprs.iter().any(|lhs_expr| {
        if expression_depth(lhs_expr) > 2 {
            rhs_subexprs
                .iter()
                .any(|rhs_expr| expressions_equal(lhs_expr, rhs_expr))
        } else {
            false
        }
    })
}

/// Push every node of `expr` (including `expr` itself) into `subexprs`.
pub fn collect_subexpressions(expr: &Expr, subexprs: &mut Vec<Expr>) {
    subexprs.push(expr.clone());
    if let Expr::Operator(node) = expr {
        for arg in &node.args {
            collect_subexpressions(arg, subexprs);
        }
    }
}

/// Structural (exact) equality of two expressions; numbers compare within a
/// tiny tolerance.
pub fn expressions_equal(expr1: &Expr, expr2: &Expr) -> bool {
    match (expr1, expr2) {
        (Expr::Number(n1), Expr::Number(n2)) => (n1 - n2).abs() < 1e-10,
        (Expr::Variable(v1), Expr::Variable(v2)) => v1 == v2,
        (Expr::Operator(op1), Expr::Operator(op2)) => {
            op1.op == op2.op
                && op1.args.len() == op2.args.len()
                && op1
                    .args
                    .iter()
                    .zip(op2.args.iter())
                    .all(|(a1, a2)| expressions_equal(a1, a2))
        }
        _ => false,
    }
}

/// Collect the set of variable names referenced anywhere in `expr`.
pub fn collect_variables(expr: &Expr, vars: &mut HashSet<String>) {
    match expr {
        Expr::Variable(name) => {
            vars.insert(name.clone());
        }
        Expr::Operator(node) => {
            for arg in &node.args {
                collect_variables(arg, vars);
            }
        }
        Expr::Number(_) | Expr::Integer(_) => {}
    }
}

/// Count operator applications in an expression (leaves contribute zero).
pub fn count_operations(expr: &Expr) -> usize {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => 0,
        Expr::Operator(node) => 1 + node.args.iter().map(count_operations).sum::<usize>(),
    }
}

/// Does the expression contain a transcendental / power operation (a rough
/// proxy for compute cost)?
pub fn contains_expensive_operations(expr: &Expr) -> bool {
    match expr {
        Expr::Operator(node) => match node.op.as_str() {
            "exp" | "log" | "sin" | "cos" | "tan" | "sqrt" | "^" => true,
            _ => node.args.iter().any(contains_expensive_operations),
        },
        _ => false,
    }
}

/// Structural equality of two expressions where numeric leaves compare within
/// `tolerance`.
pub fn expressions_numerically_equal(expr1: &Expr, expr2: &Expr, tolerance: f64) -> bool {
    match (expr1, expr2) {
        (Expr::Number(n1), Expr::Number(n2)) => (n1 - n2).abs() <= tolerance,
        (Expr::Variable(v1), Expr::Variable(v2)) => v1 == v2,
        (Expr::Operator(op1), Expr::Operator(op2)) => {
            op1.op == op2.op
                && op1.args.len() == op2.args.len()
                && op1
                    .args
                    .iter()
                    .zip(op2.args.iter())
                    .all(|(a1, a2)| expressions_numerically_equal(a1, a2, tolerance))
        }
        _ => false,
    }
}

/// Count the numeric values present across a whole document: variable
/// defaults, reaction stoichiometry entries, and numeric literals in every
/// equation and rate expression.
pub fn count_numerical_values(esm_file: &EsmFile, count: &mut usize) {
    if let Some(ref models) = esm_file.models {
        for model in models.values() {
            // Count variable defaults
            for var in model.variables.values() {
                if var.default.is_some() {
                    *count += 1;
                }
            }

            // Count numbers in expressions
            for equation in &model.equations {
                count_numbers_in_expression(&equation.lhs, count);
                count_numbers_in_expression(&equation.rhs, count);
            }
        }
    }

    if let Some(ref reaction_systems) = esm_file.reaction_systems {
        for rs in reaction_systems.values() {
            for reaction in &rs.reactions {
                // Count coefficients (schema requires integer stoichiometry ≥ 1, so
                // every entry contributes one counted numeric value).
                *count += reaction.substrates.as_ref().map(|v| v.len()).unwrap_or(0);
                *count += reaction.products.as_ref().map(|v| v.len()).unwrap_or(0);

                // Count numbers in rate expressions
                count_numbers_in_expression(&reaction.rate, count);
            }
        }
    }
}

/// Count numeric literals in a single expression tree.
pub fn count_numbers_in_expression(expr: &Expr, count: &mut usize) {
    match expr {
        Expr::Number(_) | Expr::Integer(_) => *count += 1,
        Expr::Operator(node) => {
            for arg in &node.args {
                count_numbers_in_expression(arg, count);
            }
        }
        Expr::Variable(_) => {}
    }
}

/// Tarjan's strongly-connected-components algorithm (iterative) over the
/// component graph. A component is a genuine dependency cycle iff it has more
/// than one node, or one node with a self-edge — the caller applies that
/// filter.
pub fn find_strongly_connected_components(graph: &ComponentGraph) -> Vec<Vec<String>> {
    let ids: Vec<&String> = graph.nodes.iter().map(|n| &n.id).collect();
    let index_of: std::collections::HashMap<&str, usize> = ids
        .iter()
        .enumerate()
        .map(|(i, s)| (s.as_str(), i))
        .collect();
    let n = ids.len();
    let mut adj: Vec<Vec<usize>> = vec![Vec::new(); n];
    for edge in &graph.edges {
        if let (Some(&f), Some(&t)) = (
            index_of.get(edge.from.as_str()),
            index_of.get(edge.to.as_str()),
        ) {
            adj[f].push(t);
        }
    }

    const UNVISITED: usize = usize::MAX;
    let mut index = vec![UNVISITED; n];
    let mut low = vec![0usize; n];
    let mut on_stack = vec![false; n];
    let mut stack: Vec<usize> = Vec::new();
    let mut next_index = 0usize;
    let mut components: Vec<Vec<String>> = Vec::new();

    for root in 0..n {
        if index[root] != UNVISITED {
            continue;
        }
        // Explicit call stack of (node, next-child position) frames.
        let mut call: Vec<(usize, usize)> = vec![(root, 0)];
        while let Some(frame) = call.last_mut() {
            let (v, ci) = (frame.0, frame.1);
            if ci == 0 {
                index[v] = next_index;
                low[v] = next_index;
                next_index += 1;
                stack.push(v);
                on_stack[v] = true;
            }
            if ci < adj[v].len() {
                frame.1 += 1;
                let w = adj[v][ci];
                if index[w] == UNVISITED {
                    call.push((w, 0));
                } else if on_stack[w] {
                    low[v] = low[v].min(index[w]);
                }
            } else {
                call.pop();
                if let Some(parent) = call.last() {
                    let pv = parent.0;
                    low[pv] = low[pv].min(low[v]);
                }
                if low[v] == index[v] {
                    let mut component = Vec::new();
                    loop {
                        let w = stack.pop().expect("Tarjan stack tracks open nodes");
                        on_stack[w] = false;
                        component.push(ids[w].clone());
                        if w == v {
                            break;
                        }
                    }
                    components.push(component);
                }
            }
        }
    }

    components
}

/// Length (in nodes) of the longest acyclic dependency chain in the graph.
pub fn find_longest_dependency_chain(graph: &ComponentGraph) -> usize {
    let mut max_length = 0;

    // For each node, find the longest path starting from it
    for node in &graph.nodes {
        let mut visited = HashSet::new();
        let length = dfs_longest_path(graph, &node.id, &mut visited);
        max_length = max_length.max(length);
    }

    max_length
}

/// Depth-first longest simple path starting at `node_id` (revisits are pruned
/// via `visited`, so cycles do not diverge).
pub fn dfs_longest_path(graph: &ComponentGraph, node_id: &str, visited: &mut HashSet<String>) -> usize {
    if visited.contains(node_id) {
        return 0; // Avoid cycles
    }

    visited.insert(node_id.to_string());
    let mut max_path = 1;

    // Find all outgoing edges
    for edge in &graph.edges {
        if edge.from == node_id {
            let path_length = 1 + dfs_longest_path(graph, &edge.to, visited);
            max_path = max_path.max(path_length);
        }
    }

    visited.remove(node_id);
    max_path
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::{ComponentGraph, ComponentNode, ComponentType, CouplingEdge};
    use crate::graph::CouplingEdgeKind;

    fn node(id: &str) -> ComponentNode {
        ComponentNode {
            id: id.to_string(),
            component_type: ComponentType::Model,
            name: None,
        }
    }

    fn edge(from: &str, to: &str) -> CouplingEdge {
        CouplingEdge {
            from: from.to_string(),
            to: to.to_string(),
            coupling_type: CouplingEdgeKind::VariableMap,
            data: serde_json::Value::Null,
        }
    }

    /// A 3-cycle A->B->C->A collapses to a single SCC of size 3; an isolated
    /// node D is its own SCC of size 1.
    #[test]
    fn scc_finds_cycles_and_singletons() {
        let graph = ComponentGraph {
            nodes: vec![node("A"), node("B"), node("C"), node("D")],
            edges: vec![edge("A", "B"), edge("B", "C"), edge("C", "A")],
        };
        let sccs = find_strongly_connected_components(&graph);

        // Exactly one component has size 3 (the cycle) and one has size 1 (D).
        let sizes: Vec<usize> = {
            let mut s: Vec<usize> = sccs.iter().map(|c| c.len()).collect();
            s.sort_unstable();
            s
        };
        assert_eq!(sizes, vec![1, 3]);

        let cycle = sccs.iter().find(|c| c.len() == 3).expect("cycle SCC exists");
        let mut members: Vec<&str> = cycle.iter().map(|s| s.as_str()).collect();
        members.sort_unstable();
        assert_eq!(members, vec!["A", "B", "C"]);

        let singleton = sccs.iter().find(|c| c.len() == 1).expect("singleton exists");
        assert_eq!(singleton[0], "D");
    }

    /// A pure DAG A->B->C has no non-trivial SCCs: every component is size 1.
    #[test]
    fn scc_dag_has_only_singletons() {
        let graph = ComponentGraph {
            nodes: vec![node("A"), node("B"), node("C")],
            edges: vec![edge("A", "B"), edge("B", "C")],
        };
        let sccs = find_strongly_connected_components(&graph);
        assert_eq!(sccs.len(), 3);
        assert!(sccs.iter().all(|c| c.len() == 1));
    }

    /// The longest chain in A->B->C->D is 4 nodes; a cycle does not diverge and
    /// is bounded by the node count.
    #[test]
    fn longest_chain_counts_nodes() {
        let dag = ComponentGraph {
            nodes: vec![node("A"), node("B"), node("C"), node("D")],
            edges: vec![edge("A", "B"), edge("B", "C"), edge("C", "D")],
        };
        assert_eq!(find_longest_dependency_chain(&dag), 4);

        let cyclic = ComponentGraph {
            nodes: vec![node("A"), node("B"), node("C")],
            edges: vec![edge("A", "B"), edge("B", "C"), edge("C", "A")],
        };
        // Bounded by the 3 distinct nodes; never diverges on the cycle.
        assert_eq!(find_longest_dependency_chain(&cyclic), 3);
    }

    #[test]
    fn expression_metrics() {
        // (x + 1) * 2  →  depth 3, an operator tally of 2, five total nodes.
        let expr: Expr = serde_json::from_value(serde_json::json!({
            "op": "*",
            "args": [
                { "op": "+", "args": ["x", 1.0] },
                2.0
            ]
        }))
        .expect("valid expression JSON");
        assert_eq!(expression_depth(&expr), 3);
        assert_eq!(count_operations(&expr), 2);
        assert_eq!(count_expression_nodes(&expr), 5);

        let mut vars = HashSet::new();
        collect_variables(&expr, &mut vars);
        assert_eq!(vars, HashSet::from(["x".to_string()]));

        let mut nums = 0usize;
        count_numbers_in_expression(&expr, &mut nums);
        assert_eq!(nums, 2);
    }
}
