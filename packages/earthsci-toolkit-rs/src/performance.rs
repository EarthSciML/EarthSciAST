//! Experimental performance utilities (benchmark support).
//!
//! Opt-in via the `parallel` / `simd` / `zero_copy` / `custom_alloc` feature
//! flags (or `performance` for all four). NOTE: nothing in the production
//! simulate paths uses this module — `simulate` / `simulate_array` have their
//! own evaluators and deliberately use rustc-hash + reused scratch buffers
//! (see Cargo.toml). These utilities exist for the `benchmarks` bench target,
//! the feature-gated tests in `tests/performance.rs`, and downstream
//! experimentation:
//! - Zero-copy JSON parsing with simd-json (`fast_parse`)
//! - Parallel expression batch evaluation with rayon ([`ParallelEvaluator`])
//! - SIMD vector math (`simd_math`)
//! - A bump-allocator arena for large models ([`ModelAllocator`])
//! - A stack-based postfix expression evaluator ([`CompactExpr`])

use crate::{EsmFile, Expr};
use std::collections::HashMap;

#[cfg(feature = "zero_copy")]
use simd_json;

#[cfg(feature = "parallel")]
use rayon::prelude::*;

#[cfg(feature = "simd")]
use wide::f64x4;

#[cfg(feature = "custom_alloc")]
use bumpalo::Bump;

/// Error type for performance operations
#[derive(Debug, thiserror::Error)]
pub enum PerformanceError {
    /// JSON parsing failed (either backend of [`fast_parse`]).
    #[error("parse error: {0}")]
    ParseError(String),
    #[error("Parallel evaluation error: {0}")]
    ParallelError(String),
    /// Stack-machine evaluation failed ([`CompactExpr::evaluate_fast`]):
    /// operand underflow, unbound variable, division by zero, or an operator
    /// outside the compact instruction set.
    #[error("expression evaluation error: {0}")]
    EvalError(String),
    #[error("SIMD operation error: {0}")]
    SimdError(String),
    #[error("Memory allocation error: {0}")]
    AllocError(String),
}

/// JSON parser that uses simd-json when the `zero_copy` feature is enabled
/// and serde_json otherwise. One signature for both backends, so callers do
/// not need their own cfg fork (simd-json needs a mutable buffer, which this
/// function owns internally).
pub fn fast_parse(json_str: &str) -> Result<EsmFile, PerformanceError> {
    #[cfg(feature = "zero_copy")]
    {
        let mut bytes = json_str.as_bytes().to_vec();
        simd_json::serde::from_slice(&mut bytes)
            .map_err(|e| PerformanceError::ParseError(e.to_string()))
    }
    #[cfg(not(feature = "zero_copy"))]
    {
        serde_json::from_str(json_str).map_err(|e| PerformanceError::ParseError(e.to_string()))
    }
}

/// Parallel evaluation context for expressions
#[cfg(feature = "parallel")]
pub struct ParallelEvaluator {
    thread_pool: rayon::ThreadPool,
}

#[cfg(feature = "parallel")]
impl ParallelEvaluator {
    /// Create a new parallel evaluator with specified number of threads
    pub fn new(num_threads: Option<usize>) -> Result<Self, PerformanceError> {
        let pool = if let Some(n) = num_threads {
            rayon::ThreadPoolBuilder::new()
                .num_threads(n)
                .build()
                .map_err(|e| PerformanceError::ParallelError(e.to_string()))?
        } else {
            rayon::ThreadPoolBuilder::new()
                .build()
                .map_err(|e| PerformanceError::ParallelError(e.to_string()))?
        };

        Ok(Self { thread_pool: pool })
    }

    /// Evaluate multiple expressions in parallel
    pub fn evaluate_batch(
        &self,
        expressions: &[Expr],
        variables: &HashMap<String, f64>,
    ) -> Result<Vec<f64>, PerformanceError> {
        self.thread_pool.install(|| {
            expressions
                .par_iter()
                .map(|expr| {
                    crate::simulate::fold_constant_expr(expr, variables)
                        .map_err(|e| PerformanceError::ParallelError(format!("{e:?}")))
                })
                .collect()
        })
    }

    /// Parallel stoichiometric matrix computation
    pub fn compute_stoichiometric_matrix_parallel(
        &self,
        system: &crate::ReactionSystem,
    ) -> Result<Vec<Vec<f64>>, PerformanceError> {
        let num_species = system.species.len();
        let num_reactions = system.reactions.len();

        // Build a stable, sorted species ordering so indices are reproducible
        // and match `stoichiometric_matrix` in src/reactions.rs.
        let mut sorted_species_names: Vec<&String> = system.species.keys().collect();
        sorted_species_names.sort();
        let species_index: HashMap<String, usize> = sorted_species_names
            .iter()
            .enumerate()
            .map(|(idx, name)| ((*name).clone(), idx))
            .collect();

        self.thread_pool.install(|| {
            // Initialize matrix with parallel vectors
            let mut matrix: Vec<Vec<f64>> = (0..num_species)
                .into_par_iter()
                .map(|_| vec![0.0; num_reactions])
                .collect();

            // Process reactions in parallel
            let reaction_contributions: Vec<Vec<(usize, f64)>> = system
                .reactions
                .par_iter()
                .enumerate()
                .map(|(_reaction_idx, reaction)| {
                    let mut contributions = Vec::new();

                    // Process substrates (negative coefficients)
                    for substrate in reaction.substrates.iter().flatten() {
                        if let Some(&species_idx) = species_index.get(&substrate.species) {
                            contributions.push((species_idx, -substrate.coefficient));
                        }
                    }

                    // Process products (positive coefficients)
                    for product in reaction.products.iter().flatten() {
                        if let Some(&species_idx) = species_index.get(&product.species) {
                            contributions.push((species_idx, product.coefficient));
                        }
                    }

                    contributions
                })
                .collect();

            // Apply contributions to matrix
            for (reaction_idx, contributions) in reaction_contributions.into_iter().enumerate() {
                for (species_idx, coeff) in contributions {
                    matrix[species_idx][reaction_idx] += coeff;
                }
            }

            Ok(matrix)
        })
    }
}

/// SIMD-optimized mathematical operations for expression evaluation
#[cfg(feature = "simd")]
pub mod simd_math {
    use super::*;

    /// Apply an element-wise binary op over two vectors, four lanes at a time.
    /// `simd_op` handles full `f64x4` chunks; `scalar_op` handles the tail.
    fn elementwise_simd(
        a: &[f64],
        b: &[f64],
        result: &mut [f64],
        simd_op: impl Fn(f64x4, f64x4) -> f64x4,
        scalar_op: impl Fn(f64, f64) -> f64,
    ) -> Result<(), PerformanceError> {
        if a.len() != b.len() || a.len() != result.len() {
            return Err(PerformanceError::SimdError(
                "Vector length mismatch".to_string(),
            ));
        }

        let chunks = a.len() / 4;

        // Process 4 elements at a time with SIMD
        for i in 0..chunks {
            let idx = i * 4;
            let va = f64x4::from([a[idx], a[idx + 1], a[idx + 2], a[idx + 3]]);
            let vb = f64x4::from([b[idx], b[idx + 1], b[idx + 2], b[idx + 3]]);
            let vr = simd_op(va, vb);

            result[idx..idx + 4].copy_from_slice(&vr.to_array());
        }

        // Handle remaining elements
        for i in (chunks * 4)..a.len() {
            result[i] = scalar_op(a[i], b[i]);
        }

        Ok(())
    }

    /// SIMD-optimized vector addition
    pub fn add_vectors_simd(
        a: &[f64],
        b: &[f64],
        result: &mut [f64],
    ) -> Result<(), PerformanceError> {
        elementwise_simd(a, b, result, |va, vb| va + vb, |x, y| x + y)
    }

    /// SIMD-optimized element-wise multiplication
    pub fn multiply_vectors_simd(
        a: &[f64],
        b: &[f64],
        result: &mut [f64],
    ) -> Result<(), PerformanceError> {
        elementwise_simd(a, b, result, |va, vb| va * vb, |x, y| x * y)
    }

    /// SIMD-optimized dot product
    pub fn dot_product_simd(a: &[f64], b: &[f64]) -> Result<f64, PerformanceError> {
        if a.len() != b.len() {
            return Err(PerformanceError::SimdError(
                "Vector length mismatch".to_string(),
            ));
        }

        let chunks = a.len() / 4;
        let mut sum = f64x4::from([0.0, 0.0, 0.0, 0.0]);

        // Process 4 elements at a time with SIMD
        for i in 0..chunks {
            let idx = i * 4;
            let va = f64x4::from([a[idx], a[idx + 1], a[idx + 2], a[idx + 3]]);
            let vb = f64x4::from([b[idx], b[idx + 1], b[idx + 2], b[idx + 3]]);
            sum += va * vb;
        }

        let mut result = sum.to_array().iter().sum::<f64>();

        // Handle remaining elements
        for i in (chunks * 4)..a.len() {
            result += a[i] * b[i];
        }

        Ok(result)
    }
}

/// Memory pool allocator for large model processing
#[cfg(feature = "custom_alloc")]
pub struct ModelAllocator {
    bump: Bump,
}

#[cfg(feature = "custom_alloc")]
impl Default for ModelAllocator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(feature = "custom_alloc")]
impl ModelAllocator {
    /// Create a new model allocator with specified capacity
    pub fn new() -> Self {
        Self { bump: Bump::new() }
    }

    /// Create allocator with pre-allocated capacity
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            bump: Bump::with_capacity(capacity),
        }
    }

    /// Allocate a slice for storing intermediate results
    pub fn alloc_slice<T>(&self, len: usize) -> &mut [T]
    where
        T: Default + Clone,
    {
        self.bump.alloc_slice_fill_default(len)
    }

    /// Reset the allocator for reuse
    pub fn reset(&mut self) {
        self.bump.reset();
    }

    /// Get current allocated bytes
    pub fn allocated_bytes(&self) -> usize {
        self.bump.allocated_bytes()
    }
}

/// Compact node representation for stack-based evaluation
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub enum CompactNode {
    /// Numeric constant
    Number(f64),
    /// Variable reference
    Variable(String),
    /// Operator (operands implicit via postfix notation)
    Operator(String),
}

/// High-performance expression tree with compact representation
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CompactExpr {
    /// Flattened expression tree using small vectors for cache efficiency
    pub nodes: smallvec::SmallVec<[CompactNode; 8]>,
    /// Variable name cache for quick lookups
    pub var_cache: HashMap<String, usize>,
}

impl CompactExpr {
    /// Create a compact expression from a standard expression
    pub fn from_expr(expr: &Expr) -> Self {
        let mut nodes = smallvec::SmallVec::new();
        let mut var_cache = HashMap::new();

        Self::flatten_expr(expr, &mut nodes, &mut var_cache);

        Self { nodes, var_cache }
    }

    /// Flatten expression tree into linear representation
    fn flatten_expr(
        expr: &Expr,
        nodes: &mut smallvec::SmallVec<[CompactNode; 8]>,
        var_cache: &mut HashMap<String, usize>,
    ) {
        match expr {
            Expr::Number(n) => {
                nodes.push(CompactNode::Number(*n));
            }
            Expr::Integer(n) => {
                // Compact representation currently stores float only; promote
                // per §5.4.1 at the perf-path boundary (evaluate semantics).
                nodes.push(CompactNode::Number(*n as f64));
            }
            Expr::Variable(name) => {
                let index = var_cache.len();
                var_cache.entry(name.clone()).or_insert(index);
                nodes.push(CompactNode::Variable(name.clone()));
            }
            Expr::Operator(expr_node) => {
                // Recursively flatten operands first
                for arg in &expr_node.args {
                    Self::flatten_expr(arg, nodes, var_cache);
                }
                nodes.push(CompactNode::Operator(expr_node.op.clone()));
            }
        }
    }

    /// Fast evaluation using stack-based postfix evaluation. Purely
    /// sequential — available regardless of the `parallel` feature.
    pub fn evaluate_fast(&self, variables: &HashMap<String, f64>) -> Result<f64, PerformanceError> {
        type Stack = smallvec::SmallVec<[f64; 16]>;

        fn underflow() -> PerformanceError {
            PerformanceError::EvalError("Stack underflow".to_string())
        }

        // Pop the two operands of a binary op, returning `(a, b)` in
        // left-to-right order (`b` was on top of the stack).
        fn pop2(stack: &mut Stack) -> Result<(f64, f64), PerformanceError> {
            if stack.len() < 2 {
                return Err(underflow());
            }
            let b = stack.pop().unwrap();
            let a = stack.pop().unwrap();
            Ok((a, b))
        }

        // Pop the single operand of a unary op.
        fn pop1(stack: &mut Stack) -> Result<f64, PerformanceError> {
            stack.pop().ok_or_else(underflow)
        }

        let mut stack = Stack::new();

        for node in &self.nodes {
            match node {
                CompactNode::Number(n) => stack.push(*n),
                CompactNode::Variable(name) => {
                    let value = variables.get(name).ok_or_else(|| {
                        PerformanceError::EvalError(format!("Undefined variable: {name}"))
                    })?;
                    stack.push(*value);
                }
                CompactNode::Operator(op) => match op.as_str() {
                    "+" => {
                        let (a, b) = pop2(&mut stack)?;
                        stack.push(a + b);
                    }
                    "-" => {
                        let (a, b) = pop2(&mut stack)?;
                        stack.push(a - b);
                    }
                    "*" => {
                        let (a, b) = pop2(&mut stack)?;
                        stack.push(a * b);
                    }
                    "/" => {
                        let (a, b) = pop2(&mut stack)?;
                        if b == 0.0 {
                            return Err(PerformanceError::ParallelError(
                                "Division by zero".to_string(),
                            ));
                        }
                        stack.push(a / b);
                    }
                    "^" | "**" => {
                        let (a, b) = pop2(&mut stack)?;
                        stack.push(a.powf(b));
                    }
                    "sin" => {
                        let a = pop1(&mut stack)?;
                        stack.push(a.sin());
                    }
                    "cos" => {
                        let a = pop1(&mut stack)?;
                        stack.push(a.cos());
                    }
                    "exp" => {
                        let a = pop1(&mut stack)?;
                        stack.push(a.exp());
                    }
                    "log" => {
                        let a = pop1(&mut stack)?;
                        if a <= 0.0 {
                            return Err(PerformanceError::ParallelError(
                                "Invalid log argument".to_string(),
                            ));
                        }
                        stack.push(a.ln());
                    }
                    _ => {
                        return Err(PerformanceError::ParallelError(format!(
                            "Unsupported operator: {op}"
                        )));
                    }
                },
            }
        }

        if stack.len() != 1 {
            return Err(PerformanceError::ParallelError(
                "Invalid expression".to_string(),
            ));
        }

        Ok(stack[0])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Expr, ExpressionNode};

    #[test]
    fn test_compact_expr_creation() {
        let expr = Expr::Operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let compact = CompactExpr::from_expr(&expr);
        assert_eq!(compact.nodes.len(), 3);
        assert_eq!(compact.var_cache.len(), 1);
        assert!(compact.var_cache.contains_key("x"));
    }

    #[cfg(feature = "parallel")]
    #[test]
    fn test_fast_evaluation() {
        let expr = Expr::Operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let compact = CompactExpr::from_expr(&expr);
        let mut variables = HashMap::new();
        variables.insert("x".to_string(), 5.0);

        let result = compact.evaluate_fast(&variables).unwrap();
        assert_eq!(result, 6.0);
    }

    #[cfg(feature = "simd")]
    #[test]
    fn test_simd_operations() {
        let a = vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0];
        let b = vec![2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0];
        let mut result = vec![0.0; 8];

        simd_math::add_vectors_simd(&a, &b, &mut result).unwrap();

        assert_eq!(result, vec![3.0, 5.0, 7.0, 9.0, 11.0, 13.0, 15.0, 17.0]);

        let dot = simd_math::dot_product_simd(&a, &b).unwrap();
        assert_eq!(dot, 240.0); // 1*2 + 2*3 + ... + 8*9 = 240.0
    }
}
