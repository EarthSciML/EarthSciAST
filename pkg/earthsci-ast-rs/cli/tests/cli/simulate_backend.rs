//! `esm simulate --backend`: which time integrator runs a dynamic document,
//! and the refusals of a backend, or an option, the build cannot honor.
//!
//! The document is written at run time: `u' = -k u + sin(ω t)`, `u(0) = 1`,
//! EarthSciIntegrator's `forced_decay` toy (its spec/toy-problems.md §1.1),
//! which has a closed form. It is written in esm 1.3.0 so the integrator's own
//! `earthsci-ast` (0.10, which reads esm 1.x only) reads it too.

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

/// A 3 × 2 grid in esm 1.3.0: `c[i,j]' = i + 10 j`, `c(0) = 0`, so every
/// cell has its own trajectory `(i + 10 j) t` and a column written under
/// another cell's name shows. The two index sets differ in size, so a layout
/// that ran the first index fastest on one side and the last on the other
/// would put a cell's values under another cell's name.
#[cfg(feature = "integrator")]
const GRID: &str = r#"{
  "esm": "1.3.0",
  "metadata": {"name": "grid_ramp"},
  "index_sets": {"x": {"kind": "interval", "size": 3}, "y": {"kind": "interval", "size": 2}},
  "models": {
    "Ramp": {
      "variables": {
        "c": {"type": "unknown", "units": "1", "default": 0.0, "shape": ["x", "y"]}
      },
      "equations": [
        {
          "lhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
                  "ranges": {"i": [1, 3], "j": [1, 2]},
                  "expr": {"op": "D", "args": [{"op": "index", "args": ["c", "i", "j"]}], "wrt": "t"}},
          "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
                  "ranges": {"i": [1, 3], "j": [1, 2]},
                  "expr": {"op": "+", "args": ["i", {"op": "*", "args": [10, "j"]}]}}
        }
      ]
    }
  }
}"#;

/// The exact solution of [`FORCED_DECAY`] at `t`.
#[cfg(feature = "integrator")]
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

/// [`FORCED_DECAY`] in the esm format this workspace writes (2.x).
#[cfg(feature = "integrator")]
fn document_current(dir: &Path) -> PathBuf {
    let path = dir.join("forced_decay_current.esm");
    let text = FORCED_DECAY.replace("\"1.3.0\"", &format!("{:?}", earthsci_ast::SCHEMA_VERSION));
    std::fs::write(&path, text).unwrap();
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

/// A build with no time integrator refuses only a document that integrates,
/// once it knows that (a static document evaluates: see
/// `cli_static_evaluation_output`), naming the features to build with.
#[cfg(not(any(feature = "diffsol", feature = "integrator")))]
#[test]
fn a_build_with_no_integrator_refuses_a_dynamic_document() {
    let dir = tempfile::tempdir().unwrap();
    let doc = document(dir.path());
    let out = esm(&["simulate", doc.to_str().unwrap()]);
    assert!(!out.status.success());
    let err = stderr(&out);
    assert!(err.contains("no time integrator"), "{err}");
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

    /// Integrator 0.0.1 is built on `earthsci-ast` 0.10, which reads esm 1.x
    /// only: an esm 2.x document is refused up front, saying so, rather than
    /// with the integrator's planner error.
    #[test]
    fn an_esm_2_document_is_refused_by_the_integrator_naming_the_limit() {
        let dir = tempfile::tempdir().unwrap();
        let doc = document_current(dir.path());
        let out = esm(&["simulate", doc.to_str().unwrap(), "--backend", "integrator"]);
        assert!(!out.status.success());
        let err = stderr(&out);
        assert!(err.contains("reads esm 1.x documents only"), "{err}");
        assert!(err.contains("--backend diffsol"), "{err}");
        assert!(!err.contains("Unsupported major version"), "{err}");
    }

    /// The integrator builds its own right-hand side, so the options that
    /// steer `earthsci-ast`'s are refused rather than silently ignored.
    #[test]
    fn compiler_options_are_refused_by_the_integrator() {
        let dir = tempfile::tempdir().unwrap();
        let doc = document(dir.path());
        for flag in [&["--compiler", "interpreter"][..], &["--no-count-fold"][..]] {
            let mut args = vec!["simulate", doc.to_str().unwrap(), "--backend", "integrator"];
            args.extend_from_slice(flag);
            let out = esm(&args);
            assert!(!out.status.success(), "{flag:?}");
            let err = stderr(&out);
            assert!(err.contains(flag[0]), "{flag:?}: {err}");
            assert!(err.contains("integrator backend builds its own"), "{err}");
        }
    }

    /// The integrator never evaluates `earthsci-ast`'s right-hand side, so
    /// its run prints no compiler report.
    #[test]
    fn the_integrator_run_prints_no_compiler_report() {
        let dir = tempfile::tempdir().unwrap();
        let doc = document(dir.path());
        let out = esm(&["simulate", doc.to_str().unwrap(), "--backend", "integrator"]);
        assert!(out.status.success(), "{}", stderr(&out));
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(!stdout.contains("taped"), "{stdout}");
        assert!(stdout.contains("integrator backend"), "{stdout}");
    }

    /// An array state: every column is the cell its name says, matched by
    /// name between the integrator's layout and `earthsci-ast`'s.
    #[test]
    fn array_state_columns_are_labeled_by_cell() {
        let dir = tempfile::tempdir().unwrap();
        let doc = dir.path().join("grid_ramp.esm");
        std::fs::write(&doc, GRID).unwrap();
        let out_json = dir.path().join("out.json");
        let out = esm(&[
            "simulate",
            doc.to_str().unwrap(),
            "--time",
            "1",
            "--backend",
            "integrator",
            "--dt",
            "0.25",
            "-o",
            out_json.to_str().unwrap(),
        ]);
        assert!(out.status.success(), "{}", stderr(&out));
        let (t, names, state) = trajectory(&out_json);
        assert_eq!(names.len(), 6, "{names:?}");
        assert_eq!(t.len(), 5, "{t:?}");
        for (name, series) in names.iter().zip(&state) {
            let idx = name
                .strip_prefix("Ramp.c[")
                .and_then(|r| r.strip_suffix(']'))
                .unwrap_or_else(|| panic!("column {name}"));
            let (i, j) = idx.split_once(',').unwrap();
            let rate = i.trim().parse::<f64>().unwrap() + 10.0 * j.trim().parse::<f64>().unwrap();
            for (ti, ci) in t.iter().zip(series) {
                assert!(
                    (ci - rate * ti).abs() < 1e-9,
                    "{name}({ti}) = {ci}, want {}",
                    rate * ti
                );
            }
        }
    }
}
