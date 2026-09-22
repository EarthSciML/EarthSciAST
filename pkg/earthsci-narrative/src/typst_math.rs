//! Expressions as Typst math.

use earthsci_ast::{Equation, Expr};

/// Render an expression as Typst math source (the text between `$ … $`).
pub fn expr_to_typst(_expr: &Expr) -> String {
    todo!("Typst math printer")
}

/// Render an equation as Typst math source, `lhs = rhs`.
pub fn equation_to_typst(_eq: &Equation) -> String {
    todo!("Typst math printer")
}

/// Render a variable name as Typst math source.
pub fn name_to_typst(_name: &str) -> String {
    todo!("Typst math printer")
}
