//! EarthSciData.jl acceptance coverage test (gt-0c7 mayor amendment).
//!
//! Verifies that the new STAC-like DataSource schema can express every data
//! loader currently implemented in EarthSciData.jl. Each fixture under
//! `tests/fixtures/data_sources/` hand-constructs an instantiation of one
//! EarthSciData.jl `FileSet` struct using the schema's
//! kind/source/temporal/grid/variables fields. The fixture
//! header documents which EarthSciData.jl file and line range it corresponds
//! to.
//!
//! The test checks, for each fixture:
//!
//!  1. It validates against the schema (no schema errors).
//!  2. It round-trips through parse -> serialize -> parse without losing the
//!     DataSource block.
//!  3. Basic invariants on the new schema fields (at least one data source,
//!     each with a non-empty url_template) and on the CONSUMING parameters,
//!     which from esm 1.0.0 are where the file-variable bindings and the units
//!     live.

use earthsci_ast::{DataSourceKind, EsmFile, load, save};

struct Fixture {
    /// Short name used in assertion messages.
    name: &'static str,
    /// Embedded .esm JSON string.
    content: &'static str,
    /// Schema-level variable names expected inside this fixture's data_sources
    /// block (flattened across all loader entries).
    expected_variables: &'static [&'static str],
}

const FIXTURES: &[Fixture] = &[
    Fixture {
        name: "GEOSFP",
        content: include_str!("fixtures/data_sources/geosfp.esm"),
        expected_variables: &["U", "V", "T", "PS", "PBLH"],
    },
    Fixture {
        name: "ERA5_PressureLevels",
        content: include_str!("fixtures/data_sources/era5.esm"),
        expected_variables: &["t", "u", "v", "w", "q", "z", "o3"],
    },
    Fixture {
        name: "WRF_Regional",
        content: include_str!("fixtures/data_sources/wrf.esm"),
        expected_variables: &["U", "V", "T", "P", "QVAPOR", "PBLH"],
    },
    Fixture {
        name: "NEI2016Monthly",
        content: include_str!("fixtures/data_sources/nei2016monthly.esm"),
        expected_variables: &["NO", "NO2", "CO", "SO2", "NH3", "ISOP"],
    },
    Fixture {
        name: "CEDS",
        content: include_str!("fixtures/data_sources/ceds.esm"),
        expected_variables: &["BC", "CO", "CH4", "NH3", "NMVOC", "NOx", "OC", "SO2"],
    },
    Fixture {
        name: "EDGARv81Monthly",
        content: include_str!("fixtures/data_sources/edgar.esm"),
        expected_variables: &[
            "BC", "CO", "NH3", "NMVOC", "NOx", "OC", "PM10", "PM25", "SO2",
        ],
    },
    Fixture {
        name: "USGS3DEP (elevation + slopes)",
        content: include_str!("fixtures/data_sources/usgs3dep.esm"),
        expected_variables: &["elevation", "dzdx", "dzdy"],
    },
    Fixture {
        name: "LANDFIRE",
        content: include_str!("fixtures/data_sources/landfire.esm"),
        expected_variables: &["fuel_model"],
    },
];

fn load_fixture(fx: &Fixture) -> EsmFile {
    load(fx.content).unwrap_or_else(|e| {
        panic!(
            "EarthSciData fixture '{}' failed to load against the DataSource \
             schema. This indicates the new schema cannot express this loader \
             and is a schema gap that must be reported back to the Mayor. \
             Parse error: {}",
            fx.name, e
        )
    })
}

#[test]
fn every_earthscidata_loader_validates_against_schema() {
    for fx in FIXTURES {
        let _ = load_fixture(fx);
    }
}

#[test]
fn every_earthscidata_loader_round_trips_without_loss() {
    for fx in FIXTURES {
        let parsed = load_fixture(fx);
        let serialized =
            save(&parsed).unwrap_or_else(|e| panic!("{}: serialize failed: {}", fx.name, e));
        let reparsed: EsmFile =
            load(&serialized).unwrap_or_else(|e| panic!("{}: reparse failed: {}", fx.name, e));

        let loaders1 = parsed
            .data_sources
            .as_ref()
            .unwrap_or_else(|| panic!("{}: no data_sources block in fixture", fx.name));
        let loaders2 = reparsed
            .data_sources
            .as_ref()
            .unwrap_or_else(|| panic!("{}: no data_sources block after round-trip", fx.name));

        assert_eq!(
            loaders1.len(),
            loaders2.len(),
            "{}: data_sources count changed across round-trip",
            fx.name
        );

        for (name, dl1) in loaders1 {
            let dl2 = loaders2
                .get(name)
                .unwrap_or_else(|| panic!("{}: loader '{}' disappeared", fx.name, name));
            assert_eq!(
                dl1.temporal.is_some(),
                dl2.temporal.is_some(),
                "{}/{}: temporal block changed",
                fx.name,
                name
            );
            assert_eq!(
                dl1.source.url_template, dl2.source.url_template,
                "{}/{}: url_template changed",
                fx.name, name
            );
        }
    }
}

#[test]
fn every_earthscidata_loader_has_expected_variables() {
    for fx in FIXTURES {
        let parsed = load_fixture(fx);
        let loaders = parsed
            .data_sources
            .as_ref()
            .unwrap_or_else(|| panic!("{}: no data_sources", fx.name));
        assert!(
            !loaders.is_empty(),
            "{}: data_sources block must contain at least one loader",
            fx.name
        );

        // Flatten every variable across every loader in the fixture.
        let mut all_vars: std::collections::HashSet<String> = std::collections::HashSet::new();
        for (loader_name, dl) in loaders {
            assert!(
                !dl.source.url_template.is_empty(),
                "{}/{}: url_template is empty",
                fx.name,
                loader_name
            );
            // Kind must be one of the enum variants — exercise the enum so
            // a future deserialization regression is caught here.
            match dl.kind {
                DataSourceKind::Grid | DataSourceKind::Points | DataSourceKind::Static => {}
            }
            let _ = loader_name;
        }

        // From esm 1.0.0 a source declares no variables: the CONSUMING
        // PARAMETER carries `update: {kind: "data", source, from}` and owns the
        // units (esm-spec 5.4, 8.5). So the fixture's coverage is read off the
        // model's parameters, not off the source.
        for model in parsed.models.iter().flatten().map(|(_, m)| m) {
            for (vname, var) in &model.variables {
                let Some(update) = &var.update else { continue };
                let bindings: Vec<&earthsci_ast::DataSourceBinding> = update
                    .rules()
                    .iter()
                    .filter(|r| r.data_source().is_some())
                    .filter_map(|r| r.value().and_then(|v| v.from.as_ref()))
                    .collect();
                if bindings.is_empty() {
                    continue;
                }
                for binding in bindings {
                    assert!(
                        !binding.file_variable.is_empty(),
                        "{}/{}: file_variable is empty",
                        fx.name,
                        vname
                    );
                }
                assert!(
                    var.units.as_deref().is_some_and(|u| !u.is_empty()),
                    "{}/{}: a source-fed parameter must declare its own units",
                    fx.name,
                    vname
                );
                all_vars.insert(vname.clone());
            }
        }

        for expected in fx.expected_variables {
            assert!(
                all_vars.contains(*expected),
                "{}: expected variable '{}' not present (got {:?})",
                fx.name,
                expected,
                all_vars
            );
        }
    }
}

#[test]
fn earthscidata_loader_coverage_matches_amendment_list() {
    // Mayor's amendment on gt-0c7 lists the concrete EarthSciData.jl loaders
    // that must be covered. Keep this list in lockstep with the amendment so
    // that if a future loader is added upstream we are forced to revisit.
    let expected_coverage: &[&str] = &[
        "GEOSFP",
        "ERA5",
        "WRF",
        "NEI2016Monthly",
        "CEDS",
        "EDGAR",
        "USGS3DEP",
        "LANDFIRE",
    ];

    for needle in expected_coverage {
        let found = FIXTURES.iter().any(|fx| fx.name.contains(needle));
        assert!(
            found,
            "gt-0c7 coverage gap: no fixture mentions '{needle}' \
             — update tests/fixtures/data_sources/ and this test"
        );
    }
}
