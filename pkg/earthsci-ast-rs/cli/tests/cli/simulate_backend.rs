//! `esm simulate --backend`: which time integrator runs a dynamic document,
//! and the refusals of a backend, or an option, the build cannot honor.
//!
//! The document is written at run time: `u' = -k u + sin(ω t)`, `u(0) = 1`,
//! EarthSciIntegrator's `forced_decay` toy (its spec/toy-problems.md §1.1),
//! which has a closed form. It is written in esm 1.3.0 so the integrator's own
//! `earthsci-ast`, which may trail this workspace's, reads it too.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const FORCED_DECAY: &str = r#"{
  "esm": "1.3.0",
  "metadata": {"name": "forced_decay"},
  "models": {
    "Decay": {
      "variables": {
        "u": {"type": "unknown", "default": 1},
        "k": {"type": "parameter", "default": 2},
        "omega": {"type": "parameter", "default": 3}
      },
      "equations": [
        {
          "lhs": {"op": "D", "args": ["u"], "wrt": "t"},
          "rhs": {"op": "+", "args": [
            {"op": "*", "args": [-1, "k", "u"]},
            {"op": "sin", "args": [{"op": "*", "args": ["omega", "t"]}]}
          ]}
        }
      ]
    }
  }
}"#;

/// The exact solution of [`FORCED_DECAY`] at `t`.
fn exact(t: f64) -> f64 {
    let (k, w) = (2.0_f64, 3.0_f64);
    let d = k * k + w * w;
    (1.0 + w / d) * (-k * t).exp() + (k * (w * t).sin() - w * (w * t).cos()) / d
}

fn document(dir: &Path) -> PathBuf {
    let path = dir.join("forced_decay.esm");
    std::fs::write(&path, FORCED_DECAY).unwrap();
    path
}

fn esm(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_esm"))
        .args(args)
        .output()
        .expect("run esm")
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

#[test]
fn an_unknown_backend_is_refused_naming_the_choices() {
    let dir = tempfile::tempdir().unwrap();
    let doc = document(dir.path());
    let out = esm(&["simulate", doc.to_str().unwrap(), "--backend", "lsoda"]);
    assert!(!out.status.success());
    let err = stderr(&out);
    assert!(err.contains("unknown backend \"lsoda\""), "{err}");
    assert!(err.contains("diffsol, integrator"), "{err}");
}

#[cfg(not(feature = "integrator"))]
#[test]
fn the_integrator_is_refused_by_a_build_without_it() {
    let dir = tempfile::tempdir().unwrap();
    let doc = document(dir.path());
    let out = esm(&["simulate", doc.to_str().unwrap(), "--backend", "integrator"]);
    assert!(!out.status.success());
    let err = stderr(&out);
    assert!(err.contains("--features integrator"), "{err}");
}

#[cfg(not(feature = "diffsol"))]
#[test]
fn diffsol_is_refused_by_a_build_without_it() {
    let dir = tempfile::tempdir().unwrap();
    let doc = document(dir.path());
    let out = esm(&["simulate", doc.to_str().unwrap(), "--backend", "diffsol"]);
    assert!(!out.status.success());
    let err = stderr(&out);
    assert!(err.contains("--features diffsol"), "{err}");
}

#[cfg(feature = "diffsol")]
#[test]
fn integrator_options_are_refused_with_diffsol() {
    let dir = tempfile::tempdir().unwrap();
    let doc = document(dir.path());
    let out = esm(&[
        "simulate",
        doc.to_str().unwrap(),
        "--backend",
        "diffsol",
        "--dt",
        "0.1",
    ]);
    assert!(!out.status.success());
    let err = stderr(&out);
    assert!(err.contains("configure the `integrator` backend"), "{err}");
}

#[cfg(feature = "integrator")]
mod integrator {
    use super::*;

    fn trajectory(path: &Path) -> (Vec<f64>, Vec<String>, Vec<Vec<f64>>) {
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let f = |x: &serde_json::Value| x.as_f64().unwrap();
        (
            v["time"].as_array().unwrap().iter().map(f).collect(),
            v["state_variable_names"]
                .as_array()
                .unwrap()
                .iter()
                .map(|s| s.as_str().unwrap().to_string())
                .collect(),
            v["state"]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r.as_array().unwrap().iter().map(f).collect())
                .collect(),
        )
    }

    /// The default run: one leaf over every operator, fixed macro steps of
    /// `--dt`, the state written at the start and every boundary, under the
    /// same column name the diffsol backend writes.
    #[test]
    fn the_integrator_matches_the_closed_form() {
        let dir = tempfile::tempdir().unwrap();
        let doc = document(dir.path());
        let out_json = dir.path().join("out.json");
        let plan = dir.path().join("plan");
        let out = esm(&[
            "simulate",
            doc.to_str().unwrap(),
            "--time",
            "2",
            "--backend",
            "integrator",
            "--dt",
            "0.1",
            "--plan-dir",
            plan.to_str().unwrap(),
            "-o",
            out_json.to_str().unwrap(),
        ]);
        assert!(out.status.success(), "{}", stderr(&out));
        assert!(
            plan.join("plan.json").is_file(),
            "--plan-dir keeps the plan"
        );
        let (t, names, state) = trajectory(&out_json);
        assert_eq!(names, ["Decay.u"]);
        assert_eq!(t.len(), 21, "{t:?}");
        assert_eq!((t[0], t[20]), (0.0, 2.0));
        for (ti, ui) in t.iter().zip(&state[0]) {
            assert!(
                (ui - exact(*ti)).abs() < 1e-6,
                "u({ti}) = {ui}, exact {}",
                exact(*ti)
            );
        }
    }

    #[test]
    fn a_run_config_for_another_document_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let doc = document(dir.path());
        let other = dir.path().join("other.esm");
        std::fs::write(&other, FORCED_DECAY).unwrap();
        let rc = dir.path().join("run.json");
        std::fs::write(
            &rc,
            r#"{"esm_integrator": "0.1.0", "model": "other.esm", "schedule": "auto", "step": {"dt": 0.1}}"#,
        )
        .unwrap();
        let out = esm(&[
            "simulate",
            doc.to_str().unwrap(),
            "--backend",
            "integrator",
            "--run-config",
            rc.to_str().unwrap(),
        ]);
        assert!(!out.status.success());
        let err = stderr(&out);
        assert!(
            err.contains("integrates") && err.contains("other.esm"),
            "{err}"
        );
    }

    #[test]
    fn observed_output_is_refused_by_the_integrator() {
        let dir = tempfile::tempdir().unwrap();
        let doc = document(dir.path());
        let out = esm(&[
            "simulate",
            doc.to_str().unwrap(),
            "--backend",
            "integrator",
            "--observed",
            "Decay.u",
        ]);
        assert!(!out.status.success());
        assert!(stderr(&out).contains("--observed"), "{}", stderr(&out));
    }
}
