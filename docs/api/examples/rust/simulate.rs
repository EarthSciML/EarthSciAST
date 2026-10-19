//! Build a problem from a document, solve it, and read states and observeds.

use std::collections::HashMap;

use earthsci_ast::{
    ProblemOptions, Remake, ReturnCode, SolveOptions, esm_problem, observed_trajectory, remake,
    solve,
};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: simulate ops=esm_problem,solve,observed_trajectory
    let path = fixture("decay.esm");
    let prob = esm_problem(path.as_path(), (0.0, 10.0), ProblemOptions::default())?;

    // Sample the solution at t = ln 2 / λ, one half-life in.
    let lambda = 0.1_f64;
    let t_half = 2.0_f64.ln() / lambda;
    let opts = SolveOptions {
        saveat: Some(vec![0.0, t_half]),
        ..Default::default()
    };
    let sol = solve(&prob, &opts)?;
    assert_eq!(sol.retcode, ReturnCode::Success);

    // States are read by name; a bare name resolves when it is unique.
    let n = sol.get("N").expect("N is a state");
    assert!((n[0] - 100.0).abs() < 1e-9);
    assert!((n[1] - 50.0).abs() < 1e-3, "N(ln 2 / λ) = {}", n[1]);

    // half_life is an observed: computed from the solution, not stored in it.
    let half_life = observed_trajectory(&prob, &sol, "half_life")?;
    assert!(half_life.iter().all(|h| (h - t_half).abs() < 1e-9));
    // endregion

    // region: remake ops=remake
    // A new problem with a different parameter value; the compiled
    // right-hand side is shared, not rebuilt.
    let faster = remake(
        &prob,
        &Remake {
            p: HashMap::from([("lambda".to_string(), 0.2)]),
            ..Default::default()
        },
    )?;
    let sol = solve(&faster, &opts)?;
    let n = sol.get("N").unwrap();
    assert!((n[1] - 25.0).abs() < 1e-3, "N = {}", n[1]);
    // endregion

    Ok(())
}
