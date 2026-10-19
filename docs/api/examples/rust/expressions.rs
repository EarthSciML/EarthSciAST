//! Build and parse expressions, list their free variables, substitute,
//! simplify and evaluate.

use std::collections::HashMap;

use earthsci_ast::{
    Expr, canonical_json, contains, evaluate, free_variables, parse_equation, parse_expression,
    simplify, substitute, to_ascii,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: expressions ops=parse_expression,parse_equation,free_variables,substitute
    // Parse the text form (the same syntax `to_ascii` prints) ...
    let rate = parse_expression("k * A - x")?;
    assert_eq!(to_ascii(&rate), "k * A - x");

    // ... or a whole equation.
    let eq = parse_equation("D(x)/Dt = k * A - x")?;
    assert_eq!(to_ascii(&eq.lhs), "D(x)/Dt");

    let mut names: Vec<String> = free_variables(&rate).into_iter().collect();
    names.sort();
    assert_eq!(names, ["A", "k", "x"]);

    // Replace `k` with `2 * j`.
    let subs = HashMap::from([("k".to_string(), parse_expression("2 * j")?)]);
    let replaced = substitute(&rate, &subs);
    assert_eq!(to_ascii(&replaced), "2 * j * A - x");

    // Expressions are also plain Rust values.
    let one = Expr::Variable("x".to_string());
    assert_eq!(to_ascii(&one), "x");
    // endregion

    // region: evaluate ops=evaluate,simplify,contains
    let expr = parse_expression("k * A - x")?;
    let bindings = HashMap::from([
        ("k".to_string(), 2.0),
        ("A".to_string(), 3.0),
        ("x".to_string(), 1.0),
    ]);
    assert_eq!(evaluate(&expr, &bindings), Ok(5.0));

    // A missing binding is reported by name, not guessed.
    let partial = HashMap::from([("k".to_string(), 2.0)]);
    let mut unbound = evaluate(&expr, &partial).unwrap_err();
    unbound.sort();
    assert_eq!(unbound, ["A", "x"]);

    assert!(contains(&expr, "A") && !contains(&expr, "B"));
    assert_eq!(to_ascii(&simplify(&parse_expression("x * 1 + 0")?)), "x");
    // endregion

    // region: canonical_json ops=canonical_json
    // Two spellings of the same sum serialize identically once canonicalized.
    let a = canonical_json(&parse_expression("x + y + 1")?)?;
    let b = canonical_json(&parse_expression("1 + y + x")?)?;
    assert_eq!(a, b);
    println!("{a}");
    // endregion

    Ok(())
}
