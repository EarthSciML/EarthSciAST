//! Crate-internal builders for the document skeletons unit tests construct
//! over and over: a minimal [`EsmFile`], a bare [`ModelVariable`] of a given
//! type, and a `D(x)/dt = rhs` [`Equation`]. Compiled only under `#[cfg(test)]`
//! (see `lib.rs`); integration binaries under `tests/` have their own
//! `tests/common/` helpers.
//!
//! These exist so a test names ONLY the fields it is about and spreads the
//! rest — either from a builder or straight from `..Default::default()`.

use crate::types::{Equation, Metadata, ModelVariable, VariableType};
use crate::{EsmFile, Expr, ExpressionNode};

/// A minimal well-formed document — current `esm` version, metadata carrying
/// only the name `"test"` — to be spread with `..test_file()` so a test names
/// only the sections it cares about.
pub(crate) fn test_file() -> EsmFile {
    EsmFile {
        metadata: Metadata {
            name: Some("test".to_string()),
            ..Default::default()
        },
        ..Default::default()
    }
}

/// A bare variable of the given type and (optionally) units; everything else
/// absent.
pub(crate) fn var(vt: VariableType, units: Option<&str>) -> ModelVariable {
    ModelVariable {
        var_type: vt,
        units: units.map(|u| u.to_string()),
        ..Default::default()
    }
}

/// The equation `D(target)/dt = rhs`, with the standard `wrt: "t"` derivative
/// LHS.
pub(crate) fn ddt(target: &str, rhs: Expr) -> Equation {
    Equation {
        lhs: Expr::operator(ExpressionNode {
            op: "D".to_string(),
            args: vec![Expr::Variable(target.to_string())],
            wrt: Some("t".to_string()),
            ..Default::default()
        }),
        rhs,
    }
}
