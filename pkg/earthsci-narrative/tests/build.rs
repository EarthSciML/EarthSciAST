//! End-to-end: documents in, per-element and per-construct output out.

use earthsci_ast::DocumentFormat;
use earthsci_narrative::build::{
    BuildOptions, BuildOutput, build_document, build_json, build_onto, build_text,
};
use earthsci_narrative::plot_data::PlotData;
use serde_json::{Value, json};

fn run(doc: Value, svg: bool) -> BuildOutput {
    let opts = BuildOptions {
        render_svg: svg,
        ..Default::default()
    };
    build_json(&doc.to_string(), &opts)
}

fn decay() -> Value {
    json!({
        "version": 1,
        "name": "Decay",
        "elements": [
            {"kind": "model", "name": "Decay", "description": "First-order decay"},
            {"kind": "var", "name": "N", "default": 100, "units": "mol",
             "description": "Amount of nitrogen", "source": {"file": "decay.md", "line": 3, "column": 9}},
            {"kind": "param", "name": "lambda", "default": 0.1, "units": "1/s"},
            {"kind": "eq", "math": "(dif N)/(dif t) = -lambda N", "label": "eq-decay"},
            {"kind": "test", "id": "half-life", "time_span": {"start": 0, "end": 10},
             "assertions": [{"variable": "N", "time": 6.931471805599453, "expected": 50,
                             "tolerance": {"rel": 1e-3}}]},
            {"kind": "plot", "id": "decay", "time_span": {"start": 0, "end": 50}, "y": "N",
             "description": "Decay of N."},
            {"kind": "plot", "id": "rates", "time_span": {"start": 0, "end": 50}, "y": "N",
             "parameter_sweep": {"type": "cartesian",
                 "dimensions": [{"parameter": "lambda", "values": [0.05, 0.1, 0.2]}]},
             "interactive": [{"parameter": "lambda", "min": 0.01, "max": 1, "scale": "log"}]}
        ]
    })
}

#[test]
fn decay_builds_clean() {
    let out = run(decay(), false);
    assert!(out.ok, "{:#?}", out.diagnostics);
    assert!(out.diagnostics.is_empty(), "{:#?}", out.diagnostics);
    assert_eq!(out.elements.len(), 7);

    let n = out.elements[1].math.as_ref().unwrap();
    assert_eq!((n.typst.as_str(), n.latex.as_str()), ("N", "N"));
    // The core's printers, the notation of the ESM Markdown and Typst formats.
    let eq = out.elements[3].math.as_ref().unwrap();
    assert!(eq.typst.starts_with("(dif N)/(dif t) = "), "{}", eq.typst);
    assert!(eq.typst.contains("lambda"), "{}", eq.typst);
    assert!(
        eq.latex
            .starts_with("\\frac{\\mathrm{d} N}{\\mathrm{d} t} = "),
        "{}",
        eq.latex
    );
    let lambda = out.elements[2].math.as_ref().unwrap();
    assert_eq!(
        (lambda.typst.as_str(), lambda.latex.as_str()),
        ("lambda", "\\lambda")
    );

    let test = out.elements[4].test.as_ref().unwrap();
    assert!(test.passed, "{test:#?}");
    assert_eq!(test.assertions.len(), 1);

    let figure = &out.elements[5].figures[0];
    assert_eq!(figure.id, "decay");
    let PlotData::Line(line) = &figure.data else {
        panic!()
    };
    assert_eq!(line.series.len(), 1);
    let last = line.series[0].y.last().unwrap().unwrap();
    assert!((last - 100.0 * (-5.0f64).exp()).abs() < 1e-2, "{last}");
    assert_eq!(line.y.display_label(), "N (mol)");

    let PlotData::Line(sweep) = &out.elements[6].figures[0].data else {
        panic!()
    };
    assert_eq!(sweep.series.len(), 3);
    assert_eq!(
        sweep.series[2].sweep_point,
        vec![("lambda".to_string(), 0.2)]
    );

    let n = out.quantities.iter().find(|q| q.name == "N").unwrap();
    assert_eq!(serde_json::to_value(n.role).unwrap(), "state");
    let narrative = &out.esm["metadata"]["x_esd"]["narrative"];
    assert_eq!(narrative["labels"]["eq-decay"], "/models/Decay/equations/0");
    assert!(narrative["interactive"]["/models/Decay/analyses/1/plots/0"].is_array());
}

#[test]
fn problems_land_on_their_elements() {
    let mut doc = decay();
    let elements = doc["elements"].as_array_mut().unwrap();
    // A test that fails, a misspelled name, and an element with a bad field.
    elements[4]["assertions"][0]["expected"] = json!(60);
    elements[3]["math"] = json!("(dif N)/(dif t) = -lambda N - L");
    elements.push(json!({"kind": "var", "nmae": "Q", "source": {"line": 40}}));
    let out = run(doc, false);
    assert!(!out.ok);
    let found: Vec<(Option<usize>, &str)> = out
        .diagnostics
        .iter()
        .map(|d| (d.element, d.code.as_str()))
        .collect();
    assert!(found.contains(&(Some(3), "undeclared_name")), "{found:?}");
    assert!(found.contains(&(Some(7), "invalid_element")), "{found:?}");
    assert!(out.elements[3].has_errors);
    assert_eq!(out.elements[7].kind, "var");
    assert_eq!(
        out.diagnostics
            .last()
            .unwrap()
            .source
            .as_ref()
            .unwrap()
            .line,
        Some(40)
    );
    // The undeclared name breaks the model, so its test and plots were not
    // run; fix it and the failing test is reported instead.
    assert!(out.elements[4].test.is_none());
    assert!(out.elements[4].skipped && out.elements[5].skipped);
    assert!(!out.elements[3].skipped);

    let mut doc = decay();
    doc["elements"][4]["assertions"][0]["expected"] = json!(60);
    let out = run(doc, false);
    let failed: Vec<_> = out
        .diagnostics
        .iter()
        .filter(|d| d.code == "test_failed")
        .collect();
    assert_eq!(failed.len(), 1, "{:#?}", out.diagnostics);
    assert_eq!(failed[0].element, Some(4));
    assert!(
        failed[0].message.contains("expected 60"),
        "{}",
        failed[0].message
    );
    assert!(!out.elements[4].test.as_ref().unwrap().passed);
    assert!(!out.ok);
}

#[test]
fn two_box_exchange() {
    let doc = json!({
        "version": 1,
        "elements": [
            {"kind": "model", "name": "TwoBox"},
            // A leading minus negates only its own term; read as
            // `-(k_ab A + k_ba B)`, both boxes would drain and the equilibrium
            // test below would fail.
            {"kind": "eq", "math": "(dif A)/(dif t) = -k_(upright(\"ab\")) A + k_(upright(\"ba\")) B"},
            {"kind": "eq", "math": "(dif B)/(dif t) = k_(upright(\"ab\")) A - k_(upright(\"ba\")) B"},
            {"kind": "var", "name": "A", "default": 1, "units": "mol"},
            {"kind": "var", "name": "B", "default": 0, "units": "mol"},
            {"kind": "param", "name": "k_ab", "default": 0.3, "units": "1/s"},
            {"kind": "param", "name": "k_ba", "default": 0.1, "units": "1/s"},
            {"kind": "test", "id": "equilibrium", "time_span": {"start": 0, "end": 100},
             "assertions": [{"variable": "B", "time": 100, "expected": 0.75,
                             "tolerance": {"rel": 1e-3}}]},
            {"kind": "plot", "id": "boxes", "time_span": {"start": 0, "end": 20}, "y": ["A", "B"]},
            {"kind": "analysis", "id": "rates", "time_span": {"start": 0, "end": 100},
             "parameter_sweep": {"type": "cartesian", "dimensions": [
                 {"parameter": "k_ab", "range": {"start": 0.1, "stop": 1, "count": 4}},
                 {"parameter": "k_ba", "range": {"start": 0.01, "stop": 1, "count": 3, "scale": "log"}}]},
             "plots": [{"id": "final_B", "type": "heatmap", "x": {"variable": "k_ab"},
                        "y": {"variable": "k_ba"}, "value": {"variable": "B", "reduce": "final"}}]}
        ]
    });
    let out = run(doc, true);
    assert!(out.ok, "{:#?}", out.diagnostics);
    assert!(out.elements[7].test.as_ref().unwrap().passed);

    let PlotData::Line(boxes) = &out.elements[8].figures[0].data else {
        panic!()
    };
    let names: Vec<_> = boxes.series.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(names, ["A", "B"]);
    // Mass is conserved at every sample.
    for (a, b) in boxes.series[0].y.iter().zip(&boxes.series[1].y) {
        assert!((a.unwrap() + b.unwrap() - 1.0).abs() < 1e-4);
    }

    // The heatmap is drawn for the analysis element that holds it.
    let figure = &out.elements[9].figures[0];
    let PlotData::Heatmap(h) = &figure.data else {
        panic!()
    };
    assert_eq!((h.x.values.len(), h.y.values.len()), (4, 3));
    // At equilibrium B = k_ab / (k_ab + k_ba).
    for (row, k_ba) in h.y.values.iter().enumerate() {
        for (col, k_ab) in h.x.values.iter().enumerate() {
            let expected = k_ab / (k_ab + k_ba);
            let got = h.z[row][col].unwrap();
            // The slowest pair has not quite settled by t = 100.
            assert!(
                (got - expected).abs() < 2e-2,
                "k_ab={k_ab} k_ba={k_ba}: {got} vs {expected}"
            );
        }
    }
    let svg = figure.svg.as_ref().unwrap();
    assert!(svg.starts_with("<svg"), "{}", &svg[..svg.len().min(80)]);
}

#[test]
fn unreadable_documents() {
    let out = build_json("{", &BuildOptions::default());
    assert!(!out.ok);
    assert_eq!(out.diagnostics[0].code, "invalid_document");
    let out = build_json(
        r#"{"version": 9, "elements": []}"#,
        &BuildOptions::default(),
    );
    assert!(out.diagnostics[0].message.contains("version 9"));
}

/// The decay model as an ESM Markdown document, with a test of its own.
const DECAY_MD: &str = r#"---
esm: "2.2.0"
name: "decay"
---

::model[Decay]

:var[$N$]{default=100 units="mol"}

:param[$\lambda$]{default=0.1 units="1/s"}

$$
\frac{\mathrm{d} N}{\mathrm{d} t} = -\lambda N
$$

```esm:tests
- assertions:
    - expected: 50
      time: 6.931471805599453
      tolerance:
        rel: 0.001
      variable: "N"
  id: "half-life"
  time_span:
    end: 10
    start: 0
```
"#;

#[test]
fn a_document_read_by_the_core_runs_its_own_tests() {
    let out = build_text(DECAY_MD, DocumentFormat::Markdown, &BuildOptions::default());
    assert!(out.ok, "{:#?}", out.diagnostics);
    assert!(out.elements.is_empty());
    assert_eq!(out.constructs.len(), 1, "{:#?}", out.constructs);
    assert_eq!(out.constructs[0].path, "/models/Decay/tests/0");
    assert!(out.constructs[0].test.as_ref().unwrap().passed);
    let roles: Vec<_> = out
        .quantities
        .iter()
        .map(|q| (q.name.as_str(), serde_json::to_value(q.role).unwrap()))
        .collect();
    assert!(roles.contains(&("N", json!("state"))), "{roles:?}");
    assert!(roles.contains(&("lambda", json!("parameter"))), "{roles:?}");

    // A failing test the document writes is reported at its path.
    let failing = DECAY_MD.replace("expected: 50", "expected: 60");
    let out = build_text(&failing, DocumentFormat::Markdown, &BuildOptions::default());
    assert!(!out.ok);
    let d = out
        .diagnostics
        .iter()
        .find(|d| d.code == "test_failed")
        .unwrap();
    assert_eq!(d.element, None);
    assert_eq!(d.path.as_deref(), Some("/models/Decay/tests/0"));
}

#[test]
fn text_the_core_refuses_is_one_diagnostic() {
    let out = build_text(
        "not a document",
        DocumentFormat::Markdown,
        &BuildOptions::default(),
    );
    assert!(!out.ok);
    assert_eq!(out.diagnostics.len(), 1);
    assert_eq!(out.diagnostics[0].code, "parse_error");
}

#[test]
fn elements_add_tests_and_plots_to_a_document() {
    let esm: Value = earthsci_ast::parse_markdown(DECAY_MD).unwrap();
    let elements = json!({"version": 1, "elements": [
        {"kind": "test", "id": "early", "model": "Decay", "time_span": {"start": 0, "end": 1},
         "assertions": [{"variable": "N", "time": 0, "expected": 100}]},
        {"kind": "plot", "id": "decay", "model": "Decay", "time_span": {"start": 0, "end": 50}, "y": "N",
         "interactive": [{"parameter": "lambda", "min": 0.01, "max": 1}]},
        // The document already has this one.
        {"kind": "test", "id": "half-life", "model": "Decay", "time_span": {"start": 0, "end": 1},
         "assertions": [{"variable": "N", "time": 0, "expected": 100}]},
        // Declarations are the document's own.
        {"kind": "var", "name": "M", "model": "Decay"},
    ]});
    let out = build_onto(esm, elements, &BuildOptions::default());
    let found: Vec<(Option<usize>, &str)> = out
        .diagnostics
        .iter()
        .map(|d| (d.element, d.code.as_str()))
        .collect();
    assert_eq!(
        found,
        [(Some(2), "duplicate_id"), (Some(3), "not_an_addition")],
        "{:#?}",
        out.diagnostics
    );
    // After the document's own test.
    let tests = out.esm["models"]["Decay"]["tests"].as_array().unwrap();
    assert_eq!(tests[0]["id"], "half-life");
    assert_eq!(tests[1]["id"], "early");
    assert_eq!(
        out.elements[0].info.path.as_deref(),
        Some("/models/Decay/tests/1")
    );
    assert!(out.elements[0].test.as_ref().unwrap().passed);
    assert_eq!(out.elements[1].figures.len(), 1);
    assert!(
        out.esm["metadata"]["x_esd"]["narrative"]["interactive"]
            ["/models/Decay/analyses/0/plots/0"]
            .is_array()
    );
    // The document's own test ran too.
    assert!(out.constructs[0].test.as_ref().unwrap().passed);
}

#[test]
fn a_document_as_json_builds() {
    let esm: Value = earthsci_ast::parse_markdown(DECAY_MD).unwrap();
    let out = build_document(esm, &BuildOptions::default());
    assert!(out.ok, "{:#?}", out.diagnostics);
    assert_eq!(out.constructs.len(), 1);
}
