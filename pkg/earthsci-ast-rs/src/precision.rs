//! Working precision of the evaluator — `domain.element_type` (esm-spec §11.3).
//!
//! # What `element_type: "Float32"` means
//!
//! It means the evaluator computes in **binary32, rounding once per
//! operation** — not "store f32, compute f64". The distinction is not
//! cosmetic: it decides answers. `100 * ((100 - 73.5) / 100) / (100 - 73.5)`
//! is exactly `1.0` in binary64 and `0.99999994` in binary32, and downstream
//! a comparison against such a residual decides which rows a relational model
//! emits at all. A field stored as f32 but multiplied in f64 reproduces
//! neither.
//!
//! # Representation
//!
//! Values keep their `f64` carrier (`Value::Scalar(f64)`, `ArrayD<f64>`); what
//! changes is the arithmetic. Every operation in [`Precision::Float32`] mode
//! converts its operands to `f32`, applies the `f32` operation, and widens the
//! `f32` result back — so every live value is exactly representable in
//! binary32 and every rounding step is the binary32 one. Widening f32→f64 is
//! exact, so the carrier is invisible; this is genuine binary32 arithmetic, not
//! f64 arithmetic with a cast at the end.
//!
//! Two ingress rules keep that invariant total:
//!
//! * **Literals and bindings round on entry** (numbers in the AST, parameter
//!   values, state/observed/forcing reads, `t`), so a value that reaches an
//!   output without passing through any operator is still binary32.
//! * **Loop index bindings do NOT round.** They are integers, exact in `f64`,
//!   and are consumed as array subscripts. Index *arithmetic* (`i + 1`) still
//!   goes through the f32 kernels and so is exact only while every index stays
//!   below `2^24`; [`check_index_set_extent`] rejects a Float32 document whose
//!   declared index sets exceed that rather than let a subscript silently
//!   round.
//!
//! # Where the mode lives
//!
//! A thread-local, set by an RAII [`PrecisionGuard`] at each entry point that
//! has a document (and re-armed from the compiled artifact at each run entry,
//! so a compiled model carries its own precision). The kernels read it where
//! they resolve an operator, which is once per AST node on the vectorized and
//! taped paths and once per cell on the oracle — the same place the operator
//! name is already being matched.
//!
//! # Per-variable overrides
//!
//! A variable may declare its own [`ModelVariable::element_type`], overriding
//! the document's, and precision then propagates from the leaves of an
//! expression rather than being one global mode
//! ([`crate::precision_infer`]). Two thread-locals therefore exist, not one:
//!
//! * [`document()`] — what the document declared. The build-time GATES read
//!   this (the index-set extent check, the unsupported-operator set): they ask
//!   what the document is, not what the node under the cursor is.
//! * [`active()`] — the precision of the expression node being evaluated. The
//!   KERNELS read this. It starts at the document's and is re-armed by
//!   [`enter`] wherever the inference pass marked a precision boundary.
//!
//! With no `element_type` anywhere on a variable the two are always equal and
//! nothing is marked, so the machinery is inert.
//!
//! [`ModelVariable::element_type`]: crate::types::ModelVariable::element_type
//!
//! [`Precision::Float64`] is the default and takes the identical code path it
//! took before this module existed: `active()` returns `Float64`, every
//! `is_f32()` branch is not taken, and the f64 kernel tables are the same
//! tables. Float64 results are bit-unchanged by construction, not by testing.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::sync::Arc;

use crate::compile_error::CompileError;
use crate::types::Expr;

/// The evaluator's working floating-point precision.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Hash)]
pub enum Precision {
    /// IEEE binary64 — the default, and the precision every document that does
    /// not say otherwise evaluates in.
    #[default]
    Float64,
    /// IEEE binary32, rounded per operation.
    Float32,
}

impl Precision {
    /// Parse a `domain.element_type` string.
    ///
    /// `None` (the field absent) is [`Precision::Float64`], the schema default.
    ///
    /// # Errors
    ///
    /// [`CompileError::UnsupportedElementType`] for any other spelling. The
    /// schema `enum` already restricts the field to the two names, but a
    /// document reaching the evaluator has not necessarily been schema-checked,
    /// and quietly treating an unknown element type as f64 is the exact silent
    /// fallback this module exists to remove.
    pub fn from_element_type(s: Option<&str>) -> Result<Self, CompileError> {
        match s {
            None | Some("Float64") => Ok(Precision::Float64),
            Some("Float32") => Ok(Precision::Float32),
            Some(other) => Err(CompileError::UnsupportedElementType {
                element_type: other.to_string(),
            }),
        }
    }

    /// Is this the binary32 mode?
    #[inline(always)]
    #[must_use]
    pub fn is_f32(self) -> bool {
        matches!(self, Precision::Float32)
    }

    /// Round a value to this precision. Identity in [`Precision::Float64`].
    #[inline(always)]
    #[must_use]
    pub fn round(self, v: f64) -> f64 {
        match self {
            Precision::Float64 => v,
            Precision::Float32 => v as f32 as f64,
        }
    }

    /// The `domain.element_type` spelling.
    #[must_use]
    pub fn element_type(self) -> &'static str {
        match self {
            Precision::Float64 => "Float64",
            Precision::Float32 => "Float32",
        }
    }
}

thread_local! {
    /// The precision the current thread evaluates in. Written only through
    /// [`PrecisionGuard`], which restores the previous value on drop, so a
    /// nested build/solve cannot leak a mode to its caller.
    static ACTIVE: Cell<Precision> = const { Cell::new(Precision::Float64) };
    /// The precision the current DOCUMENT declared, which [`ACTIVE`] starts at
    /// and which the build-time gates ask about. Written only through
    /// [`EnvGuard`].
    static DOCUMENT: Cell<Precision> = const { Cell::new(Precision::Float64) };
    /// Per-variable element-type overrides for the current document, keyed by
    /// every spelling a consumer may use (bare and namespaced). Empty — and
    /// therefore inert — for every document that declares none. Written only
    /// through [`EnvGuard`].
    static VARS: RefCell<Arc<VarPrecisions>> = RefCell::new(Arc::new(VarPrecisions::default()));
}

/// The per-variable element types a document declared.
///
/// Keyed by variable name under EVERY spelling a later stage may use: the bare
/// authored name and, once flattening has namespaced it, `Model.name`. Lookup
/// additionally falls back to the last dotted segment, so a consumer holding a
/// namespaced name still resolves a bare registration.
#[derive(Debug, Default, Clone)]
pub struct VarPrecisions {
    by_name: HashMap<String, Precision>,
    /// The names that DECLARED an `element_type`, for diagnostics: `Model.name`
    /// from [`Self::from_declarations`], the bare name from [`Self::insert`]. The
    /// table itself also records every other variable at the document's
    /// precision (see [`Self::from_declarations`]), and those are not
    /// overrides.
    declared: std::collections::BTreeSet<String>,
}

/// One model's variables as [`VarPrecisions::from_declarations`] reads them:
/// the model name, each top-level variable's name and declared
/// `element_type` spelling, and each variable of each of its subsystems (at
/// any depth) under its dotted path below the model.
#[derive(Debug, Default)]
pub struct ModelDeclarations<'a> {
    /// The model's key in the document.
    pub model: &'a str,
    /// `(variable, declared element_type)` for the model's own variables.
    pub variables: Vec<(&'a str, Option<&'a str>)>,
    /// `(Sub.path.variable, declared element_type)` for its subsystems'.
    pub subsystem_variables: Vec<(String, Option<String>)>,
}

impl VarPrecisions {
    /// The per-variable table for a document (esm-spec §11.3.1).
    ///
    /// EMPTY — the inert fast path — when no variable declares an
    /// `element_type`, a subsystem's included. Otherwise every model variable
    /// is recorded under its `Model.name` spelling at its EFFECTIVE precision
    /// (its declaration, else `document`), so a qualified lookup never falls
    /// through to a bare name another model registered. Bare names are recorded
    /// for `selected` (the model being built) when there is one, for the only
    /// model when there is one, and otherwise only where every model that has
    /// the name agrees on its precision: two models may both declare an `x`,
    /// and a mount makes that the ordinary case (a Float32 leaf beside a
    /// Float64 assembly).
    ///
    /// A SUBSYSTEM variable is recorded the same way under the two spellings
    /// the build uses for it: the full `Model.Sub.path.var` (a provider key, a
    /// flattened name) and the model-local `Sub.path.var` (a mounted rule's
    /// name, which is what per-rule arming looks up). Without the latter a
    /// lookup of `Sub.var` would fall back to its last segment and find a
    /// top-level `var` of another precision, or the document's. The model-local
    /// spelling follows the same selection rule as a bare name.
    ///
    /// # Errors
    ///
    /// [`CompileError::UnsupportedElementType`] for a spelling that is neither
    /// `"Float64"` nor `"Float32"`.
    pub fn from_declarations(
        models: &[ModelDeclarations<'_>],
        document: Precision,
        selected: Option<&str>,
    ) -> Result<Self, CompileError> {
        let mut out = VarPrecisions::default();
        let mut any = false;
        // `(model, model-local spelling, effective precision)`, top-level
        // variables and subsystem variables alike.
        let mut effective: Vec<(&str, &str, Precision)> = Vec::new();
        for m in models {
            let subs = m
                .subsystem_variables
                .iter()
                .map(|(path, et)| (path.as_str(), et.as_deref()));
            for (v, et) in m.variables.iter().copied().chain(subs) {
                // Absent means the document's — NOT `from_element_type(None)`,
                // which is the schema default Float64.
                let p = match et {
                    Some(_) => Precision::from_element_type(et)?,
                    None => document,
                };
                if et.is_some() {
                    any = true;
                    out.declared.insert(format!("{}.{v}", m.model));
                }
                effective.push((m.model, v, p));
            }
        }
        if !any {
            return Ok(VarPrecisions::default());
        }
        let bare_from = selected.or(if models.len() == 1 {
            Some(models[0].model)
        } else {
            None
        });
        let mut bare: HashMap<&str, Option<Precision>> = HashMap::new();
        for (m, v, p) in &effective {
            out.by_name.insert(format!("{m}.{v}"), *p);
            match bare_from {
                Some(sel) if sel == *m => {
                    bare.insert(v, Some(*p));
                }
                Some(_) => {}
                None => {
                    let e = bare.entry(v).or_insert(Some(*p));
                    if *e != Some(*p) {
                        *e = None;
                    }
                }
            }
        }
        for (v, p) in bare {
            // A name the models disagree on is recorded under no bare
            // spelling, as before. A model-local `Sub.var` never displaces a
            // full spelling recorded above (a model named `Sub` with a `var`).
            if let Some(p) = p {
                out.by_name.entry(v.to_string()).or_insert(p);
            }
        }
        Ok(out)
    }

    /// Record `name`'s declared precision (also under `Model.name` when
    /// `model` is given).
    pub fn insert(&mut self, model: Option<&str>, name: &str, p: Precision) {
        self.declared.insert(name.to_string());
        self.by_name.insert(name.to_string(), p);
        if let Some(m) = model {
            self.by_name.insert(format!("{m}.{name}"), p);
        }
    }

    /// The declared precision of `name`, or `None` if it declared none.
    #[must_use]
    pub fn get(&self, name: &str) -> Option<Precision> {
        if let Some(p) = self.by_name.get(name) {
            return Some(*p);
        }
        // A consumer may hold a namespaced spelling of a bare registration
        // (flattening prefixes) or the reverse.
        let tail = name.rsplit('.').next()?;
        if tail == name {
            return None;
        }
        self.by_name.get(tail).copied()
    }

    /// Every name that declared an element type (spelled as `declared` records
    /// it), in sort order.
    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.declared.iter().map(String::as_str)
    }

    /// Does this document declare any per-variable element type at all?
    ///
    /// False is the fast path every existing document takes: no inference pass
    /// runs, no boundary marker is inserted, and every ingress site rounds
    /// exactly as it did before.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.by_name.is_empty()
    }
}

/// Every variable of every subsystem under `subsystems` (a raw
/// `Model.subsystems` map), at any depth, as `(Sub.path.variable, declared
/// element_type)` — the input [`VarPrecisions::from_declarations`] reads.
#[must_use]
pub fn subsystem_declarations(
    subsystems: Option<&serde_json::Value>,
) -> Vec<(String, Option<String>)> {
    subsystems
        .and_then(serde_json::Value::as_object)
        .map(|subs| subsystem_declarations_in(subs))
        .unwrap_or_default()
}

/// [`subsystem_declarations`] over a typed `Model.subsystems` map, or any
/// other `(name, component)` sequence.
#[must_use]
pub fn subsystem_declarations_in<'a>(
    subsystems: impl IntoIterator<Item = (&'a String, &'a serde_json::Value)>,
) -> Vec<(String, Option<String>)> {
    fn walk<'a>(
        subs: impl IntoIterator<Item = (&'a String, &'a serde_json::Value)>,
        prefix: &str,
        out: &mut Vec<(String, Option<String>)>,
    ) {
        for (name, sub) in subs {
            let path = if prefix.is_empty() {
                name.clone()
            } else {
                format!("{prefix}.{name}")
            };
            let sub = subsystem_component(sub);
            if let Some(vars) = sub.get("variables").and_then(serde_json::Value::as_object) {
                for (v, d) in vars {
                    out.push((
                        format!("{path}.{v}"),
                        d.get("element_type")
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_string),
                    ));
                }
            }
            if let Some(nested) = sub.get("subsystems").and_then(serde_json::Value::as_object) {
                walk(nested, &path, out);
            }
        }
    }
    let mut out = Vec::new();
    walk(subsystems, "", &mut out);
    out
}

/// The component a `subsystems.<k>` entry splices in: the entry itself in the
/// inline model form, or the one model of a whole-file form (`{"models":
/// {...}}`, which `crate::simulate_array::parse_subsystem_model` also mounts).
#[must_use]
pub fn subsystem_component(sub: &serde_json::Value) -> &serde_json::Value {
    match sub
        .get("models")
        .and_then(serde_json::Value::as_object)
        .filter(|m| m.len() == 1)
    {
        Some(models) => models.values().next().expect("len checked"),
        None => sub,
    }
}

/// [`subsystem_component`], mutably.
pub fn subsystem_component_mut(sub: &mut serde_json::Value) -> &mut serde_json::Value {
    let file_form = sub
        .get("models")
        .and_then(serde_json::Value::as_object)
        .is_some_and(|m| m.len() == 1);
    if file_form {
        sub["models"]
            .as_object_mut()
            .and_then(|m| m.values_mut().next())
            .expect("checked above")
    } else {
        sub
    }
}

/// The precision the current thread is evaluating in.
#[inline(always)]
#[must_use]
pub fn active() -> Precision {
    ACTIVE.with(Cell::get)
}

/// Shorthand for `active().is_f32()`.
#[inline(always)]
#[must_use]
pub fn is_f32() -> bool {
    active().is_f32()
}

/// Round `v` to the active precision (identity under Float64).
#[inline(always)]
#[must_use]
pub fn round(v: f64) -> f64 {
    active().round(v)
}

/// The precision the current DOCUMENT declared.
///
/// This is what the build-time gates ask (index-set extents, the operators with
/// no binary32 form): they are properties of the document, not of the node
/// under the cursor. Use [`active()`] for anything that computes a value.
#[inline(always)]
#[must_use]
pub fn document() -> Precision {
    DOCUMENT.with(Cell::get)
}

/// The element type declared for `name`, or the document's if it declared none.
///
/// The ingress sites — a host-supplied parameter, a provider-fetched column, a
/// caller `const_array` — round to THIS rather than to [`active()`]: they fill
/// a named variable, and an exempt variable's data must arrive unrounded or the
/// first read of it is already wrong. Expression evaluation does not need it:
/// the inference pass has already marked the boundaries and [`active()`] is
/// correct at every node.
#[inline]
#[must_use]
pub fn of_variable(name: &str) -> Precision {
    VARS.with(|v| v.borrow().get(name)).unwrap_or_else(document)
}

/// Does the current document declare any per-variable element type?
#[inline]
#[must_use]
pub fn has_variable_overrides() -> bool {
    VARS.with(|v| !v.borrow().is_empty())
}

/// One variable that declares its own element type, or `None` when the
/// document declares no override at all.
///
/// The name is what a refusal has to carry: `has_variable_overrides` answers
/// "is there one" and a diagnostic that cannot say WHICH variable made the
/// document unlowerable sends the author looking through the whole file.
/// Lowest name in sort order, so the diagnostic is deterministic rather than
/// hash-order.
#[must_use]
pub fn first_variable_override() -> Option<String> {
    VARS.with(|v| v.borrow().names().min().map(str::to_string))
}

/// The current document's per-variable element types.
#[must_use]
pub fn variable_precisions() -> Arc<VarPrecisions> {
    VARS.with(|v| Arc::clone(&v.borrow()))
}

/// A document's whole precision environment: what it declared, and the
/// per-variable overrides that refine it.
///
/// Carried on the compiled artifacts ([`crate::problem::EsmProblem`] and the two
/// backends) and re-armed at every run entry, for the same reason the document
/// precision alone already was: a solve happens long after the build's guard has
/// been dropped, so an artifact that remembered only "Float32" would evaluate
/// its binary64 key columns in binary32 at run time — and get exactly the
/// corruption the declaration exists to prevent. Cheap to clone: the table is
/// behind an [`Arc`] and is shared, never copied.
#[derive(Clone, Debug, Default)]
pub struct Env {
    /// The document's `domain.element_type`.
    pub document: Precision,
    /// The per-variable `element_type` overrides it declared.
    pub variables: Arc<VarPrecisions>,
}

impl Env {
    /// Snapshot the environment currently armed on this thread.
    #[must_use]
    pub fn capture() -> Env {
        Env {
            document: document(),
            variables: variable_precisions(),
        }
    }

    /// Arm this environment until the returned guard is dropped.
    pub fn enter(&self) -> EnvGuard {
        enter_env(self.document, Arc::clone(&self.variables))
    }

    /// Is the DOCUMENT's declared precision binary32?
    #[inline(always)]
    #[must_use]
    pub fn is_f32(&self) -> bool {
        self.document.is_f32()
    }
}

/// Restores the enclosing document precision and per-variable table when
/// dropped. Held for the lifetime of one build/solve.
#[must_use = "the precision environment is restored as soon as the guard is dropped"]
pub struct EnvGuard {
    prev_doc: Precision,
    prev_active: Precision,
    prev_vars: Arc<VarPrecisions>,
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        DOCUMENT.with(|c| c.set(self.prev_doc));
        ACTIVE.with(|c| c.set(self.prev_active));
        VARS.with(|v| *v.borrow_mut() = Arc::clone(&self.prev_vars));
    }
}

/// Arm the whole precision environment for one document: its declared
/// precision (which [`active()`] also starts at) and its per-variable
/// overrides.
pub fn enter_env(doc: Precision, vars: Arc<VarPrecisions>) -> EnvGuard {
    let prev_doc = DOCUMENT.with(|c| c.replace(doc));
    let prev_active = ACTIVE.with(|c| c.replace(doc));
    let prev_vars = VARS.with(|v| std::mem::replace(&mut *v.borrow_mut(), vars));
    EnvGuard {
        prev_doc,
        prev_active,
        prev_vars,
    }
}

/// Restores the enclosing [`Precision`] when dropped.
#[must_use = "the precision is restored as soon as the guard is dropped"]
pub struct PrecisionGuard {
    prev: Precision,
}

impl Drop for PrecisionGuard {
    fn drop(&mut self) {
        ACTIVE.with(|c| c.set(self.prev));
    }
}

/// Evaluate in `p` until the returned guard is dropped.
pub fn enter(p: Precision) -> PrecisionGuard {
    let prev = ACTIVE.with(|c| c.replace(p));
    PrecisionGuard { prev }
}

/// Largest integer every binary32 value below it represents exactly.
///
/// Index arithmetic shares the value kernels (there is no integer type in the
/// expression language), so a subscript above this would round.
pub const F32_EXACT_INT_LIMIT: i64 = 1 << 24;

/// Reject an index-set extent a Float32 subscript could not address exactly.
///
/// # Errors
///
/// [`CompileError::Float32Unsupported`] naming the index set.
pub fn check_index_set_extent(name: &str, size: i64) -> Result<(), CompileError> {
    if size > F32_EXACT_INT_LIMIT {
        return Err(CompileError::Float32Unsupported {
            construct: format!("index set `{name}` of size {size}"),
            reason: format!(
                "index expressions share the value kernels, so a subscript above \
                 2^24 ({F32_EXACT_INT_LIMIT}) would round under \
                 `domain.element_type: \"Float32\"`"
            ),
        });
    }
    Ok(())
}

/// Operators whose numeric work happens **outside** the shared scalar kernel
/// layer, in hand-written binary64 code, and which therefore cannot honour a
/// Float32 declaration.
///
/// Returning the reason (rather than a bare bool) keeps the diagnostic
/// specific: a Float32 document that uses one of these gets an error naming the
/// construct, never a subexpression that quietly evaluated in binary64.
#[must_use]
pub fn f32_unsupported_reason(op: &str, fn_name: Option<&str>) -> Option<(String, String)> {
    let geometry = |op: &str| {
        (
            format!("operator `{op}`"),
            "polygon clipping and area are computed by the binary64 geometry \
             kernels (`crate::geometry`), which have no binary32 form"
                .to_string(),
        )
    };
    match op {
        "intersect_polygon" | "polygon_intersection_area" => Some(geometry(op)),
        "fn" => match fn_name {
            // Interpolation walks a binary64 table and blends in binary64.
            Some(n @ ("interp.linear" | "interp.bilinear")) => Some((
                format!("closed function `{n}`"),
                "table interpolation is evaluated by the binary64 closed-function \
                 registry, which has no binary32 form"
                    .to_string(),
            )),
            // A Julian day is ~2.46e6 with a fractional part; binary32 cannot
            // hold it to better than ~0.25 s, so returning one under Float32
            // would be a silent precision cliff rather than a rounding.
            Some(n @ "datetime.julian_day") => Some((
                format!("closed function `{n}`"),
                "a Julian day number exceeds binary32's exact-integer range, so \
                 its fractional part would be destroyed by the declared precision"
                    .to_string(),
            )),
            // The remaining closed functions (`datetime.year`,
            // `datetime.day_of_year`, `datetime.is_leap_year`,
            // `interp.searchsorted`) return small exact integers, which binary32
            // represents exactly.
            _ => None,
        },
        _ => None,
    }
}

/// Reject every construct in `expr` that cannot be evaluated in binary32.
///
/// A no-op unless the active precision is [`Precision::Float32`]; call it from
/// the compile paths alongside the other operator gates.
///
/// # Errors
///
/// [`CompileError::Float32Unsupported`] naming the first offending construct.
pub fn check_f32_supported(expr: &Expr) -> Result<(), CompileError> {
    if !is_f32() {
        return Ok(());
    }
    check_f32_supported_tree(expr)
}

fn check_f32_supported_tree(expr: &Expr) -> Result<(), CompileError> {
    let Expr::Operator(node) = expr else {
        return Ok(());
    };
    let fn_name = node.name.as_deref();
    if let Some((construct, reason)) = f32_unsupported_reason(&node.op, fn_name) {
        return Err(CompileError::Float32Unsupported { construct, reason });
    }
    let mut first_err: Option<CompileError> = None;
    node.for_each_child(&mut |child| {
        if first_err.is_none()
            && let Err(e) = check_f32_supported_tree(child)
        {
            first_err = Some(e);
        }
    });
    match first_err {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_float64_and_round_is_identity() {
        assert_eq!(active(), Precision::Float64);
        // A value with no binary32 representation survives untouched.
        let v = 0.1_f64;
        assert_eq!(round(v).to_bits(), v.to_bits());
    }

    #[test]
    fn guard_sets_and_restores() {
        assert!(!is_f32());
        {
            let _g = enter(Precision::Float32);
            assert!(is_f32());
            assert_eq!(round(0.1_f64), 0.1_f32 as f64);
            {
                let _inner = enter(Precision::Float64);
                assert!(!is_f32());
            }
            assert!(
                is_f32(),
                "the inner guard restores Float32, not the default"
            );
        }
        assert!(!is_f32());
    }

    #[test]
    fn element_type_parsing() {
        assert_eq!(
            Precision::from_element_type(None).unwrap(),
            Precision::Float64
        );
        assert_eq!(
            Precision::from_element_type(Some("Float64")).unwrap(),
            Precision::Float64
        );
        assert_eq!(
            Precision::from_element_type(Some("Float32")).unwrap(),
            Precision::Float32
        );
        // Not a silent fallback to f64.
        assert!(Precision::from_element_type(Some("Float16")).is_err());
        assert!(Precision::from_element_type(Some("float32")).is_err());
    }

    #[test]
    fn f32_unsupported_set() {
        assert!(f32_unsupported_reason("intersect_polygon", None).is_some());
        assert!(f32_unsupported_reason("polygon_intersection_area", None).is_some());
        assert!(f32_unsupported_reason("fn", Some("interp.linear")).is_some());
        assert!(f32_unsupported_reason("fn", Some("interp.bilinear")).is_some());
        assert!(f32_unsupported_reason("fn", Some("datetime.julian_day")).is_some());
        assert!(f32_unsupported_reason("fn", Some("interp.searchsorted")).is_none());
        assert!(f32_unsupported_reason("fn", Some("datetime.year")).is_none());
        assert!(f32_unsupported_reason("+", None).is_none());
    }

    #[test]
    fn index_set_extent_gate() {
        assert!(check_index_set_extent("rows", F32_EXACT_INT_LIMIT).is_ok());
        let err = check_index_set_extent("rows", F32_EXACT_INT_LIMIT + 1).unwrap_err();
        assert!(format!("{err}").contains("rows"), "{err}");
    }
}
