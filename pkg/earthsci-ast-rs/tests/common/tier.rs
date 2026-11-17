//! A cross-binding conformance tier run through the inline-test runner and
//! gated against its Julia-minted goldens.
//!
//! [`Tier::open`] reads `tests/conformance/<category>/manifest.json`, checks
//! its header and takes its assertion tolerances and pinned solver options.
//! [`Tier::check_fixture`] runs one fixture's inline tests and compares every
//! result against the fixture's golden, as [`GoldenCheck`] says; the tiers
//! differ in how a golden entry names its result, how close is close, and
//! what they check of the fixture's own declared assertions.

use std::collections::BTreeMap;
use std::path::PathBuf;

use earthsci_ast::{
    AssertionResult, Compiler, InlineTestOptions, SolveOptions, load_string,
    run_inline_tests_with_options,
};
use serde_json::Value;

/// How an actual must sit against a wanted value.
#[derive(Clone, Copy, Default)]
pub enum Closeness {
    /// Within `atol`, or within `rtol` of the larger magnitude
    /// ([`super::close`]).
    #[default]
    EitherBound,
    /// Within `atol + rtol * |want|`.
    SumBound,
}

impl Closeness {
    fn holds(self, actual: f64, want: f64, rtol: f64, atol: f64) -> bool {
        match self {
            Closeness::EitherBound => super::close(actual, want, rtol, atol),
            Closeness::SumBound => (actual - want).abs() <= atol + rtol * want.abs(),
        }
    }
}

/// What a tier checks of the fixture's own declared `assertions`, beyond the
/// golden.
#[derive(Clone, Copy, Default)]
pub enum Declared {
    /// Nothing.
    #[default]
    Unchecked,
    /// The result's variable is the declared one, and its actual is close to
    /// the declared `expected`.
    ActualNearExpected,
    /// The result's variable, `reduce` and `expected` are the declared ones,
    /// the last exactly.
    SameAssertion,
}

/// How [`Tier::check_fixture`] gates a fixture's results against its golden.
/// Every golden entry's result must have passed and carry an actual close to
/// the golden's.
#[derive(Clone, Copy, Default)]
pub struct GoldenCheck {
    /// Golden entries name their result by `(test_id, assertion_idx)`, for a
    /// fixture whose tests share assertion indices; otherwise by
    /// `assertion_idx` alone.
    pub by_test_id: bool,
    /// The result's variable must be the golden entry's.
    pub golden_variable: bool,
    pub closeness: Closeness,
    pub declared: Declared,
    /// The compiler the inline tests run under, when the tier pins one.
    pub compiler: Option<Compiler>,
}

/// A conformance tier: its directory, manifest, assertion tolerances and the
/// solver options it pins for this binding.
pub struct Tier {
    pub dir: PathBuf,
    pub manifest: Value,
    pub rtol: f64,
    pub atol: f64,
    pub solve: SolveOptions,
}

impl Tier {
    /// The tier `category`, its manifest's header checked.
    pub fn open(category: &str) -> Tier {
        let dir = super::category_dir(category);
        let manifest = super::read_json(dir.join("manifest.json"));
        super::assert_tier_header(&manifest, category);
        let (rtol, atol) = super::assertion_tolerances(&manifest);
        let solve = super::erk_solve_options(&manifest);
        Tier {
            dir,
            manifest,
            rtol,
            atol,
            solve,
        }
    }

    /// The manifest's fixtures.
    pub fn fixtures(&self) -> &[Value] {
        self.manifest["fixtures"].as_array().expect("fixtures")
    }

    /// The fixture whose `id` is `id`.
    pub fn fixture(&self, id: &str) -> &Value {
        self.fixtures()
            .iter()
            .find(|f| f["id"].as_str() == Some(id))
            .unwrap_or_else(|| panic!("no fixture {id}"))
    }

    /// The inline tests of fixture `fx` run under the tier's solver options,
    /// with its golden, which the reference binding minted.
    pub fn run_fixture(
        &self,
        fx: &Value,
        compiler: Option<Compiler>,
    ) -> (Vec<AssertionResult>, Value) {
        let esm_path = self.dir.join(fx["path"].as_str().expect("path"));
        let golden = super::read_json(self.dir.join(fx["golden"].as_str().expect("golden")));
        assert_eq!(golden["reference_binding"].as_str(), Some("julia"));
        let text =
            std::fs::read_to_string(&esm_path).unwrap_or_else(|e| panic!("read {esm_path:?}: {e}"));
        let file = load_string(&text)
            .unwrap_or_else(|e| panic!("fixture {esm_path:?} does not load: {e}"));
        let results = run_inline_tests_with_options(
            &file,
            &InlineTestOptions {
                model_name: fx["model"].as_str().map(str::to_string),
                solve: self.solve.clone(),
                base_dir: Some(self.dir.clone()),
                compiler,
                ..Default::default()
            },
        );
        (results, golden)
    }

    /// Run fixture `fx` and gate its results against its golden as `check`
    /// says. Returns each golden entry's actual by `assertion_idx`.
    pub fn check_fixture(&self, fx: &Value, check: &GoldenCheck) -> BTreeMap<usize, f64> {
        let (results, golden) = self.run_fixture(fx, check.compiler);
        let (rtol, atol) = (self.rtol, self.atol);
        let goldens = golden["assertions"].as_array().expect("golden assertions");
        assert_eq!(
            results.len(),
            goldens.len(),
            "{}: the fixture ran {} assertions and the golden records {}",
            fx["id"],
            results.len(),
            goldens.len()
        );
        let find = |test_id: Option<&str>, idx: usize| {
            results
                .iter()
                .find(|r| r.assertion_idx == idx && test_id.is_none_or(|t| r.test_id == t))
                .unwrap_or_else(|| panic!("missing assertion {}#{idx}", test_id.unwrap_or("")))
        };
        let mut actuals = BTreeMap::new();
        for g in goldens {
            let test_id = check
                .by_test_id
                .then(|| g["test_id"].as_str().expect("test_id"));
            let idx = g["assertion_idx"].as_u64().expect("assertion_idx") as usize;
            let what = format!("{}#{idx}", test_id.unwrap_or(""));
            let r = find(test_id, idx);
            if check.golden_variable {
                assert_eq!(r.variable, g["variable"].as_str().expect("variable"));
            }
            assert!(r.passed, "{what} ({}): {}", r.variable, r.message);
            let actual = r
                .actual
                .unwrap_or_else(|| panic!("{what}: no actual ({})", r.message));
            let want = g["actual"].as_f64().expect("golden actual");
            assert!(
                check.closeness.holds(actual, want, rtol, atol),
                "{what}: actual {actual} vs golden {want}"
            );
            actuals.insert(idx, actual);
        }
        if !matches!(check.declared, Declared::Unchecked) {
            for decl in fx["assertions"].as_array().expect("declared assertions") {
                let idx = decl["assertion_idx"].as_u64().expect("assertion_idx") as usize;
                let r = find(None, idx);
                assert_eq!(r.variable, decl["variable"].as_str().expect("variable"));
                let want = decl["expected"].as_f64().expect("expected");
                match check.declared {
                    Declared::ActualNearExpected => {
                        let actual = r.actual.expect("actual");
                        assert!(
                            check.closeness.holds(actual, want, rtol, atol),
                            "#{idx}: actual {actual} vs declared expected {want}"
                        );
                    }
                    Declared::SameAssertion => {
                        assert_eq!(r.reduce.as_deref(), decl["reduce"].as_str());
                        assert_eq!(r.expected, want);
                    }
                    Declared::Unchecked => unreachable!(),
                }
            }
        }
        actuals
    }

    /// [`Self::check_fixture`] on every fixture of the manifest.
    pub fn check_all(&self, check: &GoldenCheck) {
        for fx in self.fixtures() {
            self.check_fixture(fx, check);
        }
    }
}
