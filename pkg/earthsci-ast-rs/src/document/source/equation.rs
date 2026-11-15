//! An equation as math: `lhs = rhs` is the math of the expression
//! `==(lhs, rhs)`.
//!
//! Port of `formal/Esm/Document/Source/Equation.lean`.

use super::skeleton::Eqn;
use crate::document::json::Json;

/// `Source.eqExpr`: the expression an equation is printed as.
pub fn eq_expr(e: &Eqn) -> Json {
    Json::Obj(vec![
        (
            "args".to_string(),
            Json::Arr(vec![e.lhs.clone(), e.rhs.clone()]),
        ),
        ("op".to_string(), Json::str("==")),
    ])
}

/// `Source.eqSides`: the equation sides of a parsed `==` node.
pub fn eq_sides(j: Json) -> Option<(Json, Json)> {
    let Json::Obj(kvs) = j else { return None };
    match <[(String, Json); 2]>::try_from(kvs) {
        Ok([(a, Json::Arr(xs)), (o, Json::Str(op))]) if a == "args" && o == "op" && op == "==" => {
            match <[Json; 2]>::try_from(xs) {
                Ok([l, r]) => Some((l, r)),
                Err(_) => None,
            }
        }
        _ => None,
    }
}
