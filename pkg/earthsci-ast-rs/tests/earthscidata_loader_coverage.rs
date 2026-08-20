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
//!  3. Basic invariants on the new schema fields (at least one data_source,
//!     each loader has a non-empty url_template and variables map).

use earthsci_ast::{DataSourceKind, EsmFile, load, save};

/// Every `file_variable` the document's model parameters bind, across all
/// `update` rules.
///
/// Since 1.0.0 a data source declares no variables of its own: the CONSUMING
/// parameter names the file variable it binds and owns the units
/// (esm-spec §8.5). So the coverage this test asserts moved from
/// `data_sources[*].variables` onto `models[*].variables[*].update.from`.
fn bound_file_variables(f: &EsmFile) -> std::collections::BTreeMap<String, String> {
    let mut out = std::collections::BTreeMap::new();
    for model in f.models.iter().flatten().map(|(_, m)| m) {
        for (vname, var) in &model.variables {
            let Some(update) = &var.update else { continue };
            for rule in update.rules() {
                if let Some(binding) = rule.from() {
                    out.insert(binding.file_variable.clone(), vname.clone());
                }
            }
        }
    }
    out
}


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
fn every_earthscidata_source_validates_against_schema() {
    for fx in FIXTURES {
        let _ = load_fixture(fx);
    }
}

#[test]
fn every_earthscidata_source_round_trips_without_loss() {
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
                dl1.source.url_template, dl2.source.url_template,
                "{}/{}: url_template changed",
                fx.name, name
            );
        }

        // The bindings live on the consuming parameters now, so that is what
        // must survive the round-trip.
        assert_eq!(
            bound_file_variables(&parsed),
            bound_file_variables(&reparsed),
            "{}: parameter/file_variable bindings changed across round-trip",
            fx.name
        );
    }
}

#[test]
fn every_earthscidata_source_has_expected_variables() {
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

        // Every file variable the document's parameters bind.
        let bound = bound_file_variables(&parsed);
        let all_vars: std::collections::HashSet<String> = bound.keys().cloned().collect();
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
        }

        // A binding names a non-empty file variable, and the consuming
        // parameter — which now owns the units — declares them.
        for (file_variable, param) in &bound {
            assert!(
                !file_variable.is_empty(),
                "{}: a binding has an empty file_variable",
                fx.name
            );
            let units = parsed
                .models
                .iter()
                .flatten()
                .find_map(|(_, m)| m.variables.get(param))
                .and_then(|v| v.units.as_deref())
                .unwrap_or("");
            assert!(
                !units.is_empty(),
                "{}/{}: consuming parameter declares no units",
                fx.name,
                param
            );
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
fn earthscidata_source_coverage_matches_amendment_list() {
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
