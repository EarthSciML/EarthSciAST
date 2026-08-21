//! A derived index set's `member_factor` must SURVIVE a parse→emit round-trip.
//!
//! `member_factor` is normative (CONFORMANCE_SPEC §5.5.6 "Derived-set
//! `member_factor` and `gated_select` pushdown"), is a declared property of
//! `esm-schema.json`, is carried by the Julia reference's `IndexSet`, and is
//! used by the SHARED cross-language fixture
//! `tests/fixtures/pushdown/overlap_gate_point_in_rect.esm`.
//!
//! The Rust `IndexSet` did not model it. Because the type does not
//! `deny_unknown_fields`, parsing SILENTLY DROPPED it — no error, no warning —
//! so a document that round-tripped through the Rust binding came out missing
//! the field that tells the build which const factor receives the invented
//! members. Nothing downstream could then wire Hook 1, and the loss was
//! invisible at the point it happened.
//!
//! These tests pin both halves: the field is read, and it is written back.

use earthsci_ast::parse;
use earthsci_ast::serialize;

const FIXTURE: &str = include_str!("fixtures/pushdown/overlap_gate_point_in_rect.esm");

#[test]
fn member_factor_is_parsed_from_a_derived_set() {
    let file = parse::load(FIXTURE).expect("fixture parses");
    let sets = file
        .index_sets
        .as_ref()
        .expect("document declares index_sets");
    let derived = sets
        .get("emis_src_cells")
        .expect("fixture declares emis_src_cells");

    assert_eq!(derived.kind, "derived");
    assert_eq!(derived.from_faq.as_deref(), Some("emis_src_cells_faq"));
    assert_eq!(
        derived.member_factor.as_deref(),
        Some("src_cell_of_ppl"),
        "member_factor must be read, not silently dropped"
    );
}

#[test]
fn member_factor_survives_a_round_trip() {
    let file = parse::load(FIXTURE).expect("fixture parses");
    let emitted = serialize::save(&file).expect("serializes");

    // Re-parse rather than string-match, so the assertion is about the DOCUMENT
    // rather than about formatting.
    let again = parse::load(&emitted).expect("re-parses");
    let derived = again
        .index_sets
        .as_ref()
        .and_then(|s| s.get("emis_src_cells"))
        .expect("emis_src_cells survives");

    assert_eq!(
        derived.member_factor.as_deref(),
        Some("src_cell_of_ppl"),
        "member_factor must survive parse→emit; dropping it loses the Hook-1 wiring"
    );
    assert!(
        emitted.contains("member_factor"),
        "the emitted JSON must actually carry the field"
    );
}

#[test]
fn a_set_without_member_factor_does_not_gain_one() {
    // `skip_serializing_if` keeps ordinary sets byte-identical: an interval set
    // must not sprout a null `member_factor` key.
    let file = parse::load(FIXTURE).expect("fixture parses");
    let sets = file.index_sets.as_ref().expect("index_sets");
    let pop = sets.get("pop_cells").expect("fixture declares pop_cells");
    assert_eq!(pop.kind, "interval");
    assert!(pop.member_factor.is_none());

    let emitted = serialize::save(&file).expect("serializes");
    let doc: serde_json::Value = serde_json::from_str(&emitted).expect("valid JSON");
    assert!(
        doc["index_sets"]["pop_cells"]
            .get("member_factor")
            .is_none(),
        "an ordinary interval set must not gain a member_factor key"
    );
}
