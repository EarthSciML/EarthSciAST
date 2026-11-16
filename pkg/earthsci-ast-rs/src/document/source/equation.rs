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
    split_eq(j).ok()
}

/// [`eq_sides`], giving the value back unchanged when it is not a `==` node
/// of two operands, so a caller that keeps any other value need not copy it
/// first.
pub fn split_eq(j: Json) -> Result<(Json, Json), Json> {
    let Json::Obj(kvs) = j else { return Err(j) };
    match <[(String, Json); 2]>::try_from(kvs) {
        Ok([(a, Json::Arr(xs)), (o, Json::Str(op))]) if a == "args" && o == "op" && op == "==" => {
            match <[Json; 2]>::try_from(xs) {
                Ok([l, r]) => Ok((l, r)),
                Err(xs) => Err(Json::Obj(vec![(a, Json::Arr(xs)), (o, Json::Str(op))])),
            }
        }
        Ok(kvs) => Err(Json::Obj(kvs.into())),
        Err(kvs) => Err(Json::Obj(kvs)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(op: &str, args: Vec<Json>) -> Json {
        Json::Obj(vec![
            ("args".to_string(), Json::Arr(args)),
            ("op".to_string(), Json::str(op)),
        ])
    }

    #[test]
    fn split_eq_gives_back_what_is_not_an_equation() {
        assert_eq!(
            split_eq(node("==", vec![Json::str("y"), Json::str("k")])),
            Ok((Json::str("y"), Json::str("k")))
        );
        for j in [
            Json::str("y"),
            node("+", vec![Json::str("y"), Json::str("k")]),
            node("==", vec![Json::str("y")]),
            node("==", vec![Json::str("a"), Json::str("b"), Json::str("c")]),
            Json::Obj(vec![("op".to_string(), Json::str("=="))]),
        ] {
            assert_eq!(split_eq(j.clone()), Err(j));
        }
    }
}
