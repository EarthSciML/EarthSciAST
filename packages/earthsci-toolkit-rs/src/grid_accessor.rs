//! Cross-family `GridAccessor` trait — the ESS-side contract that
//! EarthSciDiscretizations (ESD) concrete grid families implement.
//!
//! Per the 2026-04-22 grid-inversion decision, ESS owns the public
//! accessor signatures; per-family realization (cartesian, lat_lon,
//! mpas, duo, …) lives in ESD. ESD impls register
//! themselves against an ESM-wire-form family name via [`register_factory`];
//! consumers obtain an accessor from a parsed [`crate::types::Grid`] via
//! [`build_accessor`].
//!
//! The signatures mirror `EarthSciDiscretizations/docs/GRIDS_API.md` §3
//! (grid return-type contract) and §7 (normative fields).

use crate::types::Grid;
use std::collections::HashMap;
use std::sync::{OnceLock, RwLock};

use thiserror::Error;

/// Cell identifier.
///
/// Structured families (cartesian, lat_lon) carry logical `(i, j)`
/// indices. Unstructured families (mpas, duo) carry a flat cell id.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CellId {
    /// Logical `(i, j)` index for structured / block-structured families.
    Logical { i: usize, j: usize },
    /// Flat cell index for unstructured families.
    Flat(usize),
}

/// Errors returned by [`GridAccessor`] operations and the factory registry.
#[derive(Debug, Error)]
pub enum GridAccessorError {
    /// An `(i, j)` index or flat id was out of range for this grid.
    #[error("grid index out of bounds: {0}")]
    IndexOutOfBounds(String),

    /// `metric_eval` was called with a name not declared on this grid.
    #[error("metric '{0}' not defined for this grid")]
    UnknownMetric(String),

    /// No factory has been registered for the grid's `family` string.
    #[error("no GridAccessor factory registered for family '{0}'")]
    NoFactory(String),

    /// A factory is already registered under the given family name.
    #[error("GridAccessor factory already registered for family '{0}'")]
    AlreadyRegistered(String),

    /// The parsed [`Grid`] is structurally valid but cannot be realized
    /// (missing required field for this family, etc.).
    #[error("cannot build accessor: {0}")]
    InvalidGrid(String),

    /// Operation is not supported by this family (e.g., logical
    /// `cell_centers(i, j)` on a fully unstructured mesh).
    #[error("operation unsupported by family '{family}': {detail}")]
    Unsupported {
        /// Family name from [`GridAccessor::family`].
        family: String,
        /// Human-readable detail.
        detail: String,
    },
}

/// Cross-family read-only interface over a realized grid.
///
/// The trait is the ESS-owned half of the GRIDS_API contract; concrete
/// family impls live in ESD. Every method is pure — implementations must
/// not perform I/O, mutate global state, or depend on RNG.
///
/// The trait is `Send + Sync` so accessors can be shared across threads
/// (e.g., by a `rayon` parallel metric evaluator).
pub trait GridAccessor: Send + Sync {
    /// Grid family name matching the ESM wire form
    /// (`"cartesian"`, `"lat_lon"`, `"mpas"`, `"duo"`, …).
    fn family(&self) -> &str;

    /// Returns the cell-center coordinates at logical index `(i, j)`.
    ///
    /// The returned vector length equals the grid's spatial dimension
    /// (2 for surface / lat-lon, 3 for 3-D volumetric families). Units
    /// are SI per `GRIDS_API.md` §2.2; lon/lat families return radians.
    ///
    /// Returns [`GridAccessorError::IndexOutOfBounds`] if `(i, j)` is
    /// outside the grid's cell range (interior + ghosts) and
    /// [`GridAccessorError::Unsupported`] for families where `(i, j)`
    /// is not a well-defined indexing scheme.
    fn cell_centers(&self, i: usize, j: usize) -> Result<Vec<f64>, GridAccessorError>;

    /// Returns the neighboring cell ids of `cell`.
    ///
    /// Order is family-defined but deterministic within a given grid
    /// (required by `GRIDS_API.md` §6.1). Unstructured families return
    /// neighbors as [`CellId::Flat`]; structured families may return
    /// [`CellId::Logical`].
    fn neighbors(&self, cell: CellId) -> Result<Vec<CellId>, GridAccessorError>;

    /// Evaluates a named grid metric (e.g., `"dx"`, `"area"`, `"dcEdge"`)
    /// at logical index `(i, j)`.
    ///
    /// The set of legal `name` values is determined by the grid's
    /// `metric_arrays` map (§6.5 of the ESS spec). Implementations
    /// return [`GridAccessorError::UnknownMetric`] for any other name.
    fn metric_eval(&self, name: &str, i: usize, j: usize) -> Result<f64, GridAccessorError>;
}

/// Factory signature registered by ESD concrete families.
///
/// The factory takes the ESM-wire-form [`Grid`] that ESS parses and
/// returns a boxed [`GridAccessor`] specialized to that family.
pub type GridAccessorFactory = fn(&Grid) -> Result<Box<dyn GridAccessor>, GridAccessorError>;

fn registry() -> &'static RwLock<HashMap<String, GridAccessorFactory>> {
    static REG: OnceLock<RwLock<HashMap<String, GridAccessorFactory>>> = OnceLock::new();
    REG.get_or_init(|| RwLock::new(HashMap::new()))
}

/// Register a [`GridAccessorFactory`] for the given family name.
///
/// Returns [`GridAccessorError::AlreadyRegistered`] if a factory is
/// already registered under `family`. ESD typically calls this once
/// per family from an initializer (e.g., a `ctor`-style function or
/// an explicit `earthsci_grids::register_all()` at startup).
pub fn register_factory(
    family: &str,
    factory: GridAccessorFactory,
) -> Result<(), GridAccessorError> {
    let mut reg = registry().write().expect("GridAccessor registry poisoned");
    if reg.contains_key(family) {
        return Err(GridAccessorError::AlreadyRegistered(family.to_string()));
    }
    reg.insert(family.to_string(), factory);
    Ok(())
}

/// Returns `true` iff a factory has been registered for `family`.
pub fn has_factory(family: &str) -> bool {
    registry()
        .read()
        .expect("GridAccessor registry poisoned")
        .contains_key(family)
}

/// Build a [`GridAccessor`] for the given parsed [`Grid`] by dispatching
/// on its `family` field.
///
/// Returns [`GridAccessorError::NoFactory`] if no ESD family has
/// registered against `grid.family`. ESS ships with zero built-in
/// families; all realization lives downstream.
pub fn build_accessor(grid: &Grid) -> Result<Box<dyn GridAccessor>, GridAccessorError> {
    let factory = {
        let reg = registry().read().expect("GridAccessor registry poisoned");
        reg.get(&grid.family).copied()
    };
    match factory {
        Some(f) => f(grid),
        None => Err(GridAccessorError::NoFactory(grid.family.clone())),
    }
}

/// Test-only: drop all registered factories.
///
/// Not part of the stable API; intended for downstream crate test
/// harnesses that need isolation between tests of the registry itself.
#[doc(hidden)]
pub fn __reset_registry_for_tests() {
    registry()
        .write()
        .expect("GridAccessor registry poisoned")
        .clear();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Grid;
    use std::sync::Mutex;

    // Serialize registry tests; the registry is process-global.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    struct DummyCartesian;

    impl GridAccessor for DummyCartesian {
        fn family(&self) -> &str {
            "cartesian"
        }

        fn cell_centers(&self, i: usize, j: usize) -> Result<Vec<f64>, GridAccessorError> {
            if i >= 4 || j >= 4 {
                return Err(GridAccessorError::IndexOutOfBounds(format!(
                    "({i}, {j}) outside 4x4"
                )));
            }
            Ok(vec![i as f64 + 0.5, j as f64 + 0.5])
        }

        fn neighbors(&self, cell: CellId) -> Result<Vec<CellId>, GridAccessorError> {
            match cell {
                CellId::Logical { i, j } => {
                    let mut out = Vec::new();
                    if i > 0 {
                        out.push(CellId::Logical { i: i - 1, j });
                    }
                    if i < 3 {
                        out.push(CellId::Logical { i: i + 1, j });
                    }
                    if j > 0 {
                        out.push(CellId::Logical { i, j: j - 1 });
                    }
                    if j < 3 {
                        out.push(CellId::Logical { i, j: j + 1 });
                    }
                    Ok(out)
                }
                CellId::Flat(_) => Err(GridAccessorError::Unsupported {
                    family: "cartesian".to_string(),
                    detail: "flat cell ids".to_string(),
                }),
            }
        }

        fn metric_eval(&self, name: &str, _i: usize, _j: usize) -> Result<f64, GridAccessorError> {
            match name {
                "dx" | "dy" => Ok(1.0),
                other => Err(GridAccessorError::UnknownMetric(other.to_string())),
            }
        }
    }

    fn dummy_factory(_grid: &Grid) -> Result<Box<dyn GridAccessor>, GridAccessorError> {
        Ok(Box::new(DummyCartesian))
    }

    fn minimal_grid(family: &str) -> Grid {
        Grid {
            family: family.to_string(),
            description: None,
            dimensions: vec!["x".into(), "y".into()],
            locations: None,
            metric_arrays: None,
            parameters: None,
            domain: None,
            extents: None,
            connectivity: None,
        }
    }

    #[test]
    fn trait_surface_round_trips() {
        let a = DummyCartesian;
        assert_eq!(a.family(), "cartesian");
        assert_eq!(a.cell_centers(1, 2).unwrap(), vec![1.5, 2.5]);
        assert!(matches!(
            a.cell_centers(9, 0),
            Err(GridAccessorError::IndexOutOfBounds(_))
        ));
        let n = a.neighbors(CellId::Logical { i: 0, j: 0 }).unwrap();
        assert_eq!(n.len(), 2);
        assert_eq!(a.metric_eval("dx", 0, 0).unwrap(), 1.0);
        assert!(matches!(
            a.metric_eval("nope", 0, 0),
            Err(GridAccessorError::UnknownMetric(_))
        ));
    }

    #[test]
    fn register_and_build() {
        let _g = TEST_LOCK.lock().unwrap();
        __reset_registry_for_tests();

        assert!(!has_factory("cartesian"));
        register_factory("cartesian", dummy_factory).unwrap();
        assert!(has_factory("cartesian"));

        let grid = minimal_grid("cartesian");
        let accessor = match build_accessor(&grid) {
            Ok(a) => a,
            Err(e) => panic!("expected accessor, got {e:?}"),
        };
        assert_eq!(accessor.family(), "cartesian");
        assert_eq!(accessor.cell_centers(0, 0).unwrap(), vec![0.5, 0.5]);
    }

    #[test]
    fn duplicate_registration_errors() {
        let _g = TEST_LOCK.lock().unwrap();
        __reset_registry_for_tests();

        register_factory("lat_lon", dummy_factory).unwrap();
        let err = register_factory("lat_lon", dummy_factory).unwrap_err();
        assert!(matches!(err, GridAccessorError::AlreadyRegistered(_)));
    }

    #[test]
    fn build_without_factory_errors() {
        let _g = TEST_LOCK.lock().unwrap();
        __reset_registry_for_tests();

        let grid = minimal_grid("mpas");
        match build_accessor(&grid) {
            Ok(_) => panic!("expected NoFactory error"),
            Err(GridAccessorError::NoFactory(f)) => assert_eq!(f, "mpas"),
            Err(other) => panic!("expected NoFactory, got {other:?}"),
        }
    }

    #[test]
    fn accessor_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync + ?Sized>() {}
        assert_send_sync::<dyn GridAccessor>();
    }
}
