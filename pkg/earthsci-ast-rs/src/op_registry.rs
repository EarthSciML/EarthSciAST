//! The operator registry: the single source of truth for **which `op` strings
//! exist** and **how many `args` each one takes** (esm-spec §4.2 / §4.3).
//!
//! The schema deliberately leaves `args` at `minItems: 0`, because a *schema*
//! cannot express "`atan2` takes exactly two arguments but `+` takes any
//! number". Without an arity check a malformed-but-schema-valid node would
//! reach the evaluators, where one evaluator could fold `-(3,1,1)` to `NaN`
//! while another left-folds it to `1.0`, and `atan2` with one argument would
//! index `args[1]` and panic.
//!
//! The registry closes that class of bug at the source: an op/arity pair that
//! this table rejects never reaches an evaluator, so the evaluators are only
//! ever asked to agree on nodes that are *legal*, and for those they agree by
//! construction.
//!
//! # The two tiers (esm-spec §4.2)
//!
//! - **Evaluable core (closed).** Everything in [`CoreOp`], whose
//!   [`CoreOp::info`] holds one row per operator. Adding one is a spec change. A core op with the wrong arity is a hard error
//!   ([`OpError::Arity`]).
//! - **Rewrite-target (open).** Everything else — `integral`, a *spatial*
//!   `D`, and any user-defined op. These have **no evaluator**; they MUST be eliminated by a
//!   rewrite rule (§9.6) before evaluation. Reaching an evaluator with one still
//!   present is [`OpError::Unlowered`] → diagnostic `unlowered_operator`.
//!
//! A **misspelled** op (`"expp"`) is, formally, an open-tier op for which no
//! rewrite rule exists — so it lands in the same `unlowered_operator` bucket
//! rather than being silently evaluated to `NaN`. That is the spec's own answer
//! (§9.6.3 constraint 6: "any node whose `op` is not in the evaluable-core set
//! … is rejected with diagnostic `unlowered_operator`"), and it is why a typo is
//! now loud instead of quietly poisoning a trajectory with `NaN`.

use crate::types::{Expr, ExpressionNode};

/// How many `args` an evaluable-core operator accepts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Arity {
    /// Exactly `n` arguments (`atan2` → 2, `ifelse` → 3, `const` → 0).
    Exact(usize),
    /// Between `lo` and `hi` inclusive (`-` → 1 or 2: negation or subtraction).
    Between(usize, usize),
    /// At least `n` (`+`/`*` are n-ary; `min`/`max` are n-ary with `n >= 2`).
    AtLeast(usize),
    /// Any arity, including zero. Used by the ops whose operands do not live in
    /// `args` at all (`faq`/`makearray` carry them in `expr`/`values`).
    Any,
}

impl Arity {
    /// Does `n` satisfy this arity?
    #[must_use]
    pub fn admits(self, n: usize) -> bool {
        match self {
            Self::Exact(k) => n == k,
            Self::Between(lo, hi) => n >= lo && n <= hi,
            Self::AtLeast(k) => n >= k,
            Self::Any => true,
        }
    }

    /// Human-readable expectation, for diagnostics.
    #[must_use]
    pub fn describe(self) -> String {
        match self {
            Self::Exact(k) => format!("exactly {k}"),
            Self::Between(lo, hi) => format!("{lo} or {hi}"),
            Self::AtLeast(k) => format!("at least {k}"),
            Self::Any => "any number of".to_string(),
        }
    }
}

/// What is wrong with an operator node.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpError {
    /// A known evaluable-core op applied to the wrong number of arguments.
    Arity {
        /// The operator name.
        op: String,
        /// How many arguments it was given.
        got: usize,
        /// What the spec says it takes.
        expected: String,
    },
    /// A rewrite-target op (spatial `D`, `integral`, user op, or a typo) reached
    /// evaluation without being lowered. Diagnostic code `unlowered_operator`.
    Unlowered {
        /// The operator name.
        op: String,
    },
    /// A `makearray` whose `regions` are ragged (regions disagreeing on rank)
    /// or carry an inverted bound pair. Diagnostic code
    /// `makearray_region_inverted` (esm-spec §4.3.2).
    MakearrayRegion {
        /// What is wrong with the regions.
        reason: String,
    },
    /// A `broadcast` node whose `fn` is absent, or names something that is not
    /// a SCALAR operator (esm-spec §4.3.4: "the `fn` value must name a scalar
    /// operator"). Diagnostic code `invalid_broadcast_fn`.
    ///
    /// An `fn`-arity mismatch is reported as [`OpError::Arity`] against the
    /// `fn` NAME instead, because that is literally the same defect the bare
    /// node would have: `broadcast(fn = "min", [x])` is wrong for exactly the
    /// reason `{"op": "min", "args": [x]}` is wrong.
    BroadcastFn {
        /// The offending `fn` value, or `None` when the field is absent.
        fn_name: Option<String>,
        /// Why it is rejected.
        reason: String,
    },
}

impl std::fmt::Display for OpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Arity { op, got, expected } => {
                write!(f, "operator '{op}' takes {expected} argument(s), got {got}")
            }
            Self::Unlowered { op } => write!(
                f,
                "operator '{op}' has no evaluator and was not lowered by any rewrite rule"
            ),
            Self::MakearrayRegion { reason } | Self::BroadcastFn { reason, .. } => {
                write!(f, "{reason}")
            }
        }
    }
}

/// Validate a `makearray` node's `regions` block (esm-spec §4.3.2).
///
/// Two things can be wrong with it, and both used to **panic** the per-cell
/// evaluator rather than being reported:
///
/// 1. **Ragged regions.** `eval_makearray` took its rank from `regions[0]` and
///    then indexed `lo[d]`/`hi[d]` for every `d` of *every* region, so a second
///    region of higher rank ran off the end of the bounding box.
/// 2. **An inverted bound pair.** The bounding-box extent `hi - lo + 1` was cast
///    `as usize`, so a reversed region such as `[5, 2]` produced an extent of
///    `-2`, wrapped to `usize::MAX - 1`, and blew up in `ArrayD::zeros` with a
///    capacity overflow.
///
/// The spec draws the line precisely: `stop == start - 1` is the canonical
/// **empty** region — it is what a metaparameter-folded interior region
/// (`[2, N-1]` at `N = 2`) legitimately produces, contributes no cells, and MUST
/// load cleanly. Anything *further* inverted (`stop < start - 1`) is an
/// authoring error and is rejected with `makearray_region_inverted`.
///
/// # Errors
///
/// [`OpError::MakearrayRegion`] naming the offending region.
pub fn check_makearray_regions(node: &ExpressionNode) -> Result<(), OpError> {
    let Some(regions) = node.regions.as_deref() else {
        return Ok(());
    };
    let bad = |reason: String| Err(OpError::MakearrayRegion { reason });

    if let Some(values) = node.values.as_deref()
        && values.len() != regions.len()
    {
        return bad(format!(
            "makearray has {} region(s) but {} value(s) — they must correspond one-to-one",
            regions.len(),
            values.len()
        ));
    }

    let Some(first) = regions.first() else {
        return Ok(());
    };
    let ndim = first.len();
    for (i, region) in regions.iter().enumerate() {
        if region.len() != ndim {
            return bad(format!(
                "makearray region {i} has rank {} but region 0 has rank {ndim} — every region \
                 must address the same number of dimensions",
                region.len()
            ));
        }
        for (d, pair) in region.iter().enumerate() {
            // A still-symbolic (unfolded) bound has no orderable value yet, so
            // there is nothing to check: §9.7.6 folding runs before evaluation
            // and this same check re-runs on the folded node.
            let Some([start, stop]) = crate::types::region_bounds(pair) else {
                continue;
            };
            // `stop == start - 1` is the legal empty spelling; only a further
            // inversion is an error.
            if stop < start - 1 {
                return bad(format!(
                    "makearray region {i} dimension {d} has inverted bounds [{start}, {stop}]: \
                     stop < start - 1 (the empty spelling [{start}, {}] is legal, anything \
                     further inverted is not)",
                    start - 1
                ));
            }
        }
    }
    Ok(())
}

/// Define a closed set of operator names as an enum with `ALL`, `name()` and
/// `from_name()`, all three generated from one list so they cannot disagree.
macro_rules! named_ops {
    (
        $(#[$meta:meta])*
        pub enum $ty:ident {
            $( $(#[$vmeta:meta])* $variant:ident = $name:literal, )*
        }
    ) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        pub enum $ty {
            $( $(#[$vmeta])* $variant, )*
        }

        impl $ty {
            /// Every member, in declaration order.
            #[cfg(test)]
            pub const ALL: &'static [$ty] = &[$($ty::$variant),*];

            /// The wire spelling.
            #[must_use]
            pub const fn name(self) -> &'static str {
                match self {
                    $( $ty::$variant => $name, )*
                }
            }

            /// The member spelled `name`, or `None`.
            #[must_use]
            pub fn from_name(name: &str) -> Option<Self> {
                match name {
                    $( $name => Some($ty::$variant), )*
                    _ => None,
                }
            }
        }
    };
}

named_ops! {
    /// The unary elementary functions of esm-spec §4.2.
    pub enum UnaryFn {
        Exp = "exp",
        /// The natural logarithm.
        Log = "log",
        Log10 = "log10",
        Sqrt = "sqrt",
        Abs = "abs",
        Sign = "sign",
        Floor = "floor",
        Ceil = "ceil",
        Sin = "sin",
        Cos = "cos",
        Tan = "tan",
        Asin = "asin",
        Acos = "acos",
        Atan = "atan",
        Sinh = "sinh",
        Cosh = "cosh",
        Tanh = "tanh",
        Asinh = "asinh",
        Acosh = "acosh",
        Atanh = "atanh",
    }
}

named_ops! {
    /// The six comparisons of esm-spec §4.2. Each yields a 1.0 / 0.0 flag.
    pub enum Comparison {
        Eq = "==",
        Ne = "!=",
        Lt = "<",
        Le = "<=",
        Gt = ">",
        Ge = ">=",
    }
}

named_ops! {
    /// The evaluable-core operators that are not a unary function or a
    /// comparison; [`CoreOp`] adds those two families.
    pub enum OtherOp {
        Add = "+",
        /// Unary negation or binary subtraction.
        Sub = "-",
        Mul = "*",
        Div = "/",
        Pow = "^",
        /// The deprecated word spelling of `^`.
        PowWord = "pow",
        /// The deprecated word spelling of unary `-`.
        Neg = "neg",
        /// The engine-internal precision-boundary marker
        /// ([`crate::precision_infer::MARKER_OP`]), inserted after the typed
        /// parse and never authored: a transparent unary wrapper naming the
        /// element type its operand is evaluated at.
        Precision = "__precision",
        Atan2 = "atan2",
        Min = "min",
        Max = "max",
        Ifelse = "ifelse",
        And = "and",
        Or = "or",
        Not = "not",
        /// The STRUCTURAL time derivative. A `D` with a spatial `wrt` has the
        /// same name but is a rewrite target ([`is_rewrite_target_derivative`]).
        D = "D",
        Ic = "ic",
        Pre = "Pre",
        Const = "const",
        True = "true",
        False = "false",
        Enum = "enum",
        ApplyExpressionTemplate = "apply_expression_template",
        Faq = "faq",
        Makearray = "makearray",
        Index = "index",
        Broadcast = "broadcast",
        Reshape = "reshape",
        Transpose = "transpose",
        Concat = "concat",
        /// A build-time relational op, evaluated by `crate::value_invention`
        /// rather than by the per-cell evaluator.
        Distinct = "distinct",
    }
}

/// An evaluable-core operator (esm-spec §4.2): the closed set of `op` strings
/// a legal AST may carry after rewriting. Every other name is an open-tier
/// rewrite target (`integral`, a user op, or a typo).
///
/// [`ExpressionNode::core_op`] reads one off a node. The wire format keeps
/// `op` a string; this enum is how the crate decides what that string means,
/// and consumers match it without a wildcard, so a new operator is a compile
/// error at every place that has to decide something about it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CoreOp {
    /// A unary elementary function.
    Unary(UnaryFn),
    /// A comparison.
    Compare(Comparison),
    /// Everything else.
    Other(OtherOp),
}

/// What the registry states about one [`CoreOp`]. [`CoreOp::info`] holds one
/// row per operator.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpInfo {
    /// How many `args` the operator takes.
    pub arity: Arity,
    /// A **scalar operator**: a POINTWISE map from scalar operands to a scalar
    /// result (esm-spec §4.2 "arithmetic, elementary functions, comparisons").
    /// See [`is_scalar_operator`].
    pub scalar: bool,
    /// A **built-in function head**: legal as a bare leaf in VARIABLE position
    /// even though no variable declares it. See [`is_builtin_function_name`].
    pub function_head: bool,
    /// For a DEPRECATED spelling (esm-spec §4.2 "Deprecated ops"), the
    /// operator the loader rewrites it to.
    pub replaced_by: Option<CoreOp>,
}

const fn row(arity: Arity, scalar: bool, function_head: bool) -> OpInfo {
    OpInfo {
        arity,
        scalar,
        function_head,
        replaced_by: None,
    }
}

const fn deprecated(arity: Arity, scalar: bool, replacement: OtherOp) -> OpInfo {
    OpInfo {
        arity,
        scalar,
        function_head: false,
        replaced_by: Some(CoreOp::Other(replacement)),
    }
}

impl CoreOp {
    /// The operator spelled `name`, or `None` for an open-tier name.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        if let Some(f) = UnaryFn::from_name(name) {
            return Some(Self::Unary(f));
        }
        if let Some(c) = Comparison::from_name(name) {
            return Some(Self::Compare(c));
        }
        OtherOp::from_name(name).map(Self::Other)
    }

    /// The wire spelling.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Unary(f) => f.name(),
            Self::Compare(c) => c.name(),
            Self::Other(o) => o.name(),
        }
    }

    /// Every core operator.
    #[cfg(test)]
    pub fn all() -> impl Iterator<Item = CoreOp> {
        UnaryFn::ALL
            .iter()
            .map(|&f| Self::Unary(f))
            .chain(Comparison::ALL.iter().map(|&c| Self::Compare(c)))
            .chain(OtherOp::ALL.iter().map(|&o| Self::Other(o)))
    }

    /// The registry row for this operator. Every arity is the one the spec's
    /// §4.2 tables state.
    ///
    /// Of the identifier-shaped operators, only the named elementary functions
    /// and reductions, `ifelse` and `Pre` are function heads: `neg`, `and`,
    /// `or`, `not` and the form ops (`D`, `ic`, `const`, `true`, …) have never
    /// been excused as variable names, and excusing them would silently pass
    /// a genuinely undeclared variable that happens to carry one of those names.
    ///
    /// The scalar column excludes everything whose meaning is not pointwise,
    /// and each exclusion is load-bearing: the array/tensor ops RESHAPE, so
    /// "apply element-wise" is not defined for them (and a self-referential
    /// `fn: "broadcast"` would recurse forever in the evaluators); the
    /// form/lowering ops are consumed by system assembly or a lowering pass;
    /// `distinct` is build-time. `neg` is scalar because a code-built
    /// `broadcast` may still name it (the loader rewrites an authored
    /// `fn: "neg"` to `-`); `pow` never was a `broadcast` `fn`.
    #[must_use]
    pub const fn info(self) -> OpInfo {
        use Arity::{Any, AtLeast, Between, Exact};
        use OtherOp as O;
        match self {
            Self::Unary(_) => row(Exact(1), true, true),
            Self::Compare(_) => row(Exact(2), true, false),
            Self::Other(o) => match o {
                // `+`/`*` are n-ary; `-` is unary OR binary; `/` and `^` are
                // strictly binary.
                O::Add | O::Mul => row(AtLeast(1), true, false),
                O::Sub => row(Between(1, 2), true, false),
                O::Div | O::Pow => row(Exact(2), true, false),
                // The deprecated spellings stay in the core so an AST built in
                // code still evaluates, by the same kernels as their
                // replacements; the loader rewrites every authored use.
                O::PowWord => deprecated(Exact(2), false, O::Pow),
                O::Neg => deprecated(Exact(1), true, O::Sub),
                O::Precision => row(Exact(1), false, false),
                O::Atan2 => row(Exact(2), true, true),
                // "n-ary with arity >= 2 … Conforming bindings MUST reject
                // `min`/`max` nodes with fewer than two arguments." (§4.2)
                O::Min | O::Max => row(AtLeast(2), true, true),
                O::Ifelse => row(Exact(3), true, true),
                O::And | O::Or => row(AtLeast(2), true, false),
                O::Not => row(Exact(1), true, false),
                // The STRUCTURAL time derivative is strictly unary. A SPATIAL
                // `D` never reaches an arity check (`check_node` reports it as
                // unlowered first), so it may carry trailing auxiliary
                // boundary operands (§4.2 "Arity of `D`").
                O::D | O::Ic => row(Exact(1), false, false),
                O::Pre => row(Exact(1), false, true),
                // "`args` MUST be empty `[]`" (§4.2). `true` is an always-true
                // join/`filter` predicate (§4.3); `false` its counterpart.
                O::Const | O::True | O::False => row(Exact(0), false, false),
                // Lowered at load time (§4.5): `[enum_name, symbol]`.
                O::Enum => row(Exact(2), false, false),
                // Expanded at load time (§9.6); its operands live in `bindings`.
                O::ApplyExpressionTemplate => row(Any, false, false),
                // `faq` and `makearray` carry their real operands in `expr` /
                // `values`, so their `args` arity is open.
                O::Faq | O::Makearray => row(Any, false, false),
                // "`args[0]` is the array; `args[1..]` are the index
                // expressions."
                O::Index | O::Broadcast | O::Concat => row(AtLeast(1), false, false),
                O::Reshape | O::Transpose => row(Exact(1), false, false),
                // Operand shapes are checked by its build-time evaluator.
                O::Distinct => row(Any, false, false),
            },
        }
    }

    /// The deprecated spelling's replacement, or `None`.
    #[must_use]
    pub const fn replaced_by(self) -> Option<CoreOp> {
        self.info().replaced_by
    }
}

impl std::fmt::Display for CoreOp {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

impl ExpressionNode {
    /// The evaluable-core operator this node applies, or `None` when its `op`
    /// is an open-tier name.
    #[must_use]
    pub(crate) fn core_op(&self) -> Option<CoreOp> {
        CoreOp::from_name(&self.op)
    }
}

/// The DEPRECATED op spellings (esm-spec §4.2 "Deprecated ops"), each with its
/// replacement: `neg` is the word spelling of unary `-` and `pow` of `^`. Both
/// remain evaluable-core ops with exactly their replacement's meaning, but the
/// loader's wire boundary rewrites every well-formed use to the replacement
/// and warns `deprecated_op`, and the canonical form (`crate::canonicalize`)
/// writes the replacement.
///
/// The entry for `op` — `(deprecated spelling, replacement)` — or `None` when
/// `op` is not deprecated.
#[must_use]
pub fn deprecated_op(op: &str) -> Option<(&'static str, &'static str)> {
    let core = CoreOp::from_name(op)?;
    core.replaced_by().map(|r| (core.name(), r.name()))
}

/// The arity of an evaluable-core operator, or `None` if `op` is not in the
/// closed core set (esm-spec §4.2) — i.e. it is an open-tier rewrite target.
#[must_use]
pub fn arity_of(op: &str) -> Option<Arity> {
    CoreOp::from_name(op).map(|c| c.info().arity)
}

/// Is `op` an evaluable-core operator (esm-spec §4.2)?
#[must_use]
pub fn is_core_op(op: &str) -> bool {
    CoreOp::from_name(op).is_some()
}

/// Is `name` a **built-in function head** — always legal as a bare leaf in
/// VARIABLE position even though no variable declares it (esm-spec §4.2's
/// named elementary functions and reductions, `ifelse`, and the event op
/// `Pre`)?
///
/// This is the excuse list the crate's two undefined-variable gates share:
/// [`crate::structural`]'s reference checks and the array compiler's
/// free-variable check ([`crate::simulate_array`]) skip these names instead of
/// reporting an undefined variable. The column is [`OpInfo::function_head`].
#[must_use]
pub fn is_builtin_function_name(name: &str) -> bool {
    CoreOp::from_name(name).is_some_and(|c| c.info().function_head)
}

/// Is `op` a **scalar operator** — one whose meaning is a POINTWISE map from
/// scalar operands to a scalar result (esm-spec §4.2 "arithmetic, elementary
/// functions, comparisons")?
///
/// One set answers two questions the format asks in two different places,
/// because they are the same question:
///
/// * **What may a `broadcast` node's `fn` name?** §4.3.4: "the `fn` value must
///   name a scalar operator". That is what makes the `broadcast` contract
///   stateable in one line —
///
///   > `{"op": "broadcast", "fn": F, "args": A}` means what `{"op": F, "args": A}`
///   > means, applied element-wise
///
///   — and [`check_broadcast_fn`] enforces exactly it.
/// * **Does element alignment descend into a node's operands?** An ARRAY-LEVEL
///   `a * b` means "multiply corresponding elements", so the operands must first
///   be brought onto a common index space (§4.3.4). Every other op consumes its
///   operands WHOLE and defines its own operand contract, so alignment must not
///   reach inside them. [`is_elementwise_node`] lifts this predicate to nodes.
///
/// The column is [`OpInfo::scalar`]; [`CoreOp::info`] says why each exclusion
/// is there. Being a column of the core table, the set can only classify core
/// ops, never invent one: `**` and `power` are NOT spellings of `^` and `=` is
/// not a spelling of `==`; none of them is an operator in this format at all.
#[must_use]
pub fn is_scalar_operator(op: &str) -> bool {
    CoreOp::from_name(op).is_some_and(|c| c.info().scalar)
}

/// Does element alignment see THROUGH this node to its `args` — i.e. are the
/// node's operands in elementwise position (esm-spec §4.3.4)?
///
/// This is [`is_scalar_operator`] lifted from op NAMES to NODES, plus the one
/// node whose elementwise-ness lives in a FIELD rather than in its name:
/// `broadcast` applies the scalar operator named in `fn` element by element, so
/// `{"op":"broadcast","fn":"*","args":[w2,z1]}` MEANS `{"op":"*","args":[w2,z1]}`
/// and its operands must align exactly as the bare spelling's do. Treating
/// `broadcast` as opaque made the two spellings disagree — the bare form aligned
/// by index-set name while the `broadcast` form silently kept the positional
/// flatten, which is the very divergence issue #100 exists to close.
///
/// The node-level / name-level split is exactly why [`is_scalar_operator`] must
/// keep EXCLUDING `broadcast`: a `broadcast` NODE is elementwise in its `args`,
/// but the STRING `"broadcast"` is not a kernel name, and any caller handed it
/// as one — as an `fn`, or as a re-dispatch target in the evaluators — recurses
/// forever. Ask the node question of a node and the name question of a name.
///
/// The `fn` guard is deliberately conservative: alignment descends only when
/// `fn` names a scalar operator the evaluators actually have a kernel for. A
/// `broadcast` carrying some other `fn` has no elementwise meaning to preserve —
/// it is now rejected outright (issue #101) — so it keeps the legacy positional
/// lowering rather than being reinterpreted. An ABSENT `fn` likewise keeps the
/// historical `+` classification: since #101 such a node is a hard
/// `invalid_broadcast_fn` error ([`check_broadcast_fn`]) and never reaches an
/// evaluator, so this arm decides only how an UNVALIDATED document is aligned,
/// and it keeps aligning it the way it always did.
#[must_use]
pub fn is_elementwise_node(node: &ExpressionNode) -> bool {
    elementwise_op(node).is_some()
}

/// The scalar operator an elementwise node applies element by element — its
/// `op`, or a `broadcast`'s `fn` — or `None` for a node that is not
/// elementwise ([`is_elementwise_node`]).
#[must_use]
pub fn elementwise_op(node: &ExpressionNode) -> Option<&str> {
    let op = if node.core_op() == Some(CoreOp::Other(OtherOp::Broadcast)) {
        node.broadcast_fn.as_deref().unwrap_or("+")
    } else {
        node.op.as_str()
    };
    is_scalar_operator(op).then_some(op)
}

/// Validate a `broadcast` node's `fn` field (esm-spec §4.3.4).
///
/// `broadcast` is the one op whose OPERATOR is data: the node says `broadcast`
/// but the arithmetic it performs is named by a sibling string field. Nothing
/// checked that string, so three distinct defects were accepted silently and
/// all three produced a plausible wrong number rather than a diagnostic
/// (issue #101):
///
/// 1. **A missing `fn`.** All three evaluators defaulted it to `"+"`. There is
///    no default in the spec, and inventing one turns a truncated node into a
///    silent sum.
/// 2. **An `fn` that names no scalar operator** — a typo (`"not_a_real_op"`) or
///    a non-pointwise op (`"faq"`). §4.3.4 requires a scalar operator, so
///    this is the exact analogue of the §9.1 rule for `fn`-NODE names.
/// 3. **An `fn`/`args` arity mismatch.** `broadcast(fn = "sin", [a, b])` and
///    `broadcast(fn = "min", [x])` are wrong for precisely the reason the bare
///    `sin(a, b)` / `min(x)` nodes are wrong, so they get the SAME
///    [`OpError::Arity`] diagnostic, reported against the `fn` name.
///
/// Note what rule (3) does NOT reject: a one-operand `broadcast` whose `fn` is
/// genuinely n-ary or unary. `broadcast(fn = "+", [x])` and
/// `broadcast(fn = "-", [x])` stay legal, because `+(x)` and `-(x)` are legal
/// bare nodes (identity and negation respectively). That is the whole point of
/// deriving the rule from [`arity_of`] rather than hard-coding "≥ 2".
///
/// # Errors
///
/// [`OpError::BroadcastFn`] for (1) and (2); [`OpError::Arity`] for (3).
pub fn check_broadcast_fn(node: &ExpressionNode) -> Result<(), OpError> {
    let Some(fn_name) = node.broadcast_fn.as_deref() else {
        return Err(OpError::BroadcastFn {
            fn_name: None,
            reason: "'broadcast' is missing its 'fn': the field names the scalar operator to \
                     apply element-wise and has no default (esm-spec §4.3.4)"
                .to_string(),
        });
    };
    // One `else` covers both "not in the registry at all" and "in the registry
    // but not pointwise" — from the file's point of view they are the same
    // defect: `fn` does not name a scalar operator.
    let Some(arity) = CoreOp::from_name(fn_name)
        .map(CoreOp::info)
        .filter(|info| info.scalar)
        .map(|info| info.arity)
    else {
        return Err(OpError::BroadcastFn {
            fn_name: Some(fn_name.to_string()),
            reason: format!(
                "'broadcast' fn '{fn_name}' does not name a scalar operator (esm-spec §4.3.4)"
            ),
        });
    };
    if !arity.admits(node.args.len()) {
        return Err(OpError::Arity {
            op: fn_name.to_string(),
            got: node.args.len(),
            expected: arity.describe(),
        });
    }
    Ok(())
}

/// The `wrt` value that marks the STRUCTURAL time derivative. A `D` node
/// carrying this `wrt` — or carrying no `wrt` at all, which esm-spec §4.2
/// defines to MEAN this — is the structural tier, not a rewrite target.
pub const STRUCTURAL_DERIVATIVE_WRT: &str = "t";

/// The axis a `D` node differentiates along, with esm-spec §4.2's default
/// applied: **an absent `wrt` MEANS `t`**.
///
/// Every consumer of a `D` node reads its axis through this one function. The
/// default is a property of the FORMAT, not of any one pipeline, and spelling
/// it out per call site is what let it be applied on some paths and dropped on
/// others (EarthSciAST#407).
#[must_use]
pub fn derivative_wrt(node: &ExpressionNode) -> &str {
    node.wrt.as_deref().unwrap_or(STRUCTURAL_DERIVATIVE_WRT)
}

/// Is this node a **rewrite-target** `D` — a derivative whose `wrt` names a
/// SPATIAL axis rather than the time variable (esm-spec §4.2 / §9.6.8)?
///
/// `D` is the one op whose tier — and therefore whose operand contract — depends
/// on a FIELD of the node rather than on its name. A spatial `D` has no
/// evaluator (it MUST be lowered to a stencil by a discretization rule), which
/// is exactly why it MAY carry TRAILING AUXILIARY OPERANDS after `args[0]`: the
/// per-face boundary/halo values the rule binds as ordinary §9.6.1 wildcards and
/// consumes. The STRUCTURAL time derivative (`wrt: "t"`, or absent — an absent
/// `wrt` means `t`) is not a rewrite target and stays strictly unary.
///
/// This is the single home of that predicate; both `check_node` and the
/// dimensional checker (`crate::units`) read it rather than re-deriving it.
#[must_use]
pub fn is_rewrite_target_derivative(node: &ExpressionNode) -> bool {
    node.core_op() == Some(CoreOp::Other(OtherOp::D))
        && derivative_wrt(node) != STRUCTURAL_DERIVATIVE_WRT
}

/// Classify one operator node: `Ok(())` if it is an evaluable-core op with a
/// legal arity, otherwise the reason it may not reach an evaluator.
///
/// A `D` node is the one op whose tier depends on a *field* rather than its
/// name: `wrt: "t"` is the structural time derivative (core), while a spatial
/// `wrt` is a rewrite target (§4.2). `check_node` is where that distinction
/// lives, so every caller inherits it.
///
/// # Errors
///
/// [`OpError::Unlowered`] for an open-tier op (spatial `D`, `integral`, user op, or a
/// misspelling); [`OpError::Arity`] for a core op with the wrong argument count.
pub fn check_node(node: &ExpressionNode) -> Result<(), OpError> {
    let op = node.op.as_str();
    let core = node.core_op();

    // A spatial `D` — or any `D` carrying a non-time `wrt` — is a rewrite
    // target, not the structural time derivative.
    if is_rewrite_target_derivative(node) {
        return Err(OpError::Unlowered { op: op.to_string() });
    }

    let Some(arity) = core.map(|c| c.info().arity) else {
        // Open tier: `integral`, user ops and anything unrecognised (including
        // a typo) share one diagnostic — `unlowered_operator` (§9.6.3 c.6).
        return Err(OpError::Unlowered { op: op.to_string() });
    };

    if !arity.admits(node.args.len()) {
        return Err(OpError::Arity {
            op: op.to_string(),
            got: node.args.len(),
            expected: arity.describe(),
        });
    }

    // `makearray` carries its real structure in `regions`/`values`, not `args`,
    // so arity alone says nothing about whether it is well-formed.
    // `broadcast` likewise: `Arity::AtLeast(1)` says nothing about the OPERATOR
    // it applies, which lives in the `fn` field (esm-spec §4.3.4).
    match core {
        Some(CoreOp::Other(OtherOp::Makearray)) => check_makearray_regions(node),
        Some(CoreOp::Other(OtherOp::Broadcast)) => check_broadcast_fn(node),
        _ => Ok(()),
    }
}

/// Walk an expression tree and return the first operator node that may not
/// reach an evaluator.
///
/// The walk uses [`ExpressionNode::for_each_child`], the crate's one-walker
/// keystone, so it descends into every expression-bearing sidecar field
/// (`expr`, `values`, `filter`, `key`, `axes`, `bindings`, …) and not merely
/// `args` — a hand-rolled `args`-only walk would miss exactly the
/// `aggregate.expr` bodies where these malformed nodes hide.
///
/// # Errors
///
/// The first [`OpError`] encountered, in pre-order.
pub fn check_expr(expr: &Expr) -> Result<(), OpError> {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => Ok(()),
        Expr::Operator(node) => {
            check_node(node)?;
            let mut first_err: Option<OpError> = None;
            node.for_each_child(&mut |child| {
                if first_err.is_none()
                    && let Err(e) = check_expr(child)
                {
                    first_err = Some(e);
                }
            });
            match first_err {
                Some(e) => Err(e),
                None => Ok(()),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(json: serde_json::Value) -> Expr {
        serde_json::from_value(json).expect("fixture parses")
    }

    #[test]
    fn spec_arities_are_pinned() {
        assert_eq!(arity_of("atan2"), Some(Arity::Exact(2)));
        assert_eq!(arity_of("min"), Some(Arity::AtLeast(2)));
        assert_eq!(arity_of("max"), Some(Arity::AtLeast(2)));
        assert_eq!(arity_of("/"), Some(Arity::Exact(2)));
        assert_eq!(arity_of("^"), Some(Arity::Exact(2)));
        assert_eq!(arity_of("-"), Some(Arity::Between(1, 2)));
        assert_eq!(arity_of("+"), Some(Arity::AtLeast(1)));
        assert_eq!(arity_of("ifelse"), Some(Arity::Exact(3)));
        assert_eq!(arity_of("const"), Some(Arity::Exact(0)));
        assert_eq!(arity_of("expp"), None, "a typo is not a core op");
    }

    /// R1: the node that used to panic with an index-out-of-bounds.
    #[test]
    fn underapplied_atan2_is_an_arity_error() {
        let e = check_expr(&node(serde_json::json!({"op": "atan2", "args": [1.0]})))
            .expect_err("atan2/1 must be rejected");
        assert!(matches!(e, OpError::Arity { ref op, got: 1, .. } if op == "atan2"));
        let e = check_expr(&node(serde_json::json!({"op": "atan2", "args": []})))
            .expect_err("atan2/0 must be rejected");
        assert!(matches!(e, OpError::Arity { got: 0, .. }));
    }

    /// An empty `neg` is an arity error before any evaluator sees it.
    #[test]
    fn empty_neg_is_an_arity_error() {
        assert!(matches!(
            check_expr(&node(serde_json::json!({"op": "neg", "args": []}))),
            Err(OpError::Arity { got: 0, .. })
        ));
    }

    /// R3: the exact nodes on which the two evaluators disagreed. None of them
    /// is legal, so neither evaluator ever sees one again.
    #[test]
    fn the_divergent_arities_are_all_rejected() {
        for j in [
            serde_json::json!({"op": "-", "args": [3.0, 1.0, 1.0]}),
            serde_json::json!({"op": "/", "args": [8.0, 2.0, 2.0]}),
            serde_json::json!({"op": "^", "args": [2.0, 3.0, 4.0]}),
            serde_json::json!({"op": "min", "args": [5.0]}),
            serde_json::json!({"op": "max", "args": [5.0]}),
            serde_json::json!({"op": "and", "args": [5.0]}),
        ] {
            let e = check_expr(&node(j.clone()));
            assert!(
                matches!(e, Err(OpError::Arity { .. })),
                "{j} must be an arity error, got {e:?}"
            );
        }
    }

    #[test]
    fn legal_arities_pass() {
        for j in [
            serde_json::json!({"op": "+", "args": ["a", "b", "c"]}),
            serde_json::json!({"op": "-", "args": ["a"]}),
            serde_json::json!({"op": "-", "args": ["a", "b"]}),
            serde_json::json!({"op": "min", "args": ["a", "b", "c"]}),
            serde_json::json!({"op": "atan2", "args": ["a", "b"]}),
            serde_json::json!({"op": "ifelse", "args": ["c", "a", "b"]}),
            serde_json::json!({"op": "D", "args": ["u"], "wrt": "t"}),
        ] {
            check_expr(&node(j.clone())).unwrap_or_else(|e| panic!("{j} should be legal: {e}"));
        }
    }

    /// R7: a misspelled op is loud, not a silent `NaN`.
    #[test]
    fn a_typo_is_an_unlowered_operator() {
        let e = check_expr(&node(serde_json::json!({"op": "expp", "args": ["x"]})))
            .expect_err("a typo must be rejected");
        assert!(matches!(e, OpError::Unlowered { ref op } if op == "expp"));
    }

    #[test]
    fn user_ops_and_spatial_d_are_unlowered() {
        for j in [
            serde_json::json!({"op": "godunov_hamiltonian", "args": ["u"], "dim": "x"}),
            serde_json::json!({"op": "integral", "args": ["u"], "dim": "x"}),
            serde_json::json!({"op": "D", "args": ["u"], "wrt": "x"}),
        ] {
            assert!(
                matches!(check_expr(&node(j.clone())), Err(OpError::Unlowered { .. })),
                "{j} must be unlowered"
            );
        }
    }

    /// R5: the two `makearray` region shapes that panicked the evaluator.
    #[test]
    fn ragged_and_inverted_makearray_regions_are_rejected() {
        // Ragged: region 1 has rank 2, region 0 has rank 1.
        let ragged = node(serde_json::json!({
            "op": "makearray",
            "regions": [[[1, 3]], [[1, 3], [1, 2]]],
            "values": [0.0, 1.0],
            "args": []
        }));
        assert!(
            matches!(check_expr(&ragged), Err(OpError::MakearrayRegion { .. })),
            "a ragged regions list must be rejected, not panic"
        );

        // Inverted: [5, 2] has stop < start - 1 (extent would be -2).
        let inverted = node(serde_json::json!({
            "op": "makearray",
            "regions": [[[5, 2]]],
            "values": [0.0],
            "args": []
        }));
        assert!(
            matches!(check_expr(&inverted), Err(OpError::MakearrayRegion { .. })),
            "an inverted region must be rejected, not overflow ArrayD::zeros"
        );
    }

    /// The legal EMPTY spelling `stop == start - 1` (§4.3.2) — what a
    /// metaparameter-folded interior region produces at its minimum extent —
    /// must still load cleanly. This is the boundary the inverted check must
    /// not overshoot.
    #[test]
    fn the_empty_region_spelling_is_legal() {
        let empty = node(serde_json::json!({
            "op": "makearray",
            "regions": [[[2, 1]], [[1, 1]]],
            "values": [0.0, 1.0],
            "args": []
        }));
        check_expr(&empty).expect("[2, 1] is the canonical empty region and is legal");
    }

    /// The walk must descend into sidecar fields, not just `args` — a malformed
    /// node hiding in an `aggregate.expr` body is the whole point.
    #[test]
    fn the_walk_descends_into_sidecar_fields() {
        let agg = node(serde_json::json!({
            "op": "faq",
            "output_idx": ["i"],
            "expr": {"op": "atan2", "args": [1.0]},
            "args": ["u"]
        }));
        assert!(
            matches!(check_expr(&agg), Err(OpError::Arity { .. })),
            "an arity error inside `aggregate.expr` must be found"
        );
    }

    // -----------------------------------------------------------------------
    // Issues #100 / #101 — the scalar-operator set. ONE list answers both
    // "what may a `broadcast.fn` name?" and "does element alignment descend
    // through this node?", so both branches' pins run against it.
    // -----------------------------------------------------------------------

    /// Every op this registry knows, partitioned by [`is_scalar_operator`].
    ///
    /// The list is exhaustive over [`arity_of`] as of this commit. Adding an op
    /// to `arity_of` without deciding which side it falls on will fail
    /// `the_scalar_operator_set_partitions_the_core`, which is the point: both
    /// `broadcast.fn` legality and array-level element alignment (esm-spec
    /// §4.3.4) are defined by this partition, and a new op silently defaulting
    /// to "not scalar" is a decision, not an accident.
    const SCALAR: &[&str] = &[
        "+", "-", "*", "/", "^", "neg", "exp", "log", "log10", "sqrt", "abs", "sign", "floor",
        "ceil", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh",
        "acosh", "atanh", "atan2", "min", "max", "ifelse", "==", "!=", "<", "<=", ">", ">=", "and",
        "or", "not",
    ];
    /// Core ops pinned by their own tests rather than by the two lists above:
    /// the deprecated `pow` (not a `broadcast.fn`) and the engine-internal
    /// precision marker.
    const UNPARTITIONED: &[&str] = &["pow", crate::precision_infer::MARKER_OP];
    const NOT_SCALAR: &[&str] = &[
        "D",
        "ic",
        "Pre",
        "const",
        "true",
        "false",
        "enum",
        "apply_expression_template",
        "faq",
        "makearray",
        "index",
        "broadcast",
        "reshape",
        "transpose",
        "concat",
        "distinct",
    ];

    /// [`is_scalar_operator`] may only CLASSIFY registry ops, never invent them.
    #[test]
    fn the_scalar_operator_set_partitions_the_core() {
        for op in SCALAR {
            assert!(is_core_op(op), "`{op}` is scalar but not a core op");
            assert!(is_scalar_operator(op), "`{op}` should be a scalar operator");
        }
        for op in NOT_SCALAR {
            assert!(is_core_op(op), "`{op}` is listed but not a core op");
            assert!(
                !is_scalar_operator(op),
                "`{op}` should not be a scalar operator"
            );
        }
    }

    /// Every core operator is on exactly one side of the scalar partition, so
    /// a new operator cannot reach the table without the decision being
    /// written down here; and the name round-trips through the enum.
    #[test]
    fn the_partition_covers_every_core_op_and_names_round_trip() {
        let mut names = std::collections::HashSet::new();
        for op in CoreOp::all() {
            assert_eq!(CoreOp::from_name(op.name()), Some(op));
            assert!(names.insert(op.name()), "`{}` is spelled twice", op.name());
            let listed = SCALAR.contains(&op.name()) as u8
                + NOT_SCALAR.contains(&op.name()) as u8
                + UNPARTITIONED.contains(&op.name()) as u8;
            assert_eq!(listed, 1, "`{}` must be listed exactly once", op.name());
        }
        assert_eq!(
            names.len(),
            SCALAR.len() + NOT_SCALAR.len() + UNPARTITIONED.len()
        );
    }

    /// The built-in-function-head excuse set, pinned exactly: the named
    /// elementary functions and reductions, `ifelse`, and `Pre`. Every name is
    /// a core op (the set only CLASSIFIES registry ops), and the
    /// identifier-shaped core spellings the undefined-variable gates have
    /// never excused stay excluded — widening the set would silently pass a
    /// genuinely undeclared variable carrying one of those names.
    #[test]
    fn builtin_function_names_are_core_and_nothing_widened() {
        const BUILTIN: &[&str] = &[
            "exp", "log", "log10", "sqrt", "abs", "sign", "sin", "cos", "tan", "asin", "acos",
            "atan", "atan2", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh", "min", "max",
            "floor", "ceil", "ifelse", "Pre",
        ];
        for name in BUILTIN {
            assert!(
                is_builtin_function_name(name),
                "`{name}` must be an excused built-in function head"
            );
            assert!(is_core_op(name), "`{name}` is excused but not a core op");
        }
        for name in [
            "neg", "ln", "and", "or", "not", "D", "ic", "const", "true", "faq", "index", "expp",
            "t",
        ] {
            assert!(
                !is_builtin_function_name(name),
                "`{name}` must not be excused as a built-in function head"
            );
        }
    }

    /// `pow` and `false` are evaluable-core ops: `pow` is the DEPRECATED word
    /// spelling of `^` (esm-spec §4.2 "Deprecated ops"; the loader rewrites
    /// it, but a code-built node still evaluates) and `false` the nullary
    /// counterpart of `true`, as the Julia and Python registries list them.
    /// Neither is a `broadcast.fn` — the §4.3.4 scalar-operator list names
    /// `^`, not `pow`, and a literal has no operands.
    ///
    /// `**`, `power` and `=` are still not operators in this format: they are
    /// open-tier names, rejected as `unlowered_operator` when a model carrying
    /// one is built. Adding them to [`is_scalar_operator`] so array-level
    /// alignment covers them would invent operators the spec's §4.2 table does
    /// not have, and would not make them runnable either.
    /// Each deprecated spelling is a core op whose arity is one its
    /// replacement admits, so the loader's rewrite keeps a legal node legal
    /// and never reaches a different meaning (`neg` takes exactly one operand,
    /// where `-` also admits two).
    #[test]
    fn deprecated_ops_are_core_and_rewrite_to_core_ops() {
        assert_eq!(deprecated_op("neg"), Some(("neg", "-")));
        assert_eq!(deprecated_op("pow"), Some(("pow", "^")));
        assert_eq!(deprecated_op("-"), None);
        assert_eq!(deprecated_op("**"), None);
        for (old, new) in CoreOp::all().filter_map(|c| c.replaced_by().map(|r| (c, r))) {
            let (a, b) = (old.info().arity, new.info().arity);
            for n in 0..4 {
                if a.admits(n) {
                    assert!(b.admits(n), "`{new}` must admit {n} operands like `{old}`");
                }
            }
        }
    }

    #[test]
    fn pow_and_false_are_core_and_the_other_spellings_are_not() {
        assert_eq!(arity_of("pow"), Some(Arity::Exact(2)));
        assert_eq!(arity_of("false"), Some(Arity::Exact(0)));
        for op in ["pow", "false"] {
            assert!(
                !is_scalar_operator(op),
                "`{op}` must not be a scalar operator"
            );
        }
        for op in ["**", "power", "="] {
            assert!(!is_core_op(op), "`{op}` must not be a registry op");
            assert!(
                !is_scalar_operator(op),
                "`{op}` must not be a scalar operator"
            );
            assert!(
                matches!(
                    check_node(&ExpressionNode {
                        op: op.to_string(),
                        args: vec![Expr::Variable("z".into()), Expr::Number(2.0)],
                        ..Default::default()
                    }),
                    Err(OpError::Unlowered { .. })
                ),
                "`{op}` must be reported as an open-tier / unlowered operator"
            );
        }
    }

    /// The exclusions are the load-bearing half of `is_scalar_operator`: none of
    /// these has a pointwise meaning, so none may be spelled as a `broadcast.fn`.
    /// `broadcast` itself is in [`NOT_SCALAR`] — allowing it would make the
    /// evaluators' `fn` re-dispatch recurse forever. The two trailing names are
    /// not registry ops at all: an open-tier rewrite target and a typo.
    #[test]
    fn non_pointwise_ops_are_not_scalar_operators() {
        for op in NOT_SCALAR
            .iter()
            .copied()
            .chain(["godunov_hamiltonian", "not_a_real_op"])
        {
            assert!(
                !is_scalar_operator(op),
                "`{op}` must NOT be usable as a `broadcast` fn"
            );
        }
    }

    /// The headline bug: `fn: "not_a_real_op"` was accepted and then silently
    /// discarded, so the node evaluated to its operand.
    #[test]
    fn unregistered_broadcast_fn_is_rejected() {
        let e = check_expr(&node(serde_json::json!({
            "op": "broadcast", "fn": "not_a_real_op", "args": ["x"]
        })))
        .expect_err("an unregistered `fn` must be rejected");
        assert!(
            matches!(e, OpError::BroadcastFn { fn_name: Some(ref f), .. } if f == "not_a_real_op"),
            "got {e:?}"
        );
    }

    /// A MISSING `fn` used to default to `+` in all three evaluators. There is
    /// no default in the spec.
    #[test]
    fn missing_broadcast_fn_is_rejected() {
        let e = check_expr(&node(
            serde_json::json!({"op": "broadcast", "args": ["x", "y"]}),
        ))
        .expect_err("a `broadcast` with no `fn` must be rejected");
        assert!(
            matches!(e, OpError::BroadcastFn { fn_name: None, .. }),
            "got {e:?}"
        );
    }

    /// A non-scalar op named as `fn` is rejected for the same reason a typo is:
    /// §4.3.4 requires a SCALAR operator.
    #[test]
    fn non_scalar_broadcast_fn_is_rejected() {
        for f in ["faq", "index", "makearray", "broadcast", "enum", "D"] {
            let e = check_expr(&node(serde_json::json!({
                "op": "broadcast", "fn": f, "args": ["x"]
            })))
            .expect_err("a non-scalar `fn` must be rejected");
            assert!(
                matches!(e, OpError::BroadcastFn { fn_name: Some(ref g), .. } if g == f),
                "fn `{f}`: got {e:?}"
            );
        }
    }

    /// `broadcast(fn = F, args)` is legal exactly when `{op: F, args}` is —
    /// which is also what it now MEANS. The arity rule is therefore derived
    /// from `arity_of(F)`, not hard-coded.
    #[test]
    fn broadcast_fn_arity_mirrors_the_bare_node() {
        let legal = |f: &str, n: usize| {
            let args: Vec<serde_json::Value> =
                (0..n).map(|i| serde_json::json!(format!("x{i}"))).collect();
            check_expr(&node(
                serde_json::json!({"op": "broadcast", "fn": f, "args": args}),
            ))
        };
        // n-ary ops fold to the identity on one operand — `+(x)` is `x` — so a
        // one-operand broadcast of them stays legal.
        legal("+", 1).expect("`+` is n-ary from 1");
        legal("*", 3).expect("`*` is n-ary");
        // `-` is unary OR binary: negation or subtraction, exactly as bare.
        legal("-", 1).expect("unary `-` is negation");
        legal("-", 2).expect("binary `-` is subtraction");
        assert!(matches!(legal("-", 3), Err(OpError::Arity { got: 3, .. })));
        // Strictly binary.
        assert!(matches!(legal("/", 1), Err(OpError::Arity { ref op, got: 1, .. }) if op == "/"));
        assert!(matches!(
            legal("atan2", 3),
            Err(OpError::Arity { got: 3, .. })
        ));
        // `min`/`max` are n-ary with n >= 2 (§4.2 "MUST reject … fewer than
        // two"), so a ONE-operand `broadcast(fn="min")` is an arity error —
        // the same verdict the bare `{"op":"min","args":[x]}` node gets.
        assert!(
            matches!(legal("min", 1), Err(OpError::Arity { ref op, got: 1, .. }) if op == "min")
        );
        legal("min", 2).expect("`min` of two is fine");
        // Unary elementary functions: exactly one. A 2-arg `broadcast(fn="sin")`
        // used to resolve to `BinCode::Unknown` and evaluate to NaN in silence.
        legal("sin", 1).expect("`sin` is unary");
        assert!(
            matches!(legal("sin", 2), Err(OpError::Arity { ref op, got: 2, .. }) if op == "sin")
        );
        legal("neg", 1).expect("`neg` is unary");
        assert!(matches!(
            legal("neg", 2),
            Err(OpError::Arity { got: 2, .. })
        ));
        legal("ifelse", 3).expect("`ifelse` is ternary");
        assert!(matches!(
            legal("ifelse", 2),
            Err(OpError::Arity { got: 2, .. })
        ));
    }

    /// The in-tree authored idiom (`canonicalize.rs`): a ONE-operand
    /// `broadcast` of a unary function.
    #[test]
    fn one_operand_unary_broadcast_stays_legal() {
        check_expr(&node(serde_json::json!({
            "op": "broadcast", "fn": "sin", "args": ["u"]
        })))
        .expect("`broadcast(fn=\"sin\", [u])` is the authored unary spelling");
        check_expr(&node(serde_json::json!({
            "op": "broadcast", "fn": "exp", "args": ["A"]
        })))
        .expect("`broadcast(fn=\"exp\", [A])` is the authored unary spelling");
    }

    /// [`is_elementwise_node`] sees through a `broadcast` to its `args`, because
    /// `broadcast(fn: F, args)` MEANS `{op: F, args}` — so the two spellings of
    /// one array-level expression align their operands identically (issue #100).
    /// The `fn` guard keeps that conservative: a `broadcast` whose `fn` is not a
    /// scalar operator has no elementwise meaning to preserve.
    #[test]
    fn is_elementwise_node_sees_through_broadcast() {
        let bcast = |f: Option<&str>| ExpressionNode {
            op: "broadcast".to_string(),
            broadcast_fn: f.map(str::to_string),
            args: vec![Expr::Variable("a".into()), Expr::Variable("b".into())],
            ..Default::default()
        };
        assert!(is_elementwise_node(&bcast(Some("*"))));
        assert!(is_elementwise_node(&bcast(Some("atan2"))));
        // An absent `fn` keeps the historical `+` classification; the node
        // itself is now rejected by `check_broadcast_fn` (issue #101).
        assert!(is_elementwise_node(&bcast(None)));
        // Not a scalar operator: stay out.
        assert!(!is_elementwise_node(&bcast(Some("pow"))));
        assert!(!is_elementwise_node(&bcast(Some("faq"))));

        // The NODE question and the NAME question differ on exactly one input:
        // a `broadcast` node is elementwise in its args, but the string
        // "broadcast" is not a legal kernel name.
        assert!(!is_scalar_operator("broadcast"));

        // Non-`broadcast` nodes are classified by name alone, as before.
        let named = |op: &str| ExpressionNode {
            op: op.to_string(),
            args: vec![Expr::Variable("a".into())],
            ..Default::default()
        };
        assert!(is_elementwise_node(&named("*")));
        assert!(!is_elementwise_node(&named("index")));
        assert!(!is_elementwise_node(&named("distinct")));
    }
}
