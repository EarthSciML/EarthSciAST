//! End-to-end: a Markdown page in, a built page and an `.esm` file out.

use earthsci_narrative::build::{BuildOptions, BuildOutput, build_value};
use earthsci_narrative::markdown::{self, Page, RenderOptions};

fn build(source: &str) -> (Page, BuildOutput, String) {
    let page = markdown::parse(source, "page.md", "Page");
    let mut out = build_value(page.document(), &BuildOptions::default());
    out.diagnostics.extend(page.diagnostics.iter().cloned());
    let rendered = markdown::render(
        &page,
        &out,
        &RenderOptions {
            esm_href: Some("/narrative/page.esm".to_string()),
            esm_name: "page.esm".to_string(),
            generated_by: None,
        },
    );
    (page, out, rendered)
}

const DECAY: &str = r#"---
title: Decay
---

::model[Decay]{description="First-order decay"}

Nitrogen :var[N]{default=100 units="mol" description="Amount of nitrogen"} decays
at rate :param[lambda]{default=0.1 units="1/s"}:

::eq[D(N, t) = -lambda*N]{#eq-decay}

::esm-variables{}

:::esm-test{#half-life span="0..10"}
assertions:
  - variable: N
    time: 6.931471805599453
    expected: 50
    tolerance: {rel: 0.001}
:::

:::esm-plot{#decay span="0..50" y=N sliders="lambda=0.01..1 log"}
description: Decay of N.
:::

::esm-download{}
"#;

#[test]
fn a_page_builds_into_a_page() {
    let (page, out, md) = build(DECAY);
    assert!(out.ok, "{:#?}", out.diagnostics);
    assert_eq!(page.elements.len(), 6);

    // Front matter is passed through untouched.
    assert!(md.starts_with("---\ntitle: Decay\n---\n"), "{md}");
    // Mathematics, in the delimiters the docs site renders.
    assert!(md.contains("Nitrogen \\(N\\) decays"), "{md}");
    assert!(md.contains("at rate \\(\\lambda\\):"), "{md}");
    assert!(
        md.contains("<a id=\"eq-decay\" class=\"esm-eq\"></a>"),
        "{md}"
    );
    assert!(
        md.contains("\\[\n\\frac{\\partial N}{\\partial t} = -\\lambda \\cdot N\n\\]"),
        "{md}"
    );
    // The variables table.
    assert!(
        md.contains("| \\(N\\) | state | 100 | mol | Amount of nitrogen |"),
        "{md}"
    );
    // The test ran.
    assert!(md.contains("Test <code>half-life</code> passed"), "{md}");
    // The figure is inline, and carries what an interactive figure needs.
    assert!(
        md.contains("<figure class=\"esm-figure\" id=\"fig-decay\">"),
        "{md}"
    );
    assert!(md.contains("data-sliders="), "{md}");
    assert!(md.contains("<svg xmlns="), "{md}");
    assert!(md.contains("<figcaption>Decay of N.</figcaption>"), "{md}");
    assert!(md.contains("href=\"/narrative/page.esm\""), "{md}");

    // And the `.esm` file the page defines.
    assert_eq!(
        out.esm["models"]["Decay"]["variables"]["N"]["default"],
        100.0
    );
    assert_eq!(
        out.esm["metadata"]["x_esd"]["narrative"]["labels"]["eq-decay"],
        "/models/Decay/equations/0"
    );
}

#[test]
fn a_failing_test_fails_the_page_and_shows_where() {
    let source = DECAY.replace("expected: 50", "expected: 60");
    let (_, out, md) = build(&source);
    assert!(!out.ok);
    assert!(md.contains("esm-test--fail"), "{md}");
    assert!(md.contains("error[test_failed]"), "{md}");
    let failed: Vec<_> = out
        .diagnostics
        .iter()
        .filter(|d| d.code == "test_failed")
        .collect();
    assert_eq!(failed.len(), 1);
    // The diagnostic points at the page, at the line the test is on.
    let source_span = failed[0].source.as_ref().unwrap();
    assert_eq!(source_span.file.as_deref(), Some("page.md"));
    assert_eq!(source_span.line, Some(14));
}

#[test]
fn an_undeclared_name_points_at_its_equation() {
    let source = DECAY.replace("-lambda*N", "-lamda*N");
    let (_, out, md) = build(&source);
    assert!(!out.ok);
    let d = out
        .diagnostics
        .iter()
        .find(|d| d.code == "undeclared_name")
        .expect("an undeclared name");
    assert_eq!(d.source.as_ref().unwrap().line, Some(10));
    assert!(d.message.contains("lamda"), "{}", d.message);
    // The problem is shown on the page, and the test that would have run
    // against a broken model is not run.
    assert!(md.contains("error[undeclared_name]"), "{md}");
    assert!(md.contains("esm-problem--skipped"), "{md}");
}

#[test]
fn a_page_with_no_model_still_renders_examples() {
    let (page, out, md) = build("Text.\n\n::esm-example[a + b*c]\n");
    assert!(page.elements.is_empty());
    assert!(out.ok, "{:#?}", out.diagnostics);
    assert!(md.contains("```text\na + b*c\n```"), "{md}");
    assert!(md.contains("a + b \\cdot c"), "{md}");
    assert!(md.contains("\"op\": \"+\""), "{md}");
}

#[test]
fn a_malformed_directive_is_reported_at_its_line() {
    let (_, _, md) = build("Text.\n\n:::esm-test{#t}\nassertions: [\n:::\n");
    assert!(md.contains("error[bad_directive]"), "{md}");
    let page = markdown::parse(
        "Text.\n\n:::esm-test{#t}\nassertions: [\n:::\n",
        "page.md",
        "P",
    );
    assert_eq!(page.diagnostics[0].source.as_ref().unwrap().line, Some(3));
}
