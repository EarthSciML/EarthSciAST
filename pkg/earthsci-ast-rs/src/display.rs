//! `Display` for expressions and equations: Typst math, printed by
//! [`crate::print_math`] with the expression's own names declared
//! ([`crate::expression_names`]). This is the one way the crate quotes an
//! expression in a message.

use crate::document::{DocumentFormat, expression_names, print_math};
use crate::types::{Equation, Expr};
use std::fmt;

/// Typst math for an ESM expression or equation given as JSON.
pub(crate) fn math_text(value: &serde_json::Value) -> String {
    print_math(value, &expression_names(value), DocumentFormat::Typst)
}

fn write_math<T: serde::Serialize + fmt::Debug>(v: &T, f: &mut fmt::Formatter<'_>) -> fmt::Result {
    match serde_json::to_value(v) {
        Ok(value) => f.write_str(&math_text(&value)),
        Err(_) => write!(f, "{v:?}"),
    }
}

impl fmt::Display for Expr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write_math(self, f)
    }
}

impl fmt::Display for Equation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write_math(self, f)
    }
}
