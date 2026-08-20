//! Applying a data loader's declared `unit_conversion` (esm-spec §8.5).
//!
//! > `unit_conversion` is either a plain multiplicative factor or a full
//! > `Expression` AST (§4); the runtime applies it **when producing values in
//! > the declared `units`**.
//!
//! Two spellings, because a unit conversion is not always a scale. §4.8.1 keeps
//! affine offsets OUT of the dimensional metadata on purpose — `degF` carries
//! the Kelvin dimension and the scale 5/9, and "a unit conversion that needs the
//! offset is a `unit_conversion` expression, not a dimensional judgement". So
//! ft→m is the number `0.3048` and °F→K is the expression
//! `stktemp*5/9 + 459.67*5/9`, and a runtime that honours only the first
//! silently delivers Fahrenheit.
//!
//! An expression is evaluated ONCE PER ELEMENT with the raw value bound to its
//! single free variable — by convention the loader variable's own name, though
//! the scope a loader's conversion resolves against is every name the DOCUMENT
//! declares (`EarthSciAST.jl` `_document_declared_names`, TS
//! `documentDeclaredNames`), so what is bound is "the one free variable" rather
//! than "the variable called X". A closed expression (no free variables) folds
//! to a constant and takes the same multiply path as a bare factor.
//!
//! The Rust peer of the Python `earthsci_ast.data_sources.variables`
//! (`parse_unit_conversion` / `apply_unit_conversion`) and the Julia
//! `EarthSciAST.parse_unit_conversion` / `apply_unit_conversion!`. All three
//! must agree bit for bit: the conversion is the last thing that touches a
//! delivered array, so a disagreement here is a disagreement about the numbers
//! the model integrates.

use std::collections::HashMap;

use crate::expression::free_variables;
use crate::types::{Expr, UnitConversion};

/// A `unit_conversion` that cannot be parsed or applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnitConversionError(pub String);

impl std::fmt::Display for UnitConversionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for UnitConversionError {}

fn err(msg: impl Into<String>) -> UnitConversionError {
    UnitConversionError(msg.into())
}

/// Parse a loader variable's RAW `unit_conversion` JSON (`number | Expression`).
///
/// `None` (the field is absent, or `null`) means the variable declares no
/// conversion — so a document that declares none costs nothing and behaves
/// exactly as it did before this existed.
pub fn parse_unit_conversion(
    raw: Option<&serde_json::Value>,
    variable_name: &str,
) -> Result<Option<UnitConversion>, UnitConversionError> {
    let Some(raw) = raw else { return Ok(None) };
    if raw.is_null() {
        return Ok(None);
    }
    if raw.is_boolean() {
        return Err(err(format!(
            "variable {variable_name:?} unit_conversion must be a number or an \
             Expression object, got a boolean"
        )));
    }
    serde_json::from_value::<UnitConversion>(raw.clone())
        .map(Some)
        .map_err(|e| {
            err(format!(
                "variable {variable_name:?} unit_conversion must be a number or an \
                 Expression object: {e}"
            ))
        })
}

/// The constant scale `conversion` reduces to, or `None` when it is an OPEN
/// expression that has to be evaluated per element.
fn scale_factor(
    conversion: &UnitConversion,
    variable_name: &str,
) -> Result<Option<f64>, UnitConversionError> {
    match conversion {
        UnitConversion::Factor(k) => Ok(Some(*k)),
        UnitConversion::Expression(expr) => {
            if !free_variables(expr).is_empty() {
                return Ok(None);
            }
            evaluate_scalar(expr, &HashMap::new()).map(Some).map_err(|e| {
                err(format!(
                    "variable {variable_name:?} unit_conversion is a constant \
                     expression but did not evaluate: {e}"
                ))
            })
        }
    }
}

fn evaluate_scalar(expr: &Expr, bindings: &HashMap<String, f64>) -> Result<f64, String> {
    crate::expression::evaluate(expr, bindings).map_err(|missing| {
        let mut names = missing;
        names.sort();
        format!("unbound {names:?}")
    })
}

/// Apply `conversion` to `values` IN PLACE, producing the variable's declared
/// units (esm-spec §8.5).
///
/// A factor (or a closed expression, which folds to one) multiplies; a factor of
/// exactly `1.0` leaves the values untouched rather than round-tripping them
/// through a multiply. An open expression is evaluated once per element with the
/// raw value bound to its single free variable; more than one free variable is
/// an error, since there is no second column to bind it to.
pub fn apply_unit_conversion(
    values: &mut [f64],
    conversion: &UnitConversion,
    variable_name: &str,
) -> Result<(), UnitConversionError> {
    if let Some(scale) = scale_factor(conversion, variable_name)? {
        if scale != 1.0 {
            for v in values.iter_mut() {
                *v *= scale;
            }
        }
        return Ok(());
    }
    let UnitConversion::Expression(expr) = conversion else {
        unreachable!("a Factor always reduces to a scale");
    };
    let free = free_variables(expr);
    if free.len() != 1 {
        let mut names: Vec<String> = free.into_iter().collect();
        names.sort();
        return Err(err(format!(
            "variable {variable_name:?} unit_conversion must depend on at most one \
             free variable, got {names:?}"
        )));
    }
    let raw_name = free.into_iter().next().expect("checked len == 1");
    let mut bindings: HashMap<String, f64> = HashMap::with_capacity(1);
    for v in values.iter_mut() {
        bindings.insert(raw_name.clone(), *v);
        *v = evaluate_scalar(expr, &bindings).map_err(|e| {
            err(format!(
                "variable {variable_name:?} unit_conversion did not evaluate at \
                 {raw_name}={v}: {e}"
            ))
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn conv(raw: serde_json::Value) -> UnitConversion {
        parse_unit_conversion(Some(&raw), "v").unwrap().unwrap()
    }

    #[test]
    fn an_absent_conversion_is_none() {
        assert!(parse_unit_conversion(None, "v").unwrap().is_none());
        assert!(parse_unit_conversion(Some(&json!(null)), "v").unwrap().is_none());
    }

    #[test]
    fn a_numeric_factor_scales() {
        let c = conv(json!(0.3048));
        let mut v = [707.0, 0.0, -1.0];
        apply_unit_conversion(&mut v, &c, "stkhgt").unwrap();
        assert_eq!(v, [707.0 * 0.3048, 0.0, -0.3048]);
    }

    #[test]
    fn a_factor_of_one_is_bit_identical() {
        let c = conv(json!(1));
        let mut v = [0.1 + 0.2, 1e308, f64::NAN];
        let before = v;
        apply_unit_conversion(&mut v, &c, "x").unwrap();
        assert_eq!(v[0].to_bits(), before[0].to_bits());
        assert_eq!(v[1].to_bits(), before[1].to_bits());
        assert!(v[2].is_nan());
    }

    /// The affine case §4.8.1 says MUST be an expression: °F → K.
    #[test]
    fn an_open_expression_binds_the_raw_value() {
        let c = conv(json!({
            "op": "+",
            "args": [{"op": "*", "args": ["stktemp", 0.5555555555555556]},
                     255.37222222222223]
        }));
        let mut v = [32.0, 1116.0];
        apply_unit_conversion(&mut v, &c, "stktemp").unwrap();
        assert!((v[0] - 273.15).abs() < 1e-9, "{v:?}");
        assert!((v[1] - 875.3722222222223).abs() < 1e-9, "{v:?}");
    }

    #[test]
    fn a_closed_expression_folds_to_a_factor() {
        let c = conv(json!({"op": "*", "args": [0.3048, 2.0]}));
        let mut v = [1.0];
        apply_unit_conversion(&mut v, &c, "x").unwrap();
        assert_eq!(v, [0.6096]);
    }

    #[test]
    fn two_free_variables_is_an_error() {
        let c = conv(json!({"op": "*", "args": ["a", "b"]}));
        let mut v = [1.0];
        let e = apply_unit_conversion(&mut v, &c, "x").unwrap_err();
        assert!(e.to_string().contains("at most one free variable"), "{e}");
    }

    #[test]
    fn a_boolean_is_not_a_conversion() {
        let e = parse_unit_conversion(Some(&json!(true)), "v").unwrap_err();
        assert!(e.to_string().contains("boolean"), "{e}");
    }
}
