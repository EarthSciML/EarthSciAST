//! Float32 state and clock semantics through the public simulation API.
#![cfg(feature = "solve")]

use earthsci_ast::precision::Precision;
use earthsci_ast::{
    Alg, Compiler, IntegratorPrecision, ProblemInput, ProblemOptions, RhsError, SolveOptions,
    StepStatus, esm_problem, init, rhs_program, solve,
};
use serde_json::{Value, json};

fn document() -> Value {
    serde_json::from_str(include_str!(
        "../../../tests/conformance/precision_integration/vanishing_increment.esm"
    ))
    .unwrap()
}

#[test]
fn accepted_state_loses_sub_ulp_increments() {
    let doc = document();
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let prob = esm_problem(
            ProblemInput::Json(&doc),
            (0.0, 100.0),
            ProblemOptions {
                compiler: Some(compiler),
                ..ProblemOptions::default()
            },
        )
        .unwrap();
        let opts = SolveOptions {
            alg: Alg::Erk,
            maxiters: Some(10_000),
            ..SolveOptions::default()
        };
        let sol = solve(&prob, &opts).unwrap();
        assert!(sol.retcode.is_success());
        assert_eq!(sol.time.last(), Some(&100.0));
        assert!(sol.time.windows(2).all(|w| w[1] - w[0] < 1.0));
        // Binary64 preserves the increments, producing approximately 1.000001.
        assert!(sol["x"].iter().all(|&x| x == 1.0));
        assert_eq!(
            sol.metadata.integrator_precision,
            Some(IntegratorPrecision {
                state: Precision::Float32,
                time: Precision::Float32,
                norms: Precision::Float32,
                linear_algebra: Precision::Float32,
            })
        );
    }
}

#[test]
fn every_solver_advances_a_float32_problem() {
    let mut doc = document();
    doc["models"]["M"]["equations"][0]["rhs"] = json!({"op": "-", "args": ["x"]});
    let prob = esm_problem(
        ProblemInput::Json(&doc),
        (0.0, 1.1),
        ProblemOptions::default(),
    )
    .unwrap();
    for alg in [Alg::Bdf, Alg::Sdirk, Alg::Erk] {
        let opts = SolveOptions {
            alg,
            saveat: Some(vec![0.0, 0.3, 1.1]),
            maxiters: Some(10_000),
            ..SolveOptions::default()
        };
        let sol = solve(&prob, &opts).unwrap();
        assert!(sol.retcode.is_success(), "{alg:?}");
        assert_eq!(sol.time, [0.0, f64::from(0.3_f32), f64::from(1.1_f32)]);
        assert!(
            (sol.final_value("x").unwrap() - (-1.1_f64).exp()).abs() < 5e-4,
            "{alg:?}"
        );

        let mut integrator = init(&prob, &opts).unwrap();
        while integrator.step().unwrap() == StepStatus::Advanced {}
        assert!(integrator.retcode().is_success(), "{alg:?}");
        assert_eq!(integrator.t(), f64::from(1.1_f32));
        assert!(
            (integrator.u()["M.x"] - (-1.1_f64).exp()).abs() < 5e-4,
            "{alg:?}"
        );
    }
}

#[test]
fn refuses_unsupported_clocks_tolerances_and_mixed_states() {
    let mut doc = document();
    doc["solver"] = json!({"reltol": 1e-9});
    let validation = earthsci_ast::validate_text(&doc.to_string(), None);
    assert!(validation.is_valid, "{validation:?}");
    assert_eq!(validation.warnings.len(), 1);
    assert_eq!(
        validation.warnings[0].code,
        "tolerance_below_working_precision"
    );
    assert_eq!(validation.warnings[0].path, "/solver/reltol");
    let prob = esm_problem(
        ProblemInput::Json(&doc),
        (0.0, 1.0),
        ProblemOptions::default(),
    )
    .unwrap();
    let error = solve(&prob, &SolveOptions::default()).unwrap_err();
    assert_eq!(error.code(), Some("tolerance_below_working_precision"));
    assert!(error.to_string().contains("solver.reltol"));
    let opts = SolveOptions {
        reltol: Some(1e-9),
        ..SolveOptions::default()
    };
    let error = init(&prob, &opts).unwrap_err();
    assert!(error.to_string().contains("call site"));
    let opts = SolveOptions {
        reltol: Some(1e-4),
        ..SolveOptions::default()
    };

    let prob = esm_problem(
        ProblemInput::Json(&doc),
        (1e8, 1e8 + 4.0),
        ProblemOptions::default(),
    )
    .unwrap();
    let error = solve(&prob, &opts).unwrap_err();
    assert_eq!(error.code(), Some("float32_unsupported"));
    assert!(error.to_string().contains("binary32 clock"));

    let prob = esm_problem(
        ProblemInput::Json(&doc),
        (1e8, 1e8 + 1000.0),
        ProblemOptions::default(),
    )
    .unwrap();
    let grid = SolveOptions {
        saveat: Some(vec![1e8 + 32.0, 1e8 + 33.0]),
        ..opts.clone()
    };
    assert!(
        init(&prob, &grid)
            .unwrap_err()
            .to_string()
            .contains("output times")
    );

    doc["models"]["M"]["variables"]["y"]["element_type"] = json!("Float64");
    let prob = esm_problem(
        ProblemInput::Json(&doc),
        (0.0, 1.0),
        ProblemOptions::default(),
    )
    .unwrap();
    let error = solve(&prob, &opts).unwrap_err();
    assert_eq!(error.code(), Some("float32_unsupported"));
    assert!(error.to_string().contains("mixing Float32 and Float64"));

    let rhs = rhs_program(&prob).unwrap();
    let (u, aux) = rhs.default_state();
    let p = rhs.parameter_vector(&Default::default()).unwrap();
    let u32: Vec<f32> = u.iter().map(|&v| v as f32).collect();
    let error = rhs
        .eval_into(
            &u32,
            &aux,
            &p,
            0.0,
            &rhs.default_forcing(),
            &mut [0.0_f32; 2],
            &mut rhs.new_workspace(),
        )
        .unwrap_err();
    assert!(matches!(
        error,
        RhsError::StatePrecision {
            declared: Precision::Float64,
            ..
        }
    ));
}

#[test]
fn public_rhs_rounds_time_and_parameters_even_on_a_fresh_thread() {
    let mut doc = document();
    doc["models"]["M"]["variables"]["k"]["default"] = json!(100_000_000);
    doc["models"]["M"]["equations"][0]["rhs"] = json!({"op": "-", "args": ["t", "k"]});
    doc["models"]["M"]["equations"][1]["rhs"] = json!({"op": "-", "args": ["k", 100_000_000]});
    for observed in ["time_read", "time_delta"] {
        doc["models"]["M"]["variables"][observed] = json!({"type": "unknown", "units": "s"});
    }
    doc["models"]["M"]["equations"]
        .as_array_mut()
        .unwrap()
        .extend([
            json!({"lhs": "time_read", "rhs": "t"}),
            json!({"lhs": "time_delta", "rhs": {"op": "-", "args": ["t", 100_000_000]}}),
        ]);
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let prob = esm_problem(
            ProblemInput::Json(&doc),
            (100_000_001.0, 100_000_001.0),
            ProblemOptions {
                compiler: Some(compiler),
                ..ProblemOptions::default()
            },
        )
        .unwrap();
        let observed = SolveOptions {
            output_observed: vec!["time_read".into(), "time_delta".into()],
            ..SolveOptions::default()
        };
        let sol = solve(&prob, &observed).unwrap();
        assert_eq!(sol["time_read"], [100_000_000.0], "{compiler:?}");
        assert_eq!(sol["time_delta"], [0.0]);

        let rhs = rhs_program(&prob).unwrap();
        assert_eq!(rhs.state_precisions(), [Precision::Float32; 2]);
        std::thread::spawn(move || {
            let (u, aux) = rhs.default_state();
            let u32: Vec<f32> = u.iter().map(|&v| v as f32).collect();
            let p = [100_000_001.0];
            let forcing = rhs.default_forcing();
            let mut ws = rhs.new_workspace();
            let mut du = [f64::NAN; 2];
            rhs.eval_into(&u, &aux, &p, 100_000_001.0, &forcing, &mut du, &mut ws)
                .unwrap();
            assert_eq!(du, [0.0, 0.0]);
            let mut du32 = [f32::NAN; 2];
            rhs.eval_into(&u32, &aux, &p, 100_000_001.0, &forcing, &mut du32, &mut ws)
                .unwrap();
            assert_eq!(du32, [0.0, 0.0]);
        })
        .join()
        .unwrap();
    }
}

#[test]
fn array_state_and_runtime_parameter_use_their_declared_precision() {
    let doc = json!({
        "esm": "2.0.0",
        "metadata": {"name": "ArrayFloat32"},
        "index_sets": {"i": {"kind": "interval", "size": 2}},
        "models": {"M": {
            "variables": {
                "x": {"type": "unknown", "units": "1", "shape": ["i"],
                      "element_type": "Float32", "default": [1.0, 2.0]},
                "k": {"type": "parameter", "units": "1/s", "shape": ["i"],
                      "element_type": "Float32", "default": [1.0, 2.0]}
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                 "rhs": {"op": "*", "args": [{"op": "-", "args": ["k"]}, "x"]}}
            ]
        }}
    });
    let prob = esm_problem(
        ProblemInput::Json(&doc),
        (0.0, 1.0),
        ProblemOptions {
            runtime_array_parameters: true,
            ..ProblemOptions::default()
        },
    )
    .unwrap();
    let rhs = rhs_program(&prob).unwrap();
    assert_eq!(rhs.precision(), Precision::Float64);
    assert_eq!(rhs.state_precisions(), [Precision::Float32; 2]);
    let forcing = rhs
        .default_forcing()
        .replace(0, [1.00000001, 2.00000001].into())
        .unwrap();
    assert_eq!(forcing.buffer(0), [1.0, 2.0]);
    let mut u = [1.00000001, 2.00000001];
    let mut du = [0.0; 2];
    rhs.eval_into(
        &u,
        &[],
        &[],
        0.0,
        &forcing,
        &mut du,
        &mut rhs.new_workspace(),
    )
    .unwrap();
    assert_eq!(du, [-1.0, -4.0]);
    assert_eq!(u, [1.00000001, 2.00000001]);
    rhs.round_state(&mut u).unwrap();
    assert_eq!(u, [1.0, 2.0]);

    let opts = SolveOptions {
        alg: Alg::Erk,
        ..SolveOptions::default()
    };
    let sol = solve(&prob, &opts).unwrap();
    assert_eq!(
        sol.metadata.integrator_precision.unwrap().state,
        Precision::Float32
    );
    assert!((sol.final_value("x[1]").unwrap() - (-1.0_f64).exp()).abs() < 5e-5);
    assert!((sol.final_value("x[2]").unwrap() - 2.0 * (-2.0_f64).exp()).abs() < 5e-5);
}

fn read_document(path: impl AsRef<std::path::Path>) -> Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

#[test]
fn float32_pde_trajectories_agree_with_the_binary64_goldens() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/pde_simulation");
    let manifest = read_document(root.join("manifest.json"));
    for case in manifest["fixtures"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        let mut doc = read_document(root.join(case["path"].as_str().unwrap()));
        doc["domain"]["element_type"] = json!("Float32");
        let trajectory = &case["trajectory"];
        let span = (
            trajectory["time_span"]["start"].as_f64().unwrap(),
            trajectory["time_span"]["end"].as_f64().unwrap(),
        );
        let prob = esm_problem(
            ProblemInput::Json(&doc),
            span,
            ProblemOptions {
                u0: serde_json::from_value(trajectory["initial_conditions"].clone()).unwrap(),
                ..ProblemOptions::default()
            },
        )
        .unwrap_or_else(|error| panic!("{id}: {error}"));
        let times: Vec<f64> = serde_json::from_value(trajectory["output_times"].clone()).unwrap();
        let opts = SolveOptions {
            alg: Alg::Erk,
            reltol: Some(1e-6),
            abstol: Some(1e-8),
            saveat: Some(times.clone()),
            ..SolveOptions::default()
        };
        let sol = solve(&prob, &opts).unwrap_or_else(|error| panic!("{id}: {error}"));
        assert!(sol.retcode.is_success(), "{id}");
        assert_eq!(sol.time.len(), times.len(), "{id}");
        let golden = read_document(root.join(case["golden"].as_str().unwrap()));
        for (i, time) in times.into_iter().enumerate() {
            assert_eq!(sol.time[i], f64::from(time as f32), "{id}");
            let expected = golden["trajectory"][time.to_string()].as_object().unwrap();
            for (name, expected) in expected {
                let reference = expected.as_f64().unwrap();
                let actual = sol[name][i];
                assert!(
                    (actual - reference).abs() <= 1e-4 * reference.abs() + 1e-7,
                    "{id} {name} at {time}: {actual} vs {reference}"
                );
                assert_eq!(actual, f64::from(actual as f32), "{id} {name} at {time}");
            }
        }
    }
}

/// A document whose one state `x` reads `t - 1e8`, with the document's and
/// `x`'s declared precisions given.
fn time_reading_document(document: &str, state: &str) -> Value {
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "TimeRead"},
        "domain": {"element_type": document},
        "models": {"M": {
            "variables": {
                "x": {"type": "unknown", "units": "s", "default": 0.0, "element_type": state}
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                 "rhs": {"op": "*", "args": [
                     {"op": "const", "args": [], "value": 1.0, "units": "1/s"},
                     {"op": "-", "args": ["t", 100_000_000]}]}}
            ]
        }}
    })
}

#[test]
fn the_right_hand_side_reads_time_at_its_state_s_precision() {
    // 100000001 is not a binary32 number; it reads as 1e8 there.
    for (document, state, expected) in [("Float64", "Float32", 0.0), ("Float32", "Float64", 1.0)] {
        let doc = time_reading_document(document, state);
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            let prob = esm_problem(
                ProblemInput::Json(&doc),
                (0.0, 1.0),
                ProblemOptions {
                    compiler: Some(compiler),
                    ..ProblemOptions::default()
                },
            )
            .unwrap();
            let rhs = rhs_program(&prob).unwrap();
            let (u, aux) = rhs.default_state();
            let mut du = [f64::NAN];
            rhs.eval_into(
                &u,
                &aux,
                &[],
                100_000_001.0,
                &rhs.default_forcing(),
                &mut du,
                &mut rhs.new_workspace(),
            )
            .unwrap();
            assert_eq!(
                du,
                [expected],
                "{document} document, {state} state, {compiler:?}"
            );
        }
    }
}

#[test]
fn init_checks_only_the_output_times_the_caller_requested() {
    // Without `saveat`, `init` steps over a grid of its own whose points near
    // 1e8 share binary32 values; that is not a request for them, so `init`
    // accepts what `solve` accepts. This span is still shorter than diffsol's
    // binary32 stop-time resolution, so both refuse it once they step, for
    // that reason and the same one.
    let prob = esm_problem(
        ProblemInput::Json(&document()),
        (1e8, 1e8 + 500.0),
        ProblemOptions::default(),
    )
    .unwrap();
    let opts = SolveOptions {
        reltol: Some(1e-4),
        ..SolveOptions::default()
    };
    let solved = solve(&prob, &opts).unwrap_err().to_string();
    assert!(solved.contains("clock resolution"), "{solved}");
    let mut integrator = init(&prob, &opts).unwrap();
    let stepped = integrator.solve_to_completion().unwrap_err().to_string();
    assert_eq!(stepped, solved);
}

#[test]
fn a_repeated_output_time_is_one_clock_tick() {
    let prob = esm_problem(
        ProblemInput::Json(&document()),
        (0.0, 1.0),
        ProblemOptions::default(),
    )
    .unwrap();
    let opts = SolveOptions {
        reltol: Some(1e-4),
        saveat: Some(vec![0.0, 0.5, 0.5, 1.0]),
        ..SolveOptions::default()
    };
    let sol = solve(&prob, &opts).unwrap();
    assert!(sol.retcode.is_success());
    assert_eq!(sol.time, [0.0, 0.5, 0.5, 1.0]);
    init(&prob, &opts).unwrap();
}

#[test]
fn tile_and_lane_programs_round_their_inputs_as_the_whole_domain_does() {
    use earthsci_ast::{AxisCut, Decomposition, LaneKind, TileBox};
    let ix = json!({"op": "index", "args": ["x", "i"]});
    let doc = json!({
        "esm": "2.0.0",
        "metadata": {"name": "ArrayFloat32"},
        "domain": {"element_type": "Float32"},
        "index_sets": {"i": {"kind": "interval", "size": 2}},
        "models": {"M": {
            "variables": {
                "x": {"type": "unknown", "units": "1", "shape": ["i"], "default": [1.0, 2.0]},
                "c": {"type": "parameter", "units": "1/s", "default": 1.0}
            },
            "equations": [{
                "lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "i"}},
                        "expr": {"op": "D", "args": [ix.clone()], "wrt": "t"}},
                "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "i"}},
                        "expr": {"op": "ifelse", "args": [
                            {"op": ">", "args": [ix.clone(), 1.5]}, ix, "c"]}}
            }]
        }}
    });
    let prob = esm_problem(
        ProblemInput::Json(&doc),
        (0.0, 1.0),
        ProblemOptions::default(),
    )
    .unwrap();
    let rhs = rhs_program(&prob).unwrap();
    let u = [1.00000001, 2.00000001];
    let p = [1.00000001];
    let forcing = rhs.default_forcing();
    let mut whole = [f64::NAN; 2];
    rhs.eval_into(
        &u,
        &[],
        &p,
        0.0,
        &forcing,
        &mut whole,
        &mut rhs.new_workspace(),
    )
    .unwrap();
    // The selected values pass through no arithmetic.
    assert_eq!(whole, [1.0, 2.0]);

    let dec = Decomposition {
        axes: vec![AxisCut {
            index_set: "i".to_string(),
            period: None,
        }],
        faces: Vec::new(),
    };
    let tile_box = TileBox {
        owned: vec![("i".to_string(), 1..=2)],
        storage: vec![("i".to_string(), 1..=2)],
    };
    let tile = rhs.tile(&dec, &tile_box).unwrap();
    let mut du = [f64::NAN; 2];
    tile.eval_into(
        &u,
        &[],
        &p,
        0.0,
        &forcing,
        &mut du,
        &mut tile.new_workspace(),
    )
    .unwrap();
    assert_eq!(du, whole, "tile");

    let lanes = rhs
        .lanes(
            LaneKind::Cells {
                sets: vec!["i".to_string()],
            },
            2,
        )
        .unwrap();
    let cells = [1, 2];
    let mut ws = lanes.new_workspace();
    let mut du = [f64::NAN; 2];
    lanes
        .eval_into(&u, &[], &p, 0.0, &forcing, &cells, 2, &mut du, &mut ws)
        .unwrap();
    assert_eq!(du, whole, "lanes");
    let mut inputs = lanes.lane_inputs();
    lanes
        .gather_lane_inputs(&mut inputs, &p, 0.0, &forcing, &cells, 2)
        .unwrap();
    let mut du = [f64::NAN; 2];
    lanes
        .eval_gathered_into(&u, &[], &inputs, &p, 0.0, &cells, 2, &mut du, &mut ws)
        .unwrap();
    assert_eq!(du, whole, "gathered lanes");
}
