//! Project a full gather through an elementwise expression without reading its
//! other cells. Evaluators read the projected AST with their existing operators.

use super::DimU;
use crate::op_registry::{elementwise_op, is_elementwise_node};
use crate::{Expr, ExpressionNode};

pub(super) struct ElementwiseCell<'a> {
    expr: &'a Expr,
    shape: DimU,
    operands: Vec<Self>,
}

impl<'a> ElementwiseCell<'a> {
    /// Plan a complete gather using operand extents alone. Named array leaves
    /// have no axis labels in this scope and must keep the existing path.
    pub(super) fn plan(
        base: &'a Expr,
        rank: usize,
        variable_shape: &impl Fn(&str) -> Option<DimU>,
    ) -> Option<Self> {
        if rank == 0 || !matches!(base, Expr::Operator(node) if is_elementwise_node(node)) {
            return None;
        }
        let plan = Self::operand(base, variable_shape)?;
        (plan.shape.len() == rank).then_some(plan)
    }

    fn operand(expr: &'a Expr, variable_shape: &impl Fn(&str) -> Option<DimU>) -> Option<Self> {
        let mut operands = Vec::new();
        let shape = match expr {
            Expr::Operator(node) if is_elementwise_node(node) => {
                let mut shape = DimU::new();
                for arg in &node.args {
                    let operand = Self::operand(arg, variable_shape)?;
                    for (axis, &len) in operand.shape.iter().enumerate() {
                        match shape.get_mut(axis) {
                            Some(current) if *current == 1 => *current = len,
                            Some(current) if len == 1 || len == *current => (),
                            Some(_) => return None,
                            None => shape.push(len),
                        }
                    }
                    operands.push(operand);
                }
                if elementwise_op(node) == Some("ifelse")
                    && let [condition, yes, no] = operands.as_slice()
                    && condition.shape.is_empty()
                    && yes.shape != no.shape
                {
                    // A scalar condition returns its branch as-is. The merged
                    // extents cannot decide even the rank of this gather.
                    return None;
                }
                shape
            }
            _ => {
                let shape = leaf_shape(expr, variable_shape)?;
                if matches!(expr, Expr::Variable(_)) && !shape.is_empty() {
                    return None;
                }
                shape
            }
        };
        Some(Self {
            expr,
            shape,
            operands,
        })
    }

    /// Existing computed-array gathers use zero for an out-of-bounds cell.
    pub(super) fn select(&self, position: &[i64]) -> Expr {
        if position
            .iter()
            .zip(&self.shape)
            .any(|(&i, &n)| i < 1 || i as u64 > n as u64)
        {
            return Expr::Integer(0);
        }
        let position: Vec<_> = position.iter().copied().map(Expr::Integer).collect();
        self.project(&position)
    }

    pub(super) fn extents(&self) -> &[usize] {
        &self.shape
    }

    /// Introduce the leaf gathers for a coordinate already checked against
    /// the result extents by the caller.
    pub(super) fn project(&self, position: &[Expr]) -> Expr {
        if self.shape.is_empty() {
            return self.expr.clone();
        }
        let local: Vec<_> = self
            .shape
            .iter()
            .zip(position)
            .map(|(&n, i)| if n == 1 { Expr::Integer(1) } else { i.clone() })
            .collect();
        if let Expr::Operator(node) = self.expr
            && !self.operands.is_empty()
        {
            return Expr::operator(ExpressionNode {
                args: self
                    .operands
                    .iter()
                    .map(|operand| operand.project(&local))
                    .collect(),
                ..ExpressionNode::clone(node)
            });
        }
        let mut args = vec![self.expr.clone()];
        args.extend(local);
        Expr::operator(ExpressionNode {
            op: "index".to_string(),
            args,
            ..Default::default()
        })
    }
}

/// Metadata for the operators that consume an entire operand. Their scalar
/// or array shape is enough; projection leaves their operand scopes intact.
fn leaf_shape(expr: &Expr, variable_shape: &impl Fn(&str) -> Option<DimU>) -> Option<DimU> {
    let empty = DimU::new;
    match expr {
        Expr::Integer(_) | Expr::Number(_) => Some(empty()),
        Expr::Variable(name) => variable_shape(name),
        Expr::Operator(node) => match node.op.as_str() {
            "const" => {
                let value = node.value.as_ref()?;
                if value.is_number() {
                    Some(empty())
                } else {
                    Some(value.array()?.shape().iter().copied().collect())
                }
            }
            "true" | "false" | "enum" => Some(empty()),
            "faq" if node.output_idx.as_ref().is_none_or(|out| out.is_empty()) => Some(empty()),
            "index" => {
                let (base, subscripts) = node.args.split_first()?;
                let shape = match base {
                    Expr::Variable(name) => variable_shape(name)?,
                    _ => ElementwiseCell::operand(base, variable_shape)?.shape,
                };
                // A full gather is a scalar barrier. A trailing slice may
                // still carry named axes, so leave that case to its own path.
                if subscripts.len() != shape.len() {
                    return None;
                }
                for idx in subscripts {
                    if !ElementwiseCell::operand(idx, variable_shape)?
                        .shape
                        .is_empty()
                    {
                        return None;
                    }
                }
                Some(empty())
            }
            _ => None,
        },
    }
}
