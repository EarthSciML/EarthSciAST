# tree_walk/scalar_cse.jl — scalar common-subexpression elimination: keying, counting and
# `_compile_cse` / `_cse_compile_scalar`.

# ============================================================
# Common-subexpression elimination — an evaluation-time memo
# ============================================================
#
# APPROACH: eval-time memoization. The serialized IR and the canonical goldens are
# UNCHANGED — CSE only restructures how the compiled tree-walk evaluator computes a
# RHS, so results are numerically identical and the cross-binding conformance suite
# is untouched by construction. Lives only in this Julia evaluator.
#
# KEY = `canonical_json(expr)` (canonicalize.jl), the existing cross-binding
# canonical form. Two subexpressions are "common" iff their canonical bytes are
# equal, which makes keying on it conformance-safe by construction. No parallel
# canonicalizer is introduced.
#
# SHARING HANDLE = a value-number (Int cache slot) per distinct key. A shared
# subexpression is named once and referenced from each use site by a `_NK_CACHED`
# leaf carrying that slot. Children are compiled (and hoisted) before their parent,
# so a cached subexpression's slot is always lower than the slots referencing it and
# the prelude is topologically ordered by construction.
#
# MEMO POINT = a per-`f!`-call scratch `cache::Vector{Float64}`. The prelude
# evaluates each distinct cached subexpression exactly ONCE per call, in slot order;
# every occurrence then reads `cache[slot]`.
#
# IDENTITY IS CANONICAL, NOT STRUCTURAL — a decision, not an accident.
# `canonical_json` flattens n-ary `+`/`*` and sorts their arguments, so
# reassociation-equivalent expressions SHARE A SLOT (`(a+b)+c` and `a+(b+c)` have
# one key), and the FIRST-SEEN operand order is what every occurrence reads back
# (the slot's def is compiled from the first occurrence — `_cse_rebuild`).
#
# The consequence is worth naming, because it is surprising: since float `+`/`*` are
# not associative, an equation's numeric output is NOT a function of that equation
# alone — adding a canonically-equal expression elsewhere in the model can shift it.
# The difference is bounded by float reassociation of a CANONICALLY EQUAL expression
# (normally sub-ulp; catastrophic cancellation can amplify it), and the format
# already reassociates freely: `discretize` canonicalizes each per-cell RHS before it
# is ever compiled, so canonical form IS this format's notion of expression identity.
# Keying structurally instead would restore per-equation locality but lose
# commutative sharing (which tree_walk_cse_test.jl pins) and would itself change the
# numbers of models that work today. The property is PINNED by a test, not latent.
#
# A model with nothing to share gets an empty prelude, and `_compile_cse` then
# produces the identical `_Node` tree `_compile` would.
#
# GUARDS — the prelude is UNCONDITIONAL, the walker is LAZY. `_make_rhs` fills every
# slot at the top of every call, while `_eval_node_op` is lazy for `ifelse` and
# short-circuits `and`/`or`. Hoisting a subexpression that occurs ONLY under a guard
# would evaluate it when no guard fires — turning `ifelse(a >= 0, sqrt(a), 0)` at
# `a = -1` into a `DomainError`. So a key is hoisted iff
#
#     total_occurrences >= 2   AND   unconditional_occurrences >= 1
#
# (`_cse_count!`). If a key has an unconditional occurrence the original walk
# evaluates it anyway at that occurrence, so evaluating it once in the prelude is
# exactly as safe, and the GUARDED occurrences may then freely read the cache. A key
# occurring only under guards is left inline, where its guard still protects it.
# This is deliberately not "refuse to recurse into guarded arms", which would lose
# legitimate sharing within an arm and between an arm and an unconditional one.
#
# Every walker is lazy for `ifelse` and short-circuits `and`/`or`: the scalar
# `_eval_node` and the access-kernel `_eval_acc_op` alike (the eager ladder is the
# shared `_scalar_op`, which receives evaluated operands). The access-kernel CSE
# applies the same rule to its own unconditional tiers (`_build_acc_cse`).
#
# SCOPE — why this pass is scalar-only. Redundancy is removed at three layers:
#   * cross-grid-cell  — by whole-array kernels (one broadcast per structural cell
#                        group), so a stencil is never re-walked per cell;
#   * intra-expression — at DISCRETIZE time, since canonicalization already merges
#                        like additive/multiplicative terms;
#   * cross-equation / intra-RHS across nonlinear contexts — SURVIVES canonicalize,
#                        which normalizes one expression at a time and does not
#                        combine `sin(a+b)` with `cos(a+b)`, or share a reaction flux
#                        `k*A*B` across several species balances. That is this pass.
# Cross-KERNEL sharing of a lane-invariant subtree across several faq equations
# is a separate pass, keyed structurally on the kernel spine rather than on
# `canonical_json`: see tree_walk/xcse.jl.
#
# WHAT THIS PASS NO LONGER CARRIES: AUTHOR-NAMED sharing. Scalar
# observeds now compile as NAMED PRELUDE DEFS in this same prelude
# (`_plan_observed_slots` in build_classify.jl; the `obs_defs` argument of
# `_cse_compile_scalar`), so what is left for the canonical-key machinery is exactly
# the ANONYMOUS repeats — a subexpression written twice without a name.

# Ops CSE must not look at: array/aggregate producers, const/enum data carriers,
# and the unresolved/illegal-in-RHS markers. CSE never hoists a node rooted at
# one of these and never rewrites their operands — such subtrees delegate to
# plain `_compile`. Everything else is a pure, deterministic scalar node whose
# value depends only on `(u, p, t)`, so naming it once and reading the name back
# is value-preserving.
#
# Membership is declared per-op in src/op_registry.jl (flag `:cse_opaque`)
# and pinned by op_registry_test.jl.
const _CSE_OPAQUE_OPS = _ops_with(:cse_opaque)

# A node is a CSE hoist/recurse candidate iff it is an OpExpr whose op is
# evaluable-core (`+`, `sin`, …). Two disjoint reasons disqualify a node:
#   (1) it is a CSE-opaque core form (`_CSE_OPAQUE_OPS` — `const`/`index`/`D`/…,
#       structural ops `_compile` lowers or rejects specially); or
#   (2) it is an open-tier rewrite-target op (`_op_in_T`: a named
#       `D`/`integral`/… OR any unregistered custom op).
# A rewrite-target op is NOT evaluable — a discretization rule must lower it
# first — so it must never be hoisted into a guardless generic `_cse_rebuild`
# node (which would defer the failure to evaluation). The same holds for a core
# op with no ladder arm (3): hoisting one would skip `_compile_op`'s
# `unevaluable_operator` gate.
# Keeping every T op non-hoistable routes it to `_compile`/`_compile_op`, the
# one path carrying the GENERIC `unlowered_operator` rejection gate. Leaves (state/param/literal/time) are never hoisted — caching a leaf costs
# more than the bare read it would replace.
_cse_hoistable(e::OpExpr) =
    _tpl_is_call(e) ||    # a template call is a pure function of its arguments (call.jl)
    (!(e.op in _CSE_OPAQUE_OPS) && !_op_in_T(e.op) && _has_tree_walk_rule(e.op))

# `_eval_node_op` has an arm for exactly the shaped registry rows
# (`_SHAPED_OP_SYMS`). `_compile_op` refuses any other op reaching its generic
# tail with `unevaluable_operator` (esm-spec §9.6.6).
_has_tree_walk_rule(op::AbstractString) = Symbol(op) in _SHAPED_OP_SYMS
_cse_hoistable(::ASTExpr) = false

# ---- Keying an expression built over a live forcing buffer ----------------------
#
# A resolved `param_arrays` gather is an argless `index` node carrying a
# `_PGatherRef` in `value` (see `_PGatherRef`). `_PGatherRef` is a runtime payload,
# not a JSON type, so `canonical_json` throws on it, and since it is canonicalized
# as a CHILD of every hoistable ancestor, that throw would decline sharing for the
# whole met→physics stack sitting above a forcing buffer: a scalar equation
# reading `index(forcing, …)` and every observed slot's definition. So the gather
# is keyed as a LEAF with a canonicalizable, DISTINGUISHABLE identity:
#
#     OpExpr("index", []; name="__pgather", value=[<buffer name>, <linear offset>])
#
# both of which `_emit_canonical_value` handles (AbstractString / Integer inside an
# AbstractArray). The gather itself STAYS CSE-opaque — it is never hoisted into the
# prelude (a live buffer read is one indexed load, cheaper than a cache slot); the
# point is only that its ancestors can now be keyed.
#
# DISTINCTNESS is the whole safety argument, and it is the one way this can go
# catastrophically wrong: if two gathers collide on a key, CSE MERGES them and the
# model computes silently wrong numbers. `(buffer name, linear offset)` is
# injective onto `(buffer, element)` because the buffer name is its KEY in the
# build's `pgather` dict — distinct buffers cannot share a name — and every entry
# (raw `param_arrays` buffers in `_build_pgather`, discrete-cadence caches in
# `_build_discrete_materializer!`) is registered before any expression is resolved
# against the dict, so a name resolves to one buffer for the whole resolve phase.
# `_pgather_check_distinct!` re-verifies that at key time rather than assuming it.
#
# LIVENESS is unaffected. Hoisting an expression built OVER a gather caches the
# expression's VALUE for one `f!` call only — the prelude is refilled at the top of
# every call — and a forcing buffer cannot change mid-call (it is refreshed by a
# discrete callback BETWEEN steps, and a discrete cache by `materialize!`). So the
# cached value is exactly what the inline walk would have computed at that call.
const _PGATHER_KEY_NAME = "__pgather"

# Per-build context for the stand-in rewrite: an identity memo (each node rewritten
# at most once, so the whole pass is O(nodes) across every `_cse_key` call) plus the
# distinctness witness (`name` → the buffer it was seen bound to).
struct _PGatherKeyCtx
    memo::IdDict{OpExpr, ASTExpr}
    seen::Dict{String, Vector{Float64}}
end
_PGatherKeyCtx() = _PGatherKeyCtx(IdDict{OpExpr, ASTExpr}(), Dict{String, Vector{Float64}}())

# The key identity `(name, lin)` is only injective if `name` names ONE buffer. That
# holds by construction today; check it anyway, because the failure mode of a broken
# assumption here is wrong numbers, not lost sharing.
function _pgather_check_distinct!(ctx::_PGatherKeyCtx, ref::_PGatherRef)
    prev = get(ctx.seen, ref.name, nothing)
    if prev === nothing
        ctx.seen[ref.name] = ref.flat
    elseif prev !== ref.flat
        throw(
            TreeWalkError(
                "E_TREEWALK_PGATHER_KEY_COLLISION",
                "internal: forcing-buffer name '$(ref.name)' resolved to two different " *
                    "buffers within one build. The CSE key for a live gather is " *
                    "(buffer name, offset); a name bound to two buffers would let CSE merge " *
                    "two DIFFERENT reads into one cache slot. Registration of every `pgather` " *
                    "entry must precede expression resolution — that invariant is broken."
            )
        )
    end
    return nothing
end

# Replace every resolved live-forcing gather in `e` with its canonicalizable
# stand-in, leaving everything else alone. IDENTITY-PRESERVING in the style of
# `_sub_preserving`: a subtree containing no `_PGatherRef` is returned as the SAME
# object, so a model with no forcing buffers is untouched (and `_cse_key` skips this
# pass entirely — `ctx === nothing`). Rewritten nodes are memoized by object
# identity, so a subexpression shared across equations is rewritten once.
_pgather_key_expr(e::ASTExpr, ::_PGatherKeyCtx) = e   # NumExpr / IntExpr / VarExpr
function _pgather_key_expr(e::OpExpr, ctx::_PGatherKeyCtx)
    r = get(ctx.memo, e, nothing)
    r === nothing || return r
    r = _pgather_key_expr_uncached(e, ctx)
    ctx.memo[e] = r
    return r
end
function _pgather_key_expr_uncached(e::OpExpr, ctx::_PGatherKeyCtx)
    # The ref is keyed off the `value` field rather than off `op == "index"`, so any
    # future node that carries one is keyed (never silently declined) too.
    if e.value isa _PGatherRef
        ref = e.value::_PGatherRef
        _pgather_check_distinct!(ctx, ref)
        return OpExpr(
            e.op, ASTExpr[]; name = _PGATHER_KEY_NAME,
            value = Any[ref.name, ref.lin]
        )
    end
    # `map_children` (expression.jl) is the ONE field-preserving rewrite primitive —
    # it visits every expression-bearing field, so a gather buried in an aggregate
    # body / filter / range bound is rewritten too. Its rebuilt node is DISCARDED
    # when no descendant changed, which is what keeps this identity-preserving.
    changed = false
    rebuilt = map_children(e) do c
        r = _pgather_key_expr(c, ctx)
        changed |= r !== c
        return r
    end
    return changed ? rebuilt : e
end

# Canonical-form key for a subexpression, or `nothing` if it cannot be keyed
# safely. A `nothing` key disables sharing for that subtree — CSE is a pure
# optimization and silently declines anything it cannot key safely.
#
# `pgctx` is the live-forcing stand-in context (above) when the build binds any
# `param_arrays` buffer or discrete cache, and `nothing` otherwise — in which case
# no `_PGatherRef` can exist and the key is the expression's own.
#
# ---------------------------------------------------------------------------
# WHY A BARE-LITERAL CANONICAL FORM IS REFUSED
#
# The CSE key is `canonical_json`, and `canonicalize` contains folds that are NOT
# value-preserving on the IEEE reals: `_canon_mul` maps `x*0 → 0` and `_canon_div`
# maps `0/x → 0` **regardless of x**. Those are wrong when `x` is `Inf` or `NaN`
# (`Inf*0` is `NaN`, not `0`), which is fine for a canonical *identity* key in the
# abstract-algebra sense, but fatal for CSE: two structurally DIFFERENT
# expressions both canonicalize to the literal `0.0`, `_cse_count!` sees one key
# with two occurrences, hoists ONE slot, and compiles that slot's definition from
# whichever occurrence it saw FIRST. Every other occurrence then reads a value
# computed from a different expression.
#
#     D(x) = (1/z)*0                 alone  ->  du[x] = NaN   (correct: Inf*0)
#     D(y) = w*0  ;  D(x) = (1/z)*0         ->  du[x] = 0.0   (WRONG)
#
# `D(x)` is byte-identical between the two models: adding an UNRELATED equation
# changed another equation's value, and the error is unbounded (NaN ↔ 0.0), not
# the sub-ulp reassociation drift the existing pin at the top of this file
# describes. Fail-close: refuse to key any subexpression whose canonical form
# collapses to a bare literal.
#
# A canonical form that collapses to a bare VARIABLE (`x*1 → x`, `x+0 → x`) is
# NOT refused: those folds *are* value-preserving, so two expressions sharing
# such a key really do compute the same value.
# ---------------------------------------------------------------------------
function _cse_key(e::ASTExpr, pgctx::Union{Nothing, _PGatherKeyCtx})
    return _cse_key(e, pgctx, _CSEKeyMemos())
end

# Per-build memos for CSE keying over a structurally-SHARED expression DAG
# (template expansion splices identical subtrees by reference, so the same
# node object hangs under exponentially many paths):
#
#   * `canon` — node object → its canonical form (or the `CanonicalizeError`
#     it raised, replayed on every later consumer so a shared failing subtree
#     declines every ancestor exactly as the plain recursion did).
#   * `key`   — node object → its `_cse_key` result (a number or `nothing`).
#   * `num`, `ids` — the canonical-node numbering (`_cse_node_number!`).
#
# `canon` and `key` are keyed on OBJECT IDENTITY: keying is a pure function of the node
# (and the build-constant `pgctx`), so one computation per unique node is
# byte-identical to one per path. The count pass and the compile pass share
# ONE memo pair (via `_CSEContext`) for the same reason they share `pgctx`.
struct _CSEKeyMemos
    canon::IdDict{OpExpr, Any}   # ASTExpr result or CanonicalizeError
    key::IdDict{OpExpr, Any}     # Int or nothing
    num::IdDict{OpExpr, Int}     # canonical node => its number (`_cse_node_number!`)
    ids::Dict{Any, Int}          # a node's fields and operand numbers => its number
end
_CSEKeyMemos() = _CSEKeyMemos(
    IdDict{OpExpr, Any}(), IdDict{OpExpr, Any}(), IdDict{OpExpr, Int}(), Dict{Any, Int}()
)

# The number of a canonical node: two nodes get one number exactly when their
# canonical JSON (`_emit_node_json`) is equal. The JSON is a function of the
# node's emitted fields (`_EMISSIBLE_FIELDS`, canonicalize.jl) and its operands'
# JSON, injectively (strings are quoted, numbers and nested values are
# canonical), so the tuple of those fields, with each operand node's NUMBER in
# place of its JSON, is equal exactly when the JSON is, by induction on the
# operands. The tuple is built from that same field list, so a field the
# emitter carries is never left out of the key. A bare operand keeps the JSON
# text (or its name, for a variable, whose JSON is the quoted name); the fields
# the JSON cannot carry raise as the emission does. Keying a template call site
# this way costs one node's fields, where its JSON is its whole body.
function _cse_node_number!(e::OpExpr, M::_CSEKeyMemos)
    v = get(M.num, e, 0)
    v == 0 || return v
    _check_emissible(e)
    ops = Vector{Any}(undef, length(e.args))
    for (i, a) in enumerate(e.args)
        ops[i] = a isa OpExpr ? _cse_node_number!(a, M) :
            a isa VarExpr ? (:var, a.name) : _emit_json(a)
    end
    key = map(f -> _cse_field_key(e, f, ops), _EMISSIBLE_FIELDS)
    # A template call's arguments are its `bindings`, which the canonical JSON
    # does not carry: they enter the key here, each numbered like an operand.
    _tpl_is_call(e) && (key = (key, _cse_bindings_key(e, M)))
    n = get!(M.ids, key, length(M.ids) + 1)
    M.num[e] = n
    return n
end

# The bindings of a template call in its CSE key: each binding's canonical
# number, by name. A binding whose canonical form collapses to a literal is
# keyed by identity (never shared), as `_cse_key` refuses such a collapse.
function _cse_bindings_key(e::OpExpr, M::_CSEKeyMemos)
    b = e.bindings
    b === nothing && return ()
    out = Any[]
    for k in sort!(collect(keys(b)))
        v = b[k]
        c = v isa OpExpr ? _canonicalize_memo(v, M.canon) : v
        num = c isa OpExpr ? _cse_node_number!(c, M) :
            c isa VarExpr ? (:var, c.name) :
            v isa OpExpr ? (:unique, objectid(v)) : _emit_json(c)
        push!(out, k => num)
    end
    return Tuple(out)
end

# One emitted field of `e` in its CSE key: the operand numbers for `args`, the
# canonical value for `value`, the field itself otherwise.
_cse_field_key(e::OpExpr, f::Symbol, ops::Vector{Any}) =
    f === :args ? ops : f === :value ? _cse_value_key(e.value) : getfield(e, f)

# A node's `value` in its key: the canonical JSON of a document value, or, for
# the run-time const gather (`_ConstGatherRef`, which no JSON carries), the
# identity of the array it reads. One array object is one registry entry for
# the whole build, and the subscripts are the node's operands, so two gathers
# share a key exactly when they read the same element.
_cse_value_key(::Nothing) = nothing
_cse_value_key(v::_ConstGatherRef) = (:const_gather, v.name, objectid(v.vals))
_cse_value_key(v::_GatherBoundsRef) = (:gather_bounds, v.name, Tuple(v.dims))
_cse_value_key(v) = _emit_canonical_value(v)

# The number of a canonical form that is a bare variable (`x * 1`), in the
# same numbering: such a key's JSON is the quoted name.
_cse_leaf_number!(e::ASTExpr, M::_CSEKeyMemos) =
    get!(M.ids, (:leaf, e isa VarExpr ? (:var, e.name) : _emit_json(e)), length(M.ids) + 1)

# Identity-memoized `canonicalize`: drives the recursion over unique nodes
# only, delegating the per-node work to `_canonicalize_shallow`
# (canonicalize.jl) — `canonicalize` is compositional, so this is
# byte-identical to the plain recursion on any tree and processes a shared
# subtree once on a DAG. A `CanonicalizeError` is memoized and re-thrown so
# repeated consumers of a failing shared subtree see the plain behavior.
function _canonicalize_memo(e::ASTExpr, memo::IdDict{OpExpr, Any})
    e isa OpExpr || return canonicalize(e)
    v = get(memo, e, nothing)
    if v !== nothing
        v isa CanonicalizeError && throw(v)
        return v::ASTExpr
    end
    local res::ASTExpr
    try
        new_args = Vector{ASTExpr}(undef, length(e.args))
        for (i, a) in enumerate(e.args)
            new_args[i] = _canonicalize_memo(a, memo)
        end
        res = _canonicalize_shallow(reconstruct(e; args = new_args))
    catch err
        if err isa CanonicalizeError
            memo[e] = err
        end
        rethrow()
    end
    memo[e] = res
    return res
end

function _cse_key(
        e::ASTExpr, pgctx::Union{Nothing, _PGatherKeyCtx},
        memos::_CSEKeyMemos
    )
    if e isa OpExpr
        v = get(memos.key, e, _CSE_KEY_UNSET)
        v === _CSE_KEY_UNSET || return v
    end
    keyed = pgctx === nothing ? e : _pgather_key_expr(e, pgctx)
    r = try
        # `canonical_json` is `_emit_json ∘ canonicalize`; split it so the
        # canonical NODE can be inspected before it is flattened to bytes.
        canon = _canonicalize_memo(keyed, memos.canon)
        # Fail-close on a non-value-preserving collapse to a literal.
        (canon isa NumExpr || canon isa IntExpr) ? nothing :
            canon isa OpExpr ? _cse_node_number!(canon, memos) : _cse_leaf_number!(canon, memos)
    catch err
        err isa CanonicalizeError || rethrow()
        nothing
    end
    e isa OpExpr && (memos.key[e] = r)
    return r
end

# Sentinel distinguishing "not memoized yet" from a memoized `nothing` key.
struct _CSEKeyUnset end
const _CSE_KEY_UNSET = _CSEKeyUnset()

# Is argument `i` of `op` evaluated CONDITIONALLY — i.e. only when a sibling
# argument takes a particular value? The registry's `lazy_from` column says
# (`_op_arg_conditional`): `ifelse` walks only the taken branch (args 2 and 3), and
# `and` / `or` stop at the first decisive argument (args 2..n). Every other op
# evaluates all of its arguments, always. `_cse_count!` propagates the flag to all
# descendants, so a node inside a guarded arm is guarded however deep.
@inline _cse_arg_conditional(op::Union{String, Symbol}, i::Int) = _op_arg_conditional(op, i)

# Count pass: tally `canonical_json` occurrences of every hoistable subexpression
# across all RHS trees, splitting each key's tally into (TOTAL, UNCONDITIONAL).
#
# An occurrence is CONDITIONAL iff it sits under a guard — under a lazy `ifelse`
# branch or a short-circuited `and`/`or` argument, at any depth. Two counts, not
# one, because the hoist rule needs both (see the GUARDS note above): >= 2 total
# occurrences makes a key worth hoisting, and >= 1 unconditional occurrence makes
# hoisting it SAFE — the original walk evaluates it at that occurrence regardless,
# so the prelude's unconditional evaluation introduces no throw or NaN the walk
# did not already have.
#
# Occurrences are counted as PATHS through the expression, exactly as the
# original per-path recursion did — but computed by multiplicity propagation
# over the UNIQUE-node DAG (template expansion splices identical subtrees by
# reference, so one node object can hang under exponentially many paths; the
# naive recursion re-walked and re-keyed it once per path). One reverse-
# postorder pass pushes each node's (total, unconditional) path multiplicity
# to its children — a conditional argument edge forwards no unconditional
# multiplicity — and each unique node is then keyed ONCE and contributes its
# multiplicities to its key's tally. On a pure tree this produces the same
# numbers as the recursion, occurrence for occurrence; additions saturate at
# `typemax(Int)` so a deeply-shared DAG cannot overflow the tally (the hoist
# rule only ever asks >= 2 / >= 1).
function _cse_count!(
        e::ASTExpr, counts::Dict{Int, Tuple{Int, Int}},
        pgctx::Union{Nothing, _PGatherKeyCtx},
        memos::_CSEKeyMemos = _CSEKeyMemos()
    )
    (e isa OpExpr && _cse_hoistable(e)) || return
    # The walk descends only through hoistable nodes — a non-hoistable node is
    # a counting barrier, exactly as in the original recursion.
    order, pos = _dag_postorder(e, _cse_args, _cse_counted)
    total, uncond = _dag_path_counts(order, pos, _cse_args, _cse_counted, _cse_op_conditional)
    for (i, n) in enumerate(order)
        k = _cse_key(n, pgctx, memos)
        k === nothing && continue
        t0, u0 = get(counts, k, (0, 0))
        counts[k] = (_sat_add(t0, total[i]), _sat_add(u0, uncond[i]))
    end
    return
end
_cse_args(n::OpExpr) = _operands(n)
_cse_counted(a) = a isa OpExpr && _cse_hoistable(a)
_cse_op_conditional(n::OpExpr, j::Int) = _cse_arg_conditional(n.op, j)

# Mutable CSE compile context: the set of cached keys, the slot assigned to each
# (assigned lazily, in topological order, at first compile), the prelude
# definitions (`defs[s]` computes `cache[s]`), the shared scratch the
# `_NK_CACHED` nodes read from, and the live-forcing stand-in context the keys were
# COUNTED with (`nothing` on a build with no forcing buffers). The count pass and
# the compile pass MUST key with the same `pgctx` or their keys would not match.
mutable struct _CSEContext
    cached::Set{Int}
    slot::Dict{Int, Int}
    defs::Vector{_Node}
    cache::_CSECache
    pgctx::Union{Nothing, _PGatherKeyCtx}
    # The SAME key/canonical memo pair the count pass used (the two passes
    # must key identically), plus a compiled-node identity memo so a subtree
    # shared under many parents is lowered once (`_compile_cse` is a pure
    # function of the node for a fixed build context).
    keymemos::_CSEKeyMemos
    compiled::IdDict{OpExpr, _Node}
    # NAMED scalar-observed slots: observed name → prelude slot.
    # Filled by `_cse_compile_scalar` as it compiles each observed def (in
    # dependency order, before any equation); a `VarExpr` reader whose name is
    # registered here lowers to `_NK_CACHED` on that slot instead of a spliced
    # copy of the body (see `_plan_observed_slots`, build_classify.jl).
    obs_slot::Dict{String, Int}
end

# Rebuild the `_Node` that plain `_compile` would emit for a hoistable `expr`,
# but with each operand lowered through `_compile_cse` so a shared operand
# becomes a `_NK_CACHED` ref. Every hoistable op is a plain `_NK_OP` whose
# operands are all scalar.
function _cse_rebuild(expr::OpExpr, var_map, param_syms, ctx::_CSEContext)
    if _tpl_is_call(expr)
        tg = _call_target(expr)
        return _call_node(
            tg, _Node[_compile_cse(a, var_map, param_syms, ctx) for a in _call_args(tg, expr)],
            _call_arrays(tg, expr)
        )
    end
    children = _Node[
        _compile_cse(a, var_map, param_syms, ctx)
            for a in expr.args
    ]
    op_sym = Symbol(expr.op)
    _check_op_arity(op_sym, length(children))
    return _mknode(kind = _NK_OP, op = op_sym, children = children)
end

# Compile `expr` to a `_Node`, hoisting any subexpression whose canonical key is
# in `ctx.cached` into the prelude and replacing it with a `_NK_CACHED` ref.
# Falls back to plain `_compile` for leaves and opaque ops, so the result is
# identical to `_compile` wherever nothing is hoisted.
function _compile_cse(expr::ASTExpr, var_map, param_syms, ctx::_CSEContext)
    # A named scalar-observed reference reads its prelude slot.
    # Checked FIRST: an observed name is neither a state, a parameter, nor `t`,
    # so plain `_compile` would (rightly) reject it as unbound. Observed names
    # are disjoint from the state/param namespaces by `_partition_variables`,
    # so this shadows nothing.
    if expr isa VarExpr
        s = get(ctx.obs_slot, expr.name, 0)
        s != 0 && return _mknode(kind = _NK_CACHED, idx = s, payload = ctx.cache)
        return _compile(expr, var_map, param_syms)
    end
    (expr isa OpExpr && _cse_hoistable(expr)) ||
        return _compile(expr, var_map, param_syms)

    # Identity memo: the lowering of a node is a pure function of the node for
    # a fixed build context, so a subtree shared under many parents (template
    # expansion splices by reference) is lowered once. The memoized value is a
    # `_NK_CACHED` ref for hoisted nodes and the rebuilt `_Node` otherwise —
    # both stable after the first visit (the first visit performs any slot
    # assignment, so def order is unchanged).
    memoized = get(ctx.compiled, expr, nothing)
    memoized === nothing || return memoized

    key = _cse_key(expr, ctx.pgctx, ctx.keymemos)
    local out::_Node
    if key !== nothing && key in ctx.cached
        s = get(ctx.slot, key, 0)
        if s != 0
            out = _mknode(kind = _NK_CACHED, idx = s, payload = ctx.cache)
        else
            # First occurrence: compile children first (assigning them lower
            # slots, keeping `defs` topologically ordered), reserve this slot,
            # register the def, and return a ref. Every later occurrence hits
            # the `s != 0` path.
            defnode = _cse_rebuild(expr, var_map, param_syms, ctx)
            s = length(ctx.defs) + 1
            ctx.slot[key] = s
            push!(ctx.defs, defnode)
            out = _mknode(kind = _NK_CACHED, idx = s, payload = ctx.cache)
        end
    else
        # Not cached: reconstruct the same `_Node` `_compile` would, but with
        # hoisted children.
        out = _cse_rebuild(expr, var_map, param_syms, ctx)
    end
    ctx.compiled[expr] = out
    return out
end

# Compile a batch of scalar `(state_index, resolved_rhs_expr)` entries with
# cross-equation + intra-expression CSE. Returns the compiled rhs list, the
# prelude (slot-ordered def nodes), the shared cache vector, and a diagnostic
# `(; n_slots, n_occurrences)` that witnesses the evaluate-once property
# (criterion #2: distinct evaluations == distinct canonical subexpressions).
# `has_pgather` is whether the build bound ANY live forcing buffer or discrete
# cache (`!isempty(pgather)`). It is a required keyword, not a defaulted one: a
# forgotten `false` would silently stop every expression over a forcing buffer
# from being shared.
function _cse_compile_scalar(
        entries::Vector{Tuple{Int, ASTExpr}},
        var_map, param_syms; has_pgather::Bool,
        # Named scalar-observed defs, in
        # dependency order, already `_resolve_indices`d.
        # Each compiles ONCE as a prelude def; readers
        # (`VarExpr` of the name, in entries or in later
        # defs) lower to `_NK_CACHED` on its slot.
        obs_defs::Vector{Pair{String, ASTExpr}} = Pair{String, ASTExpr}[]
    )
    pgctx = has_pgather ? _PGatherKeyCtx() : nothing
    # One memo pair for BOTH passes: count and compile must key identically.
    keymemos = _CSEKeyMemos()
    counts = Dict{Int, Tuple{Int, Int}}()
    # Observed def bodies participate in anonymous CSE alongside the equations
    # (a subtree shared between a def and an equation gets one slot); each def
    # root is an unconditional occurrence — the prelude evaluates it every call.
    for (_, e) in obs_defs
        _cse_count!(e, counts, pgctx, keymemos)
    end
    for (_, e) in entries
        _cse_count!(e, counts, pgctx, keymemos)
    end
    cached = Set{Int}()
    n_occ = 0
    for (k, (total, uncond)) in counts
        # Hoist iff it is WORTH it (>= 2 occurrences) and SAFE (>= 1 of them
        # unconditional — the prelude then evaluates nothing the walk would not).
        # A key occurring only under guards stays inline, behind its guard.
        if total >= 2 && uncond >= 1
            push!(cached, k)
            n_occ += total   # every occurrence of a cached key becomes a cache read
        end
    end
    cache = _CSECache()
    ctx = _CSEContext(
        cached, Dict{Int, Int}(), _Node[], cache, pgctx,
        keymemos, IdDict{OpExpr, _Node}(), Dict{String, Int}()
    )
    # ---- Named observed prelude defs, in dependency order ----
    # Compiled BEFORE the equations so every reader's slot exists, and in
    # dependency order so a def's slot reads land strictly below it (the
    # topological-prelude invariant const_tier.jl and xcse.jl rely
    # on). A def whose whole body lowered to an existing CSE slot (its key was
    # counted >= 2) is ALIASED onto that slot rather than duplicated.
    n_obs_own = 0
    for (name, e) in obs_defs
        node = _compile_cse(e, var_map, param_syms, ctx)
        if node.kind === _NK_CACHED && node.payload === cache
            ctx.obs_slot[name] = node.idx
        else
            push!(ctx.defs, node)
            ctx.obs_slot[name] = length(ctx.defs)
            n_obs_own += 1
        end
    end
    rhs_list = Tuple{Int, _Node}[]
    for (idx, e) in entries
        push!(rhs_list, (idx, _compile_cse(e, var_map, param_syms, ctx)))
    end
    # Size the scratch to the number of slots. `cache` is the SAME object the
    # `_NK_CACHED` nodes captured, so this in-place resize is visible to them.
    # (`alt` is sized from `f64` on first use, i.e. after this.)
    resize!(cache.f64, length(ctx.defs))
    # `n_slots` stays the ANONYMOUS-CSE slot count (the observed slots are
    # reported as `n_obs_slots`, aliased-or-own; `n_obs_own` of them occupy
    # their own prelude slot, so the prelude length is `n_slots + n_obs_own`).
    diag = (;
        n_slots = length(ctx.defs) - n_obs_own, n_occurrences = n_occ,
        n_obs_slots = length(obs_defs),
    )
    return rhs_list, ctx.defs, cache, diag
end
