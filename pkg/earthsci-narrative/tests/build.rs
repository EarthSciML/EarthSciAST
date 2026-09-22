//! End-to-end: element documents in, per-element output out.

use earthsci_narrative::build::{BuildOptions, BuildOutput, build_json};
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
            {"kind": "eq", "text": "D(N, t) = -lambda*N", "label": "eq-decay"},
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
    assert_eq!(
        (n.typst.as_str(), n.latex.as_str(), n.unicode.as_str()),
        ("N", "N", "N")
    );
    let eq = out.elements[3].math.as_ref().unwrap();
    assert_eq!(eq.typst, "frac(partial N, partial t) = -lambda dot.op N");
    assert!(
        eq.latex.starts_with("\\frac{\\partial N}{\\partial t}"),
        "{}",
        eq.latex
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
    elements[3]["text"] = json!("D(N, t) = -lambda*N - lamda");
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
            {"kind": "eq", "text": "D(A, t) = k_ba*B - k_ab*A"},
            {"kind": "eq", "text": "D(B, t) = k_ab*A - k_ba*B"},
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
