//! Read expressions from math, build them as values, list their free
//! variables, substitute, simplify and evaluate.

use std::collections::HashMap;

use earthsci_ast::{
    DocumentFormat, Equation, Expr, canonical_json, contains, evaluate, free_variables, parse_math,
    simplify, substitute,
};

/// Read Typst math under the declared names into an `Expr`: parse_math
/// returns the JSON form.
fn read(text: &str, names: &[&str]) -> Expr {
    let names: Vec<String> = names.iter().map(|n| n.to_string()).collect();
    let value = parse_math(text, &names, DocumentFormat::Typst).expect("readable math");
    serde_json::from_value(value).expect("an expression")
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: expressions ops=parse_math,free_variables,substitute
    // Read Typst math (or LaTeX, with DocumentFormat::Markdown) under the
    // names it uses: the inverse of print_math.
    let names = ["k".to_string(), "A".to_string(), "x".to_string()];
    let value = parse_math("k A - x", &names, DocumentFormat::Typst)?;
    let rate: Expr = serde_json::from_value(value)?;
    assert_eq!(rate.to_string(), "k A - x");

    // Text whose top is `=` reads as an equation.
    let value = parse_math("(dif x)/(dif t) = k A - x", &names, DocumentFormat::Typst)?;
    let eq: Equation = serde_json::from_value(value)?;
    assert_eq!(eq.lhs.to_string(), "(dif x)/(dif t)");

    let mut free: Vec<String> = free_variables(&rate).into_iter().collect();
    free.sort();
    assert_eq!(free, ["A", "k", "x"]);

    // Replace `k` with `2 j`.
    let subs = HashMap::from([("k".to_string(), read("2 j", &["j"]))]);
    let replaced = substitute(&rate, &subs);
    assert_eq!(replaced.to_string(), "(2 j) A - x");

    // Expressions are also plain Rust values.
    let one = Expr::Variable("x".to_string());
    assert_eq!(one.to_string(), "x");
    // endregion

    // region: evaluate ops=evaluate,simplify,contains
    let expr = read("k A - x", &["k", "A", "x"]);
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
    // simplify folds numbers: with k = 2 and A = 3, k A is 6.
    let numbers = HashMap::from([
        ("k".to_string(), Expr::Number(2.0)),
        ("A".to_string(), Expr::Number(3.0)),
    ]);
    assert_eq!(simplify(&substitute(&expr, &numbers)).to_string(), "6 - x");
    // endregion

    // region: canonical_json ops=canonical_json
    // Two spellings of the same sum serialize identically once canonicalized.
    let a = canonical_json(&read("x + y + 1", &["x", "y"]))?;
    let b = canonical_json(&read("1 + y + x", &["x", "y"]))?;
    assert_eq!(a, b);
    println!("{a}");
    // endregion

    Ok(())
}
