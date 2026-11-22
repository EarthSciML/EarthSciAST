//! The version-gated constructs, declared once (esm-spec §4.7 "Each file is
//! held to its own declared `esm` version").
//!
//! Every construct that arrives at some `esm` version is one [`VersionGate`]
//! in [`VERSIONED`]: the version it arrives at, the diagnostic a file declaring
//! less gets, which kinds of document are checked for it, and how to find it.
//! The same table drives both halves of the rule:
//!
//! * the LOAD check refuses a file that spells a construct its own declared
//!   version predates ([`check_file_gates`] and the public `reject_*`
//!   wrappers);
//! * the EMIT floor raises a resolved document's declared version to cover
//!   every construct it came to contain through a mount ([`raise_emit_floors`]),
//!   so `emit` never writes bytes the load check refuses.

use crate::diagnostic::{DiagnosticError, codes, err};
use crate::parse::AuthoredFacts;
use serde_json::Value;

/// A kind of document a load reads, for the gate coverage column.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum DocKind {
    /// The document the caller asked to load.
    Root,
    /// A file mounted by a §4.7 `{ref}` edge, at either mount form.
    MountedLeaf,
    /// A template-library file imported by `expression_template_imports`.
    TemplateLibrary,
    /// A coupling-library file imported by a `coupling_import` entry.
    CouplingLibrary,
}

/// Where in the root load a gate runs. The root interleaves its gates with
/// other passes, and which diagnostic fires first is visible across bindings,
/// so the root runs each group at its own place; every other kind of document
/// runs all its gates together, in table order.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Group {
    /// Inside the wire-boundary op walk (`parse::prepare_document_ops`), which
    /// every document a load reads passes through.
    Wire,
    /// The §9.6 / §9.7 template-machinery constructs.
    Templates,
    /// The top-level `solver` block and its fields.
    Solver,
    /// Constructs inside components (expression nodes, variables).
    Content,
}

/// One version-gated construct.
pub(crate) struct VersionGate {
    /// What the construct is, for documentation and tests.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) construct: &'static str,
    /// The `(major, minor)` version the construct arrives at.
    pub(crate) min: (u64, u64),
    /// The diagnostic code of a file declaring less.
    pub(crate) code: &'static str,
    /// The kinds of document the load check applies to.
    pub(crate) kinds: &'static [DocKind],
    pub(crate) group: Group,
    /// Whether `emit` raises a document's version to `min` when it contains
    /// the construct. A construct that never crosses a mount edge (a mounted
    /// leaf's `solver` block is dropped) or is consumed at the edge (a leaf's
    /// template machinery is expanded there) cannot reach a document that
    /// declares less, so it needs no floor.
    pub(crate) floor: bool,
    /// The offending location(s) in a whole document, or `None` when it does
    /// not spell the construct.
    find: fn(&Value) -> Option<String>,
    /// The same, read from the facts the load's wire walk already noted,
    /// where it noted them (the authored tree, before a mount spliced
    /// anything in).
    from_facts: Option<fn(&AuthoredFacts) -> Option<String>>,
    /// The refusal message, given the declared version and the offence.
    message: fn(esm: &str, offending: &str) -> String,
}

const ROOT_LEAF: &[DocKind] = &[DocKind::Root, DocKind::MountedLeaf];
const ROOT_LEAF_LIBRARY: &[DocKind] = &[
    DocKind::Root,
    DocKind::MountedLeaf,
    DocKind::TemplateLibrary,
];
const EVERY_DOCUMENT: &[DocKind] = &[
    DocKind::Root,
    DocKind::MountedLeaf,
    DocKind::TemplateLibrary,
    DocKind::CouplingLibrary,
];

/// Index of the `faq` gate in [`VERSIONED`].
pub(crate) const FAQ: usize = 0;
/// Index of the `expression_templates` / `apply_expression_template` gate.
pub(crate) const EXPRESSION_TEMPLATES: usize = 1;
/// Index of the §9.7 template-import gate.
pub(crate) const TEMPLATE_IMPORTS: usize = 2;
/// Index of the top-level `solver` block gate.
pub(crate) const SOLVER: usize = 3;
/// Index of the `solver.external` gate.
pub(crate) const SOLVER_EXTERNAL: usize = 4;
/// Index of the `solver.time_span` gate.
pub(crate) const SOLVER_TIME_SPAN: usize = 5;
/// Index of the unit-bearing expression node gate.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) const CONST_UNITS: usize = 6;
/// Index of the variable bounds gate.
pub(crate) const VARIABLE_BOUNDS: usize = 7;

/// Every version-gated construct, in the order a document's gates run.
///
/// | construct | arrives | root | leaf | template library | coupling library | emit floor |
/// |---|---|---|---|---|---|---|
/// | `faq` op | 1.1.0 | yes | yes | yes | yes | yes |
/// | `expression_templates` / `apply_expression_template` | 0.4.0 | yes | yes | yes | no | no |
/// | `expression_template_imports` / `metaparameters` | 0.8.0 | yes | yes | yes | no | no |
/// | `solver` block | 1.1.0 | yes | yes | no | no | no |
/// | `solver.external` | 1.3.0 | yes | no | no | no | no |
/// | `solver.time_span` | 1.3.0 | yes | no | no | no | no |
/// | `units` on an expression node | 1.2.0 | yes | yes | yes | no | yes |
/// | variable `lb` / `ub` | 2.1.0 | yes | yes | no | no | yes |
///
/// `solver.external` and `solver.time_span` describe one run of the root, so
/// a mounted document's are not refused for their version (esm-spec §2.2.6,
/// §2.2.7 "Mounting"). A library holds no `solver` block and no variables.
pub(crate) static VERSIONED: [VersionGate; 8] = [
    VersionGate {
        construct: "`faq` op",
        min: (1, 1),
        code: codes::FAQ_VERSION_TOO_OLD,
        kinds: EVERY_DOCUMENT,
        group: Group::Wire,
        floor: true,
        find: first_faq_path,
        from_facts: None,
        message: |esm, path| {
            format!(
                "faq_version_too_old at {path}: the `faq` op arrives at esm 1.1.0; file \
                 declares {esm}. Raise the declared version. \
                 See docs/content/rfcs/faq-node-rename.md."
            )
        },
    },
    VersionGate {
        construct: "`operators` / `apply_operator`",
        min: (0, 4),
        code: codes::OPERATOR_VERSION_TOO_OLD,
        kinds: ROOT_LEAF_LIBRARY,
        group: Group::Templates,
        floor: false,
        find: crate::lower_expression_templates::expression_template_offences,
        from_facts: None,
        message: |esm, paths| {
            format!(
                "operators / apply_operator require esm >= 0.4.0; \
                 file declares {esm}. Offending paths: {paths}"
            )
        },
    },
    VersionGate {
        construct: "`operator_imports` / top-level `operators` / \
                    `metaparameters`",
        min: (0, 8),
        code: codes::OPERATOR_IMPORT_VERSION_TOO_OLD,
        kinds: ROOT_LEAF_LIBRARY,
        group: Group::Templates,
        floor: false,
        find: crate::template_imports::template_import_offences,
        from_facts: None,
        message: |esm, paths| {
            format!(
                "operator_imports / top-level operators / metaparameters \
                 require esm >= 0.8.0; file declares {esm}. Offending paths: {paths}"
            )
        },
    },
    VersionGate {
        construct: "top-level `solver` block",
        min: (1, 1),
        code: codes::SOLVER_VERSION_TOO_OLD,
        kinds: ROOT_LEAF,
        group: Group::Solver,
        floor: false,
        find: |v| v.get("solver").map(|_| "/solver".to_string()),
        from_facts: None,
        message: |esm, path| {
            format!(
                "the top-level `solver` block requires esm >= 1.1.0; file declares {esm}. \
                 Offending path: {path}"
            )
        },
    },
    VersionGate {
        construct: "`solver.external`",
        min: (1, 3),
        code: codes::SOLVER_EXTERNAL_VERSION_TOO_OLD,
        kinds: &[DocKind::Root],
        group: Group::Solver,
        floor: false,
        find: |v| solver_field(v, "external"),
        from_facts: None,
        message: |esm, path| {
            format!(
                "`solver.external` requires esm >= 1.3.0; file declares {esm}. Offending path: {path}"
            )
        },
    },
    VersionGate {
        construct: "`solver.time_span`",
        min: (1, 3),
        code: codes::SOLVER_TIME_SPAN_VERSION_TOO_OLD,
        kinds: &[DocKind::Root],
        group: Group::Solver,
        floor: false,
        find: |v| solver_field(v, "time_span"),
        from_facts: None,
        message: |esm, path| {
            format!(
                "`solver.time_span` requires esm >= 1.3.0; file declares {esm}. Offending path: {path}"
            )
        },
    },
    VersionGate {
        construct: "declared `units` on an expression node",
        min: (1, 2),
        code: codes::CONST_UNITS_VERSION_TOO_OLD,
        kinds: ROOT_LEAF_LIBRARY,
        group: Group::Content,
        floor: true,
        find: first_op_with_units,
        from_facts: Some(|f| f.op_with_units.clone()),
        message: |esm, path| {
            format!(
                "declared `units` on an expression node require esm >= 1.2.0; file declares \
                 {esm}. Offending path: {path}"
            )
        },
    },
    VersionGate {
        construct: "variable `lb` / `ub`",
        min: (2, 1),
        code: codes::VARIABLE_BOUNDS_VERSION_TOO_OLD,
        kinds: ROOT_LEAF,
        group: Group::Content,
        floor: true,
        find: crate::variable_bounds::first_bound_pointer,
        from_facts: Some(|f| f.variable_bound.clone()),
        message: |esm, path| {
            format!(
                "variable bounds (`lb` / `ub`) require esm >= 2.1.0; file declares {esm}. \
                 Offending path: {path}"
            )
        },
    },
];

/// A document's declared `esm` string and its `(major, minor)`, or `None`
/// when it declares none or one that does not parse (the schema and the
/// version-compatibility check report those).
fn declared_version(view: &Value) -> Option<(&str, (u64, u64))> {
    let esm = view.get("esm").and_then(Value::as_str)?;
    let (major, minor, _) = crate::diagnostic::parse_semver(esm)?;
    Some((esm, (u64::from(major), u64::from(minor))))
}

impl VersionGate {
    /// Does a document declaring `view`'s version predate this construct?
    pub(crate) fn predates(&self, view: &Value) -> bool {
        declared_version(view).is_some_and(|(_, v)| v < self.min)
    }

    /// The refusal message for a document declaring `esm` that spells the
    /// construct at `offending`.
    pub(crate) fn message(&self, esm: &str, offending: &str) -> String {
        (self.message)(esm, offending)
    }

    /// The load check: refuse `view` when its declared version predates the
    /// construct and `offending` (called only then) finds it.
    pub(crate) fn check(
        &self,
        view: &Value,
        offending: impl FnOnce() -> Option<String>,
    ) -> Result<(), DiagnosticError> {
        let Some((esm, version)) = declared_version(view) else {
            return Ok(());
        };
        if version >= self.min {
            return Ok(());
        }
        match offending() {
            None => Ok(()),
            Some(at) => Err(err(self.code, self.message(esm, &at))),
        }
    }

    /// The load check, finding the construct by walking `view`.
    pub(crate) fn check_document(&self, view: &Value) -> Result<(), DiagnosticError> {
        self.check(view, || (self.find)(view))
    }
}

/// Run every gate of `group` (every group when `None`) that applies to a
/// document of `kind`, in table order. `facts` are what the load's wire walk
/// noted on `view`'s authored tree; a gate that reads them never walks the
/// document again. The [`Group::Wire`] gate runs inside that walk and is not
/// rerun here.
pub(crate) fn check_file_gates(
    view: &Value,
    kind: DocKind,
    group: Option<Group>,
    facts: &AuthoredFacts,
) -> Result<(), DiagnosticError> {
    for gate in &VERSIONED {
        if gate.group == Group::Wire
            || !gate.kinds.contains(&kind)
            || group.is_some_and(|g| g != gate.group)
        {
            continue;
        }
        match gate.from_facts {
            Some(read) => gate.check(view, || read(facts))?,
            None => gate.check_document(view)?,
        }
    }
    Ok(())
}

/// Raise an emitted document's declared `esm` to cover every floored
/// construct it contains.
///
/// A FLOOR — "a consumer needs at least this" — so it only ever raises. It
/// exists because a document can come to contain a construct without ever
/// spelling it: a 1.0.0 document that mounts a 1.2.0 leaf carrying a
/// unit-bearing `const` has the leaf inlined into it at load, and emitting that
/// as 1.0.0 writes a document the `const_units_version_too_old` gate then
/// refuses to read back. The load check cannot catch it — the mounting file's
/// AUTHORED bytes are legal — so the floor closes it here.
pub(crate) fn raise_emit_floors(value: &mut Value) {
    let Some((_, declared)) = declared_version(value) else {
        return;
    };
    let floor = VERSIONED
        .iter()
        .filter(|g| g.floor && g.min > declared && (g.find)(value).is_some())
        .map(|g| g.min)
        .max();
    if let Some((major, minor)) = floor
        && let Some(obj) = value.as_object_mut()
    {
        obj.insert(
            "esm".to_string(),
            Value::String(format!("{major}.{minor}.0")),
        );
    }
}

/// The pre-order path of the first `"op": "faq"` node.
fn first_faq_path(view: &Value) -> Option<String> {
    let mut found = None;
    crate::json_visit::visit_values(view, &mut |path, v| {
        if found.is_none()
            && v.as_object()
                .and_then(|o| o.get("op"))
                .and_then(Value::as_str)
                == Some("faq")
        {
            found = Some(path.to_string());
        }
    });
    found
}

/// The pre-order path of the first object carrying both an `op` and a `units`
/// key — the walk `parse::prepare_document_ops` notes as
/// [`AuthoredFacts::op_with_units`].
fn first_op_with_units(view: &Value) -> Option<String> {
    let mut found = None;
    crate::json_visit::visit_values(view, &mut |path, v| {
        if found.is_none()
            && let Some(o) = v.as_object()
            && o.contains_key("op")
            && o.contains_key("units")
        {
            found = Some(path.to_string());
        }
    });
    found
}

/// The pointer of `solver.<field>` when the top-level block carries it.
fn solver_field(view: &Value, field: &str) -> Option<String> {
    view.get("solver")
        .and_then(Value::as_object)
        .filter(|s| s.contains_key(field))
        .map(|_| format!("/solver/{field}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The table's indices name the entries they claim to.
    #[test]
    fn indices_name_their_entries() {
        assert_eq!(VERSIONED[FAQ].code, codes::FAQ_VERSION_TOO_OLD);
        assert_eq!(
            VERSIONED[EXPRESSION_TEMPLATES].code,
            codes::OPERATOR_VERSION_TOO_OLD
        );
        assert_eq!(
            VERSIONED[TEMPLATE_IMPORTS].code,
            codes::OPERATOR_IMPORT_VERSION_TOO_OLD
        );
        assert_eq!(VERSIONED[SOLVER].code, codes::SOLVER_VERSION_TOO_OLD);
        assert_eq!(
            VERSIONED[SOLVER_EXTERNAL].code,
            codes::SOLVER_EXTERNAL_VERSION_TOO_OLD
        );
        assert_eq!(
            VERSIONED[SOLVER_TIME_SPAN].code,
            codes::SOLVER_TIME_SPAN_VERSION_TOO_OLD
        );
        assert_eq!(
            VERSIONED[CONST_UNITS].code,
            codes::CONST_UNITS_VERSION_TOO_OLD
        );
        assert_eq!(
            VERSIONED[VARIABLE_BOUNDS].code,
            codes::VARIABLE_BOUNDS_VERSION_TOO_OLD
        );
    }

    /// Every construct that can reach a document through a mount — it is
    /// checked on a mounted leaf or a library and is not consumed at the edge
    /// — has an emit floor.
    #[test]
    fn mount_crossing_constructs_are_floored() {
        for gate in &VERSIONED {
            let crosses = matches!(gate.code, c if c == codes::FAQ_VERSION_TOO_OLD
                || c == codes::CONST_UNITS_VERSION_TOO_OLD
                || c == codes::VARIABLE_BOUNDS_VERSION_TOO_OLD);
            assert_eq!(gate.floor, crosses, "{}", gate.construct);
        }
    }

    /// A template library is held to its own `esm` for declared `units` on
    /// an expression node in a template body (esm-spec §4.8.5 item 6, §4.7),
    /// as a root and a mounted leaf are.
    #[test]
    fn template_library_gets_the_const_units_gate() {
        let dir = tempfile::TempDir::new().unwrap();
        let library = |esm: &str| {
            json!({
                "esm": esm,
                "metadata": { "name": "lib" },
                "operators": { "one_pa": {
                    "params": [],
                    "body": { "op": "const", "args": [], "value": 1.0, "units": "Pa" }
                } }
            })
        };
        let root = |lib: &str| {
            json!({
                "esm": "1.2.0",
                "metadata": { "name": "root" },
                "models": { "M": {
                    "operator_imports": [{ "ref": lib }],
                    "variables": {},
                    "equations": []
                } }
            })
        };
        std::fs::write(dir.path().join("old.esm"), library("1.1.0").to_string()).unwrap();
        std::fs::write(dir.path().join("new.esm"), library("1.2.0").to_string()).unwrap();
        for (lib, refused) in [("old.esm", true), ("new.esm", false)] {
            let path = dir.path().join(format!("root_{lib}"));
            std::fs::write(&path, root(lib).to_string()).unwrap();
            let gated = crate::load_path(&path)
                .err()
                .is_some_and(|e| e.to_string().contains(codes::CONST_UNITS_VERSION_TOO_OLD));
            assert_eq!(gated, refused, "{lib}");
        }

        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/invalid/version_gate_library_older_const_units.esm");
        let e = crate::load_path(&fixture).expect_err("the shared fixture is refused");
        assert!(
            e.to_string().contains(codes::CONST_UNITS_VERSION_TOO_OLD),
            "{e}"
        );
    }

    #[test]
    fn emit_floor_covers_const_units() {
        let mut doc = json!({
            "esm": "1.0.0",
            "models": { "M": { "variables": {}, "equations": [
                { "lhs": "x", "rhs": { "op": "const", "args": [], "value": 1.0, "units": "Pa" } }
            ] } }
        });
        raise_emit_floors(&mut doc);
        assert_eq!(doc["esm"], "1.2.0");
    }

    #[test]
    fn emit_floor_takes_the_highest_construct_and_never_lowers() {
        let mut doc = json!({
            "esm": "1.0.0",
            "models": { "M": {
                "variables": { "x": { "type": "unknown", "lb": 0.0 } },
                "equations": [{ "lhs": "x", "rhs": { "op": "faq", "args": [] } }]
            } }
        });
        raise_emit_floors(&mut doc);
        assert_eq!(doc["esm"], "2.1.0");

        let mut newer = json!({
            "esm": "2.3.0",
            "models": { "M": { "equations": [{ "rhs": { "op": "faq", "args": [] } }] } }
        });
        raise_emit_floors(&mut newer);
        assert_eq!(newer["esm"], "2.3.0");
    }
}
