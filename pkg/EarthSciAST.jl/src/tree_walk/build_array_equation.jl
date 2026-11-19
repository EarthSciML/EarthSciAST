# tree_walk/build_array_equation.jl — the derivative-equation compile and the array-equation cascade
# (scan, affine, contraction, per-cell).

# ---- Stage: per-derivative compiled-IR list ----
# Each scalar entry is `(state_index, resolved-RHS-expr)`. The RHS is inlined
# with observed variables and index ops are resolved to flat-slot references
# here; compilation to the compact `_Node` form is deferred to the caller's
# single batched `_cse_compile_scalar` pass, so common subexpressions are
# eliminated across equations as well as within one RHS. Array
# (`faq`) derivative equations compile to whole-array access kernels
# instead of N per-cell scalar nodes — see `_compile_faq_equation!`.
# `percell_scalar` carries the per-cell reference's compiled nodes (empty
# whenever the affine stencil tier is on); the caller appends them to
# `rhs_list` so they evaluate through the plain scalar walker — the maximally
# independent differential oracle. Returns a `_CompiledEquations`.
struct _CompiledEquations
    # `(state slot, resolved right-hand side)` of each scalar equation, compiled
    # by the caller.
    scalar_entries::Vector{Tuple{Int, ASTExpr}}
    # The per-cell reference's compiled cells, walked by the scalar walker.
    percell::Vector{Tuple{Int, _Node}}
    kernels::Vector{_AccKernel}
    scan_folds::Vector{_ScanFold}
    contractions::Vector{_ArrayContraction}
end

function _compile_derivative_equations(
        derivative_eqs::Vector{Equation},
        resolved_obs::Dict{String, ASTExpr}, cs::_CompileScope, n_states::Int;
        template_sites::Union{Nothing, IdDict{OpExpr, OpExpr}} = nothing,
        # SCALAR-arm substitution map: `resolved_obs` minus the
        # observeds compiled as named prelude slots, so a slot reference stays a
        # bare `VarExpr` for `_compile_cse` to lower onto its slot. `nothing`
        # (no slots) ⇔ the full map — byte-identical to the pre-slot build. The
        # ARRAY (`faq`) arm always inlines the FULL map.
        scalar_obs_inline::Union{Nothing, Dict{String, ASTExpr}} = nothing,
        # Whether whatever consumes `rhs_list` COMPILES it. True only for the
        # out-of-place form, whose emitters (`:xla`) lower the per-cell
        # contraction loop's nodes into their own program; the in-place `f!`
        # walks `rhs_list` with `_eval_node`, so there the loop tier is an
        # interpreter and is retired (see `_compile_faq_equation!`).
        rhs_list_compiled::Bool = false,
        # The state length of the two-buffer slot space the in-place RHS runs
        # on (`_ObsSplitVec`), or 0; the contraction nests address by it.
        obs_nst::Int = 0,
        # The report label of every array equation here, for equations that
        # stand for something that is not an equation of the document (a
        # materialized observed's fill is labelled by the observed's name);
        # `nothing` labels each by its derivative target (`_faq_debug_label`).
        rule_label::Union{Nothing, String} = nothing
    )
    scalar_inline = scalar_obs_inline === nothing ? resolved_obs : scalar_obs_inline
    scalar_entries = Tuple{Int, ASTExpr}[]
    percell_scalar = Tuple{Int, _Node}[]
    acc_kernels = _AccKernel[]
    scan_folds = _ScanFold[]           # prefix-scan post-passes (scan.jl); usually empty
    # whole-equation loop nests (array_contraction.jl);
    # empty unless a contraction clears the length floor.
    array_contractions = _ArrayContraction[]
    covered = _Covered(n_states)
    # A3: ONE cross-equation store for this build's whole equation loop — the
    # compile-once variant / bound-body caches and the shared obs-inline memo
    # move from per-equation to per-build (sound because every compile input
    # threaded below is the same object for every equation; see the _XEqStore
    # note in stencil.jl). Off, the caches are per equation.
    xeq = _compiler_plan_now().stencil ? _XEqStore() : nothing
    # Cross-equation direct class emission (acc_merge.jl): pool every per-cell
    # equation's cell entries here and run the scalarizer-level class emitter
    # ONCE, above the equation loop, so structurally identical cells arising in
    # DIFFERENT equations share a class kernel directly. `nothing` (the class
    # merge off) keeps one `_acc_from_cell_entries` call per equation.
    pooled_cells = _cross_eq_class_emit_enabled() ? Tuple{Int, _Node}[] : nothing
    var_map = cs.var_map
    faq_scope = _FaqScope(
        resolved_obs, cs, template_sites, xeq, pooled_cells, rhs_list_compiled, obs_nst,
        percell_scalar, acc_kernels, scan_folds, array_contractions, covered
    )

    for eq in derivative_eqs
        if _is_scalar_D_lhs(eq.lhs)
            # D(scalar_var) = expr
            state_name = (eq.lhs::OpExpr).args[1]::VarExpr
            idx = get(var_map, state_name.name, 0)
            idx == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", state_name.name))
            _claim_cell!(covered, idx, state_name.name)
            rhs = isempty(scalar_inline) ? eq.rhs :
                _sub_preserving(eq.rhs, scalar_inline)
            rhs_r = _resolve_in(cs, rhs)
            push!(scalar_entries, (idx, rhs_r))
            _record_rule!(state_name.name, :equation, _scalar_rule_tier(rhs_r))

        elseif _is_indexed_D_lhs(eq.lhs)
            # D(index(var, k...)) = expr  — indexed scalar derivative
            lhs_op = eq.lhs::OpExpr
            inner = lhs_op.args[1]::OpExpr   # the index node
            var_expr = inner.args[1]
            var_expr isa VarExpr ||
                throw(
                TreeWalkError(
                    "E_TREEWALK_UNSUPPORTED_LHS",
                    "index first arg must be a variable name"
                )
            )
            concrete_idxs = [
                _eval_const_int(a, _EMPTY_IDX_ENV)
                    for a in inner.args[2:end]
            ]
            cname = _cell_key(var_expr.name, concrete_idxs)
            idx = get(var_map, cname, 0)
            idx == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", cname))
            _claim_cell!(covered, idx, cname)
            rhs = isempty(scalar_inline) ? eq.rhs :
                _sub_preserving(eq.rhs, scalar_inline)
            rhs_r = _resolve_in(cs, rhs)
            push!(scalar_entries, (idx, rhs_r))
            _record_rule!(cname, :equation, _scalar_rule_tier(rhs_r))

        elseif _is_faq_D_lhs(eq.lhs)
            _compile_faq_equation!(faq_scope, eq; rule_label = rule_label)
        else
            # Every caller hands only the three derivative shapes above; an
            # equation of another shape would otherwise drop out unseen.
            throw(
                TreeWalkError(
                    "E_TREEWALK_UNSUPPORTED_LHS",
                    "a derivative equation's left-hand side must be D(x), " *
                        "D(index(x, …)) or a faq over D(index(x, …))"
                )
            )
        end
    end
    # The pooled scalarizer-level emitter: one grouping over EVERY per-cell
    # equation's cells. Same-signature cells merge into one class kernel no
    # matter which equation minted them; a group's lanes keep entry order
    # (equation order, cell order within an equation), so the build stays
    # deterministic. Empty whenever no equation took the per-cell path.
    pooled_cells === nothing || isempty(pooled_cells) ||
        append!(acc_kernels, _acc_from_cell_entries(pooled_cells))
    # `percell_scalar` holds per-cell trees the in-place `f!` walks on every
    # call. Only `_compile_faq_percell!` fills it, and in the in-place form that
    # takes a license, so a strict plan's list is empty by construction.
    return _CompiledEquations(
        scalar_entries, percell_scalar, acc_kernels, scan_folds, array_contractions
    )
end

# The compiled parts of one level of materialized-observed fills: what
# `_compile_fill_level` produces and a level's sections are made from.
struct _LevelParts
    cadence::Symbol                    # :const, :time or :dynamic
    owner::IdDict{Any, String}         # scan fold => the observed it fills
    scalars::Vector{Tuple{Int, _Node}}
    kernels::Vector{_AccKernel}
    scans::Vector{_ScanFold}
    contractions::Vector{_ArrayContraction}
    recurrences::Vector{Any}
end
_LevelParts(cadence::Symbol) = _LevelParts(
    cadence, IdDict{Any, String}(), Tuple{Int, _Node}[], _AccKernel[], _ScanFold[],
    _ArrayContraction[], Any[]
)

"""
    _compile_fill_level(names, cadence, fill_equations, recurrence, resolved_obs,
                        cs, n_total; label_by_name, kw...) -> _LevelParts

Compile the fills of the materialized observeds `names` (one level: none reads
another) into one level's parts. `recurrence(name)` compiles a causal
self-reference into its ordered sweep, or returns `nothing` for a name that is
not one; every other name's `fill_equations(name)` go through
`_compile_derivative_equations` (`kw` passed on), its scalar entries compiled
here. `label_by_name` labels each fill's report row and refusals by the
observed's name.
"""
function _compile_fill_level(
        names, cadence::Symbol, fill_equations, recurrence,
        resolved_obs::Dict{String, ASTExpr}, cs::_CompileScope,
        n_total::Int; label_by_name::Bool = false, kw...
    )
    lv = _LevelParts(cadence)
    for name in names
        sw = recurrence(name)
        if sw !== nothing
            push!(lv.recurrences, sw)
            continue
        end
        ce = _compile_derivative_equations(
            fill_equations(name), resolved_obs, cs, n_total;
            rule_label = label_by_name ? String(name) : nothing, kw...
        )
        for (slot, ex) in ce.scalar_entries
            push!(lv.scalars, (slot, _compile_in(cs, ex)))
        end
        append!(lv.scalars, ce.percell)
        append!(lv.kernels, ce.kernels)
        append!(lv.scans, ce.scan_folds)
        foreach(S -> (lv.owner[S] = name), ce.scan_folds)
        append!(lv.contractions, ce.contractions)
    end
    return lv
end

"""
    _OopFillLevel

One level of materialized-observed fills in the out-of-place product: the
scalar entries `(extended slot, node)`, the class-merged kernels and one
vectorization plan per kernel, the prefix folds and the whole-array
contractions writing the level's slots. A level reads only the levels before it.
"""
struct _OopFillLevel
    scalars::Vector{Tuple{Int, _Node}}
    kernels::Vector{_AccKernel}
    plans::Vector{_OopAccPlan}
    scans::Vector{_ScanFold}
    contractions::Vector{_ArrayContraction}
end

# ---- Stage: one faq derivative equation → whole-array kernels ----
# `faq(expr=D(index(var, ...)), output_idx=[...], ranges={...}) = rhs_faq(...)`
# Expand by iterating the Cartesian product of output_ranges.
# Per-cell compiled nodes are collected and then merged into whole-array
# kernels rather than pushed individually into `rhs_list`; the
# per-cell build logic (ghost cells, const-array inlining, joins/filters,
# variable-valence bounds) is unchanged. Appends to `acc_kernels` and marks
# `covered` for every cell it owns. The tiers are offered in order at the
# function itself (`_compile_faq_equation!`); the per-cell build
# (`_compile_faq_percell!`) is the last.
# (`acc_kernels` is a `Vector{_AccKernel}`; the annotation is omitted because
# `_AccKernel` is defined in access_kernel.jl, included after this build section.)

# Unroll a CONSTANT-bound contraction (aggregate reduction) into a
# plain ⊕-fold AST so the existing affine box processor can lower it — no runtime
# reduce, no per-cell loop. Output indices stay SYMBOLIC (one fold template shared
# across every output cell); only the contracted indices are expanded, through the
# SAME `_foreach_aggregate_term` core the per-cell path uses, so term order and the
# filter `ifelse`-guard are byte-identical. The fold is seeded with the 0̄ identity
# FIRST — matching `_eval_contraction`'s in-place fold exactly (signed-zero `+`, the
# min/max identities) — so the lowered `+`/`min`/`max`/`*` op is bit-identical.
#
# Caller guarantees every contracted bound is constant (`contract_const[d] !==
# nothing`) and there are no join gates (a join can drop terms per output cell,
# which would break the shared template). A filter is fine: it references the
# contracted (now concrete) and/or output (still symbolic) indices and lowers to a
# runtime `ifelse` guard the box processor verifies affine.
function _unrolled_contraction_body(
        rhs_body::ASTExpr, contract_names::Vector{String},
        contract_const, filt, oplus::String, zerobar::Float64;
        out_names = String[]
    )
    iters = _window_iters(
        Vector{Int}[convert(Vector{Int}, c) for c in contract_const],
        filt, contract_names, out_names
    )
    terms = ASTExpr[]
    _foreach_aggregate_term(
        rhs_body, contract_names, iters, nothing, filt, zerobar,
        nothing
    ) do term
        push!(terms, term)
    end
    isempty(terms) && return NumExpr(zerobar)            # empty ⊕-reduction → 0̄ (§5.1)
    return OpExpr(oplus, ASTExpr[NumExpr(zerobar); terms])
end

# The loop form of a contraction for the affine tier (`_AffineReduce`), or
# `nothing` when it has none: every contracted bound constant and contiguous
# with unit step (the box's dims are unit ranges), no join gate (a join drops
# terms per output cell, so cells would not share one fold), and a ⊕ the fold
# node has an arm for. The same admission `_unrolled_contraction_body` has,
# less the ranges an axis cannot be. A single-term contraction is left to the
# unroll, whose one term is no larger than the loop's body and keeps the kernel
# an ordinary one that the kernel-class merge can batch.
function _affine_reduce_form(
        contract_names::Vector{String}, contract_const,
        agg_gates::Union{Vector{_JoinGate}, Nothing}, oplus::String, zerobar::Float64
    )
    isempty(contract_names) && return nothing
    agg_gates === nothing || return nothing
    _is_numeric_reducer(oplus) || return nothing
    rngs = UnitRange{Int}[]
    for c in contract_const
        (c === nothing || isempty(c)) && return nothing
        _is_unit_run(c) || return nothing
        r = first(c):last(c)
        push!(rngs, r)
    end
    prod(length, rngs) >= 2 || return nothing
    return _AffineReduce(copy(contract_names), rngs, Symbol(oplus), zerobar)
end

# Which of `_affine_reduce_form`'s conditions a join-free contraction fails, in
# words, for a refusal to name the construct it actually refuses.
function _fold_form_refusal(contract_names::Vector{String}, contract_const, oplus::String)
    _is_numeric_reducer(oplus) ||
        return "its ⊕ must be +, *, max or min, and this one is `$(oplus)`"
    for (name, c) in zip(contract_names, contract_const)
        (c === nothing || isempty(c)) && continue
        _is_unit_run(c) ||
            return "it folds unit-step ranges only, and `$(name)` steps " *
            (length(c) >= 2 ? "by $(c[2] - c[1]) " : "") *
            "from $(first(c)) to $(last(c))"
    end
    return "it needs at least two terms over constant ranges"
end

# Recognize a CUMULATIVE (prefix) reduction — an aggregate whose
# filter admits the monotone window `j ⋚ i` against one output index — so the
# equation can be evaluated as a term pass plus an O(N) accumulation instead of
# the O(N²) guarded fold `_unrolled_contraction_body` would emit. See scan.jl
# for the rewrite and the bit-exactness argument.
#
# Returns `(axis, inclusive, j_name, term_iters, reverse)` — `axis` the
# POSITION of the scanned symbol in `idx_names`, `term_iters` the range vector
# the TERM build must run over (`nothing` ⇒ `range_iters` unchanged; see the
# STAGGERED case below), `reverse` whether the window is `j >= i` (a REVERSE
# scan, folding from the top of the axis) — or `nothing` for anything that is
# not exactly this shape. Every
# condition below is load-bearing:
#
#   * one contracted symbol, constant-bound: a second contraction or a ragged
#     bound means the admitted set is not a simple prefix of one axis;
#   * no join gates: a join can drop terms per output cell, so consecutive
#     cells would no longer share a prefix;
#   * the filter is EXACTLY one comparison between the contracted symbol and an
#     output symbol — a conjunction, a shifted bound (`j <= i-1`) or a compare
#     against anything else is not this pattern (and `j <= i-1` is just the
#     strict form, which the caller can already spell as `<`);
#   * the ranges COINCIDE, or the contracted range is the output range minus
#     its last cell (see `_scan_term_iters`);
#   * the body does not mention the scanned OUTPUT symbol. This is the
#     condition that makes the rewrite sound rather than merely faster: if the
#     term at `j` depends on `i` (`u[j] * w[i]`, `u[i-j]`), then consecutive
#     cells sum DIFFERENT terms and share no partial result at all.
function _detect_prefix_scan(
        idx_names::Vector{String}, range_iters,
        contract_names::Vector{String}, contract_const, agg_gates::Union{Vector{_JoinGate}, Nothing}, agg_filter,
        rhs_body::ASTExpr
    )
    agg_gates === nothing || return nothing
    length(contract_names) == 1 || return nothing
    citer = contract_const[1]
    citer === nothing && return nothing
    agg_filter isa OpExpr || return nothing
    f = agg_filter::OpExpr
    length(f.args) == 2 || return nothing
    # `j <= i` and its mirror `i >= j` are the SAME forward scan; `j >= i` and
    # `i <= j` the same REVERSE scan, which folds descending (esm-spec §4.3.1):
    # its running accumulator walks the axis from the top, so it is the forward
    # fold over the cells in reverse order (`_build_scan_fold`).
    local j_side::ASTExpr, i_side::ASTExpr, inclusive::Bool
    j = contract_names[1]
    isj(x) = x isa VarExpr && (x::VarExpr).name == j
    if f.op == "<=" || f.op == "<"
        reverse = isj(f.args[2])
        j_side, i_side = reverse ? (f.args[2], f.args[1]) : (f.args[1], f.args[2])
        inclusive = f.op == "<="
    elseif f.op == ">=" || f.op == ">"
        reverse = isj(f.args[1])
        j_side, i_side = reverse ? (f.args[1], f.args[2]) : (f.args[2], f.args[1])
        inclusive = f.op == ">="
    else
        return nothing
    end
    (j_side isa VarExpr && i_side isa VarExpr) || return nothing
    (j_side::VarExpr).name == j || return nothing
    i_name = (i_side::VarExpr).name
    axis = findfirst(isequal(i_name), idx_names)
    axis === nothing && return nothing
    # A reverse scan takes the same-range shape only.
    term_iters = reverse ? (range_iters[axis] == citer ? nothing : :decline) :
        _scan_term_iters(range_iters, axis, citer, inclusive)
    term_iters === :decline && return nothing
    # `_referenced_var_names` routes through the generated field walk, so a
    # reference buried in a nested aggregate's body/filter/ranges counts.
    i_name in _referenced_var_names(rhs_body) && return nothing
    return (axis::Int, inclusive, j, term_iters, reverse)
end

# Which axis do the TERMS live on? Two shapes are admitted, and they are the
# same recurrence — `out[i] = out[i-1] ⊕ term[i-1]` for the strict window,
# `out[i] = out[i-1] ⊕ term[i]` for the inclusive one — differing only in how
# many output cells that recurrence has to fill:
#
#   SAME-RANGE (`nothing`). Output and terms share the axis, which is the only
#   shape a scan could take before this. The term build runs over the output
#   range verbatim.
#
#   STAGGERED (a modified range vector). The output is the axis's NODES and the
#   terms its CENTRES — one fewer — which is how a cumulative flux is spelled on
#   a staggered grid: `Mz[ke] = -Σ_{k < ke}(…)` over `lev_nodes` contracting
#   `lev` (ReSEACT's diagnosed vertical air-mass flux). Admitted ONLY for the
#   STRICT window, and only when the contracted range is exactly the output
#   range minus its LAST cell, because that is precisely the condition under
#   which `{k ∈ terms : k < i}` equals `{k ∈ terms : k < i-1} ∪ {i-1}` for every
#   output cell — i.e. the same prefix recurrence, run one step further. The
#   INCLUSIVE window is declined: `out[i] = ⊕_{k <= i}` over a longer output
#   axis would need a term at the last node, which does not exist.
#
#   The last output node is then left UNCOVERED by the term build and untouched
#   by the term kernels. That is safe by inspection of `_scan_lanes!`
#   (scan.jl): the strict fold WRITES `du[s] = acc` at every
#   cell and only reads the slot into a `term` it accumulates into an `acc` that
#   the loop then discards — so whatever the slot held on entry (0̄ from `du`
#   zeroing, or a stale observed-buffer value) cannot reach an output. The fold
#   itself is untouched by this change, which is what keeps scan.jl's
#   bit-exactness argument intact.
#
# See through a materialized observed's IDENTITY GATHER to the CONTRACTING
# producer underneath.
#
# `_materialized_fill_equation` synthesizes every array-observed fill as
# `index(<def>, i…)` rather than handing over the bare producer, so the fill
# lowers through the identical, already-exercised path every reader used after
# inlining. That is the right default and it stays. But `_compile_faq_equation!`
# detects a contraction by testing `rhs.op == "faq"` — it sees `index`,
# leaves `contract_names` empty, and NONE of the contraction machinery runs:
# not `_detect_prefix_scan`, not `_unrolled_contraction_body`, not the runtime
# contraction loop. The affine build is then handed `index(<contracting
# aggregate>, i…)` directly, which `_stencilize_indexed` cannot model
# ("index(aggregate) with contracted index"), so the whole equation lands on the
# per-cell tier at O(#cells) IR. On a real transport model a staggered prefix scan
# and its column integrals all declined here rather than at any tier's own guard.
#
# It is safe for any reduction, not only a scan: `_derive_lane_repl`
# (stencil_affine.jl) decides a const lane is loop-invariant structurally, from
# the resolved linear index (an all-zero stride vector over the box), never by
# sampling values, so a const column that agrees at the box corners and differs
# inside is not folded to a literal.
#
# STILL DELIBERATELY NARROW: the bare form is adopted only when it UNLOCKS
# something — i.e. only when the producer actually contracts, or carries a
# filter. Any other non-contracting aggregate lowers identically either way, so
# it keeps the gather form and the default above governs it unchanged. A
# join-gated or ragged producer unwraps too: the whole-array contraction nest
# takes the bare form as a table.
#
# The fold is the same in either form: the bare form is a contraction, which
# every tier folds from the semiring's 0̄ (`_NK_CONTRACTION` in the per-cell
# build, the affine tier's unroll and run-time fold, the nest), and the gather
# form resolves the producer as an expression whose fold is seeded from 0̄ too
# (`_combine_with_reducer`): `0̄ ⊕ t₁ ⊕ t₂ ⊕ …` (esm-spec §4.3.1).
#
# Returns the bare producer when the gather is the identity one and the
# producer contracts or carries a filter, else `rhs` unchanged.
# The operand of `index(operand, i…)` when the subscripts are exactly this
# equation's own loop symbols, in order (the identity gather), else `nothing`.
function _identity_gather_operand(rhs::ASTExpr, idx_names::Vector{String})
    rhs isa OpExpr || return nothing
    g = rhs::OpExpr
    nd = length(idx_names)
    (g.op == "index" && length(g.args) == nd + 1) || return nothing
    for d in 1:nd
        v = g.args[d + 1]
        (v isa VarExpr && (v::VarExpr).name == idx_names[d]) || return nothing
    end
    return g.args[1]
end

function _unwrap_identity_gather(
        rhs::ASTExpr, idx_names::Vector{String},
        ranges_dict
    )
    # The gather must be the IDENTITY one the fill synthesizer emits — this
    # equation's own loop symbols, in order. Anything else is a real reindex.
    prod = _identity_gather_operand(rhs, idx_names)
    (prod isa OpExpr && _is_faq_op((prod::OpExpr).op)) || return rhs
    a = prod::OpExpr
    a.expr_body === nothing && return rhs
    aranges = a.ranges
    aranges === nothing && return rhs
    nd = length(idx_names)
    aout = _output_idx_strings(a)
    length(aout) == nd || return rhs
    # Rename the producer's own output symbols onto this equation's loops. A loop
    # name colliding with one of the producer's CONTRACTED symbols would capture
    # it, so decline rather than rename into a capture.
    contracted = _contracted_index_names(aranges, aout)
    any(n -> n in contracted, idx_names) && return rhs
    ren = Dict{String, ASTExpr}()
    renmap = Dict{String, String}()
    for d in 1:nd
        aout[d] == idx_names[d] && continue
        ren[aout[d]] = VarExpr(idx_names[d])
        renmap[aout[d]] = idx_names[d]
    end
    newranges = Dict{String, Any}()
    for (k, v) in aranges
        # A ragged bound's expression names the output symbols it varies with.
        newranges[get(renmap, k, k)] = (v isa AbstractVector && !isempty(ren)) ?
            Any[x isa ASTExpr ? _sub_preserving(x, ren) : x for x in v] : v
    end
    # A join gate binds range symbols by NAME, so it follows the rename too.
    gates = a.join_gates
    if gates !== nothing && !isempty(renmap)
        gates = [
            _JoinGate(
                get(renmap, g.sym_l, g.sym_l), get(renmap, g.sym_r, g.sym_r),
                g.codes_l, g.codes_r, g.candidates
            ) for g in gates
        ]
    end
    bare = reconstruct(
        a;
        output_idx = Any[n for n in idx_names],
        ranges = newranges,
        join_gates = gates,
        # `a.filter` is `nothing` for a plain (unfiltered) reduction.
        filter = (a.filter === nothing || isempty(ren)) ? a.filter :
            _sub_preserving(a.filter, ren),
        expr_body = isempty(ren) ? a.expr_body : _sub_preserving(a.expr_body, ren)
    )
    # The contracted names as `_compile_faq_equation!` will derive them from
    # `bare`.
    cnames = _contracted_index_names(newranges, idx_names)
    # No contraction ⇒ the gather form already lowers identically. Keep it —
    # unless the producer carries a filter, which the affine tier does not model
    # inside a gather, and the bare form puts on the body as its `ifelse` guard
    # (`_compile_faq_equation!`), the value the gather form's resolve computes.
    isempty(cnames) && bare.filter === nothing && return rhs
    all(n -> haskey(ranges_dict, n), idx_names) || return rhs
    # A forward prefix scan, a constant-bound contraction, a join-gated or a
    # ragged one: each is a tier's in the bare form (the scan tier, the affine
    # tier, the nest's static or table form) and hidden from all of them in the
    # gather form.
    return bare
end

# Returns `nothing` (same-range), a term range vector (staggered), or `:decline`.
function _scan_term_iters(range_iters, axis::Int, citer, inclusive::Bool)
    out = range_iters[axis]
    out == citer && return nothing
    (
        !inclusive && length(citer) == length(out) - 1 &&
            @views(out[1:(end - 1)]) == citer
    ) || return :decline
    term_iters = AbstractVector{Int}[r for r in range_iters]
    term_iters[axis] = citer
    return term_iters
end

# The affine reading of an equation LHS `D(index(var, a...))`: `(var, forms)`
# with one `_lhs_index_affine` form `(pos, coef, c)` per subscript, so the cell
# a binding of the loop indices writes is `coef * loop[pos] + c` per subscript
# with no substitution into the tree. `nothing` when the LHS is not that shape,
# a subscript is not affine, or the variable shares a loop index's name; the
# caller then substitutes cell by cell, which raises the shape's own error.
function _lhs_affine_target(lhs_body, idx_names::Vector{String})
    (lhs_body isa OpExpr && lhs_body.op == "D" && !isempty(lhs_body.args)) || return nothing
    inner = lhs_body.args[1]
    (inner isa OpExpr && inner.op == "index" && !isempty(inner.args)) || return nothing
    ve = inner.args[1]
    (ve isa VarExpr && !(ve.name in idx_names)) || return nothing
    forms = Tuple{Int, Int, Int}[]
    for a in @view inner.args[2:end]
        t = _lhs_index_affine(a, idx_names)
        t === nothing && return nothing
        push!(forms, t)
    end
    return (ve.name, forms)
end

# The cell `forms` (from `_lhs_affine_target`) name at loop-index values
# `loop`, written into `cell`.
@inline function _lhs_affine_cell!(cell::Vector{Int}, forms::Vector{Tuple{Int, Int, Int}}, loop)
    @inbounds for k in eachindex(forms)
        pos, coef, c = forms[k]
        cell[k] = pos == 0 ? c : coef * loop[pos] + c
    end
    return cell
end

# The slot of the cell `forms` name at loop values `loop`: arithmetic on the
# array's block when there is one, the map lookup otherwise; 0 for no state.
@inline function _lhs_cell_slot(
        blk, var_map, vname::String, cell::Vector{Int},
        forms::Vector{Tuple{Int, Int, Int}}, loop
    )
    _lhs_affine_cell!(cell, forms, loop)
    return blk === nothing ? _vm_slot(var_map, vname, cell) : _block_slot(blk, cell)
end

# The scan fold's slots in lane order (see `_build_scan_fold`), for an LHS whose
# subscripts are affine.
function _scan_fold_slots!(
        slots::Vector{Int}, blk, var_map::AbstractDict{String, Int}, vname::String,
        forms::Vector{Tuple{Int, Int, Int}}, axis::Int,
        outer_iters, scan_range
    )
    nd = length(outer_iters)
    cell = Vector{Int}(undef, length(forms))
    loop = Vector{Int}(undef, nd)
    # Behind a barrier, so the lane loop runs at the product's concrete type.
    return _scan_fold_slots_lanes!(
        slots, blk, var_map, vname, forms, axis,
        Iterators.product(outer_iters...), scan_range,
        cell, loop, nd
    )
end
function _scan_fold_slots_lanes!(
        slots::Vector{Int}, blk, var_map::AbstractDict{String, Int}, vname::String,
        forms::Vector{Tuple{Int, Int, Int}}, axis::Int,
        lanes, scan_range, cell::Vector{Int},
        loop::Vector{Int}, nd::Int
    )
    for outer in lanes
        for d in 1:nd
            loop[d] = outer[d]
        end
        for s in scan_range
            loop[axis] = s
            slot = _lhs_cell_slot(blk, var_map, vname, cell, forms, loop)
            slot == 0 && throw(
                TreeWalkError(
                    "E_TREEWALK_UNKNOWN_STATE",
                    _cell_key(vname, cell)
                )
            )
            push!(slots, slot)
        end
    end
    return slots
end

# Resolve the output slots a prefix-scan equation owns, grouped into lanes
# along the scanned axis (see `_ScanFold`). One lane per combination of the
# NON-scanned output indices; within a lane the slots ascend.
#
# Slots come from `var_map` for the cell the LHS names, deliberately: the state
# ordering is a derived fact, not a convention, and this must not re-derive it.
# The cell is read off the LHS's affine subscripts when they are affine, else by
# the per-cell substitution the per-cell build uses (`_compile_faq_percell!`).
function _build_scan_fold(
        axis::Int, inclusive::Bool, idx_names::Vector{String},
        range_iters, lhs_body::OpExpr, var_map::AbstractDict{String, Int},
        oplus::String, zerobar::Float64; reverse::Bool = false
    )
    nd = length(idx_names)
    # A reverse scan's lanes run from the top of the axis down.
    scan_range = reverse ? collect(Int, Iterators.reverse(range_iters[axis])) :
        range_iters[axis]
    len = length(scan_range)
    # Unreachable — `_try_affine_stencil` already refused an empty range before
    # the caller got here — but a `nothing` return would leave the term kernels
    # in place with no fold behind them, which is a WRONG ANSWER rather than a
    # slow one. Fail loudly instead.
    len >= 1 || throw(
        TreeWalkError(
            "E_TREEWALK_SCAN_EMPTY_RANGE",
            "prefix scan over an empty range on index '$(idx_names[axis])'"
        )
    )
    # Pin the scanned axis to a single placeholder so the product enumerates
    # LANES; the scan coordinate is substituted in the inner loop.
    outer_iters = Vector{Vector{Int}}(undef, nd)
    for d in 1:nd
        outer_iters[d] = d == axis ? Int[first(range_iters[d])] :
            convert(Vector{Int}, range_iters[d])
    end
    slots = Int[]
    sizehint!(slots, len * prod(length(it) for it in outer_iters; init = 1))
    target = _lhs_affine_target(lhs_body, idx_names)
    if target !== nothing
        vname, forms = target
        _scan_fold_slots!(
            slots, _vm_block(var_map, vname), var_map, vname, forms,
            axis, outer_iters, scan_range
        )
        return _ScanFold(slots, len, Symbol(oplus), zerobar, inclusive)
    end
    idx_exprs = Dict{String, ASTExpr}()
    for outer in Iterators.product(outer_iters...)
        for s in scan_range
            for d in 1:nd
                idx_exprs[idx_names[d]] = IntExpr(Int64(d == axis ? s : outer[d]))
            end
            push!(slots, first(_lhs_cell_slot_at(lhs_body, idx_exprs, var_map)))
        end
    end
    return _ScanFold(slots, len, Symbol(oplus), zerobar, inclusive)
end

# ---- Cascade coverage tally (build observability) ----
# Which of the array-equation build attempts each equation LANDS on:
#   :affine             — the polyhedral access-kernel build, first try
#   :affine_fused_retry — affine succeeded only after fusing the compile-once
#                         template tier back in
#   :percell_acc        — the per-cell scalarize fallback, merged into
#                         indirect-outs `_AccKernel`s (acc_merge.jl); never in
#                         a strict in-place build, which refuses it
#   :empty_output       — an equation over an empty output range: no cell
#   :scan               — a forward cumulative (prefix) reduction, rewritten
#                         into an affine TERM build plus an O(N) accumulation
#                         (scan.jl). Counted instead of `:affine`,
#                         since the term kernels are what the affine build
#                         actually produced.
#   :percell_disabled   — the affine stencil tier is off, so the equation took
#                         the per-cell reference
#                         (plain compiled scalar nodes on `rhs_list`, evaluated
#                         by `_eval_node` — the differential oracle)
# One increment per array equation, at the cascade's dispatch below. Cheap
# (a Dict bump per EQUATION, not per cell) and always on; each lands in the
# build's `CompilerReport.tally` and in the engagement counts (`_count!`).
#
# One NON-routing key rides the same tally:
#   :affine_subtree_tbl — the subtree-table rescue fired (stencil.jl
#                         `_try_exprtbl_lane`): a build-time-evaluable subtree
#                         the stencil vocabulary could not model became a
#                         `LANE_EXPRTBL` per-box table lane instead of
#                         declining the whole equation. Counted PER RESCUED
#                         SUBTREE LANE PER BRANCH TEMPLATE (grid-independent;
#                         bounded by structural groups), not per equation —
#                         and it increments even when the equation later
#                         declines over some OTHER construct, so it measures
#                         rescue firings, not final routing.
#
# Class-emission observability keys (also non-routing) ride the same tally:
#   :classmerge_round{1,2}_merge
#                         — a class-merge round over the assembled kernels
#                           (oop_merge.jl `_merge_acc_kernel_classes`) merged
#                           one class.
#   :classmerge_recheck   — under `_with_merge_recheck` (tests), a second
#                           application of the rounds merged a class: the
#                           rounds were not idempotent on this build.
# The ROUTING keys — the ones that say where an array equation finally landed,
# exactly one per equation. Bumping one of these closes the rule the cascade
# opened and files it in the build's `CompilerReport`; every other key is a
# counter and only adds to the per-build tally.
const _CASCADE_ROUTING_TIER = Dict{Symbol, Symbol}(
    :affine => :affine,
    :affine_fused_retry => :affine,
    :scan => :scan,
    :array_contraction_codegen => :array_contraction_codegen,
    # An equation over an empty output range: no cell, nothing built or run.
    :empty_output => :empty_output,
    # A per-cell SCALARIZE at build whose cell entries then go to the codegen
    # tier as ordinary access kernels — build cost, not right-hand-side cost.
    # A strict in-place build refuses it instead.
    :percell_acc => :percell_build,
    # The per-cell contraction loop (out-of-place only) is NOT that: its cells
    # stay `_Node` trees on `rhs_list`, one per output cell.
    :percell_loop => :interpreter,
    # …except under the forced per-cell reference, where they stay plain scalar
    # nodes on `rhs_list` and are walked per cell on every call.
    :percell_disabled => :interpreter,
)

# A scalar equation is filed on the scalar walker: interpreted, once per slot, on
# every right-hand-side call. `:scalar_loop` marks one whose resolved body keeps
# a reduction as a runtime loop (`_resolve_scalar_faq`), so each of those calls
# also walks that loop over its whole contracted length — per slot rather than
# per cell, which is why it is reported rather than refused. Under `native` the
# scalar codegen tier (scalar_codegen.jl) then emits the equation and moves its
# row to `:scalar_codegen` / `:scalar_loop_codegen` (`_retier_scalar_rules!`).
_scalar_rule_tier(e) = _has_contract_loop(e) ? :scalar_loop : :scalar
function _has_contract_loop(e)
    e isa OpExpr || return false
    e.op == "__contract_loop" && return true
    for a in _operands(e)
        _has_contract_loop(a) && return true
    end
    return e.expr_body !== nothing && _has_contract_loop(e.expr_body)
end

function _tally_cascade!(k::Symbol)
    _count!(k)
    rec = _build_record()
    if rec !== nothing
        rec.tally[k] = get(rec.tally, k, 0) + 1
        tier = get(_CASCADE_ROUTING_TIER, k, nothing)
        tier === nothing || _land_rule!(tier)
    end
    return nothing
end

# One-line identity of a faq equation, for the compiler report's rule label and
# for a refusal's message: the derivative target and its output axes with their
# extents, e.g. `D(conc)[rcv=1024]`. Showing the LHS expression instead prints
# every field of every node it contains — several hundred characters that
# identify the equation no better than this does, and that bury the line they
# are part of.
function _faq_debug_label(lhs_body, idx_names::Vector{String}, range_iters)
    name = "?"
    if lhs_body isa OpExpr && lhs_body.op == "D" && !isempty(lhs_body.args)
        inner = lhs_body.args[1]
        if inner isa OpExpr && inner.op == "index" && !isempty(inner.args)
            ve = inner.args[1]
            ve isa VarExpr && (name = ve.name)
        end
    end
    axes = join(
        (
            "$(idx_names[d])=$(length(range_iters[d]))"
                for d in eachindex(idx_names)
        ), ","
    )
    return "D($(name))[$(axes)]"
end


# The most contraction terms the diagnostic build ahead of a per-cell-build
# refusal builds (see `_faq_percell_license`).
const _REFUSAL_DIAGNOSTIC_TERMS = 1024

# The tile view of a `faq` equation (`_range_affine_view`, range_hooks.jl) and
# its whole-domain ranges in `idx_names` order, or `nothing`.
function _faq_range_view(
        lhs_body::OpExpr, idx_names::Vector{String}, range_iters, var_map::AbstractDict{String, Int},
        array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}}, xeq
    )
    spec = _range_spec_now()
    spec === nothing && return nothing
    range_iters isa Vector{UnitRange{Int}} || return nothing
    isempty(lhs_body.args) && return nothing
    inner = lhs_body.args[1]
    (
        inner isa OpExpr && (inner::OpExpr).op == "index" &&
            !isempty((inner::OpExpr).args) && (inner::OpExpr).args[1] isa VarExpr
    ) || return nothing
    pos = Int[]
    for a in (inner::OpExpr).args[2:end]
        a isa VarExpr || continue
        p = findfirst(==((a::VarExpr).name), idx_names)
        p === nothing || push!(pos, p)
    end
    sort(pos) == collect(eachindex(idx_names)) || return nothing
    var = ((inner::OpExpr).args[1]::VarExpr).name
    got = _range_affine_view(
        spec, var, UnitRange{Int}[range_iters[p] for p in pos],
        var_map, array_var_info, xeq
    )
    got === nothing && return nothing
    view, sr = got
    whole = Vector{UnitRange{Int}}(undef, length(idx_names))
    for (k, p) in enumerate(pos)
        whole[p] = sr[k]
    end
    return view, whole
end

# An array-producing nested `faq` in elementwise position of an equation body
# over the same output box — `D(q[f]) = faq_f(Σ_le w[e(f, le)]) - q[f]` — is a
# whole array (it rebinds `f`, esm-spec §4.3.1 shadowing) that the body combines
# with its other operands cell by cell, so each cell reads its element at that
# cell, as the Rust binding's whole-array overlay, tape and per-cell oracle do.
# Make that gather explicit, `index(faq_f(…), f) - q[f]`, so every tier below
# resolves it through `_resolve_index_of_faq` instead of meeting a bare
# producer. Only a node whose output indices are the equation's own, in order,
# over the same ranges is gathered; any other is left as written.
function _gather_nested_faqs_at_cell(
        body::ASTExpr, idx_names::Vector{String}, ranges_dict
    )::ASTExpr
    isempty(idx_names) && return body
    same_box(o::OpExpr) = begin
        _is_faq_op(o.op) && _is_array_producer(o) || return false
        _output_idx_strings(o) == idx_names || return false
        r = _ranges_dict(o)
        all(n -> haskey(r, n) && haskey(ranges_dict, n) && r[n] == ranges_dict[n], idx_names)
    end
    return _wrap_bare_array_refs(
        body, Set{String}(), idx_names;
        wrap_node = same_box,
        stop_node = e -> _is_array_producer(e) || e.op in _SELF_INDEXED_OPS
    )
end

# ---- The array-equation cascade ----
#
# An array equation (`faq` over `D(index(var, i…))`) is analysed once into an
# `_FaqEq`, then offered to the tiers in `_FAQ_TIERS` in order. Each tier is a
# type with two functions: `_admits(tier, a, sc, st)` says whether the tier
# looks at the equation at all, and `_offer(tier, a, sc, st)` returns a product
# or declines by throwing a `_Decline` (compiler.jl). The driver,
# `_compile_faq_equation!`, files a decline against the rule under the tier's
# name (`_tier_name`) and offers the equation to the next tier; it lands the
# first product (`_land!`), which also tallies the tier the rule landed on. The
# last tier is the per-cell build, which under a strict compiler is the
# refusal: it prints every decline the rule collected.

# The facts the cascade derives about one array equation, once, before any tier
# looks at it.
struct _FaqEq
    eq::Equation
    lhs_op::OpExpr
    # `D(index(var, i…))`.
    lhs_body::OpExpr
    idx_names::Vector{String}
    ranges_dict::AbstractDict
    range_iters::Union{Vector{UnitRange{Int}}, Vector{Vector{Int}}}
    # The right-hand side with an identity gather of a contracting producer
    # unwrapped (`_unwrap_identity_gather`), and its term: the body of the
    # `faq`, with a pointwise filter folded in as the `ifelse` guard.
    rhs_expr::ASTExpr
    rhs_body::ASTExpr
    # The contracted indices, each one's raw range (`[lo, hi]` or
    # `[lo, step, hi]`) and, for a constant range, its iterator (`nothing` for
    # a bound that varies per output cell).
    contract_names::Vector{String}
    contract_ranges::Vector{Vector{Any}}
    contract_const::Vector{Union{AbstractVector{Int}, Nothing}}
    # Semiring ⊕ and its 0̄ (§5.1), the join gates and the filter of a
    # contraction (§5.3 / §7.2).
    oplus::String
    zerobar::Float64
    gates::Any
    filter::Any
    # The rule's report label, and the tile view a range-restricted build gives
    # the affine tier (`_faq_range_view`), or `nothing`.
    label::String
    rview::Any
end

# Whether every contracted range is constant.
_const_bounds(a::_FaqEq) = all(c -> c !== nothing, a.contract_const)
# The number of terms of a constant-bound contraction.
_contract_len(a::_FaqEq) = prod(length(c) for c in a.contract_const)
_output_cells(a::_FaqEq) = prod(length(r) for r in a.range_iters; init = 1)
# An output range with no cell.
_empty_output(a::_FaqEq) = !isempty(a.range_iters) && any(isempty, a.range_iters)

# What every tier resolves and compiles against, and where its products go.
struct _FaqScope{O, S <: _CompileScope}
    resolved_obs::O
    cs::S
    template_sites::Union{Nothing, IdDict{OpExpr, OpExpr}}
    xeq::Union{Nothing, _XEqStore}
    # `nothing`, or the cross-equation cell-entry pool: per-cell entries are
    # appended here instead of being merged per equation, and
    # `_compile_derivative_equations` runs `_acc_from_cell_entries` once after
    # the whole equation loop.
    pooled_cells::Union{Nothing, Vector{Tuple{Int, _Node}}}
    # The out-of-place form, whose emitters compile `rhs_list` into a program
    # of their own (see `_compile_derivative_equations`).
    oop::Bool
    # The state length of the two-buffer slot space the in-place RHS runs on
    # (`_ObsSplitVec`), or 0; the contraction nests address by it.
    obs_nst::Int
    # The products.
    percell_scalar::Vector{Tuple{Int, _Node}}
    acc_kernels::Vector{_AccKernel}
    scan_folds::Vector{_ScanFold}
    array_contractions::Vector{_ArrayContraction}
    covered::_Covered
end

# What the cascade learns about one equation as it goes.
mutable struct _FaqRun
    # The compile-once forms offered the equation, in order: what a refusal
    # says declined it.
    offered::Vector{Symbol}
    # Why the per-cell contraction loop does not take the equation, or
    # `nothing` when it does (`_loop_decline`); computed once, when first read.
    loop_why::Union{Nothing, _Decline, Missing}
    # The loop is the out-of-place form's, and the cheaper of it and the
    # affine tier: the affine tier is not offered the equation.
    loop_preempts_affine::Bool
end

# The analysed equation. `label` names a piece of a split equation.
function _analyse_faq_equation(eq::Equation, sc::_FaqScope, label::Union{Nothing, String})
    lhs_op = eq.lhs::OpExpr
    idx_names = _output_idx_strings(lhs_op)
    ranges_dict = _ranges_dict(lhs_op)
    lhs_body = lhs_op.expr_body::OpExpr
    # A materialized observed's fill arrives as the GATHER form
    # `index(<def>, i…)` (`_materialized_fill_equation`). Speculatively unwrap it
    # back to the bare producer — adopted only when that producer CONTRACTS,
    # which is the only case the gather form costs anything (it hides the
    # contraction from every tier below). See `_unwrap_identity_gather`.
    rhs_expr = _unwrap_identity_gather(eq.rhs, idx_names, ranges_dict)
    rhs_body = _gather_nested_faqs_at_cell(_extract_faq_body(rhs_expr), idx_names, ranges_dict)
    # Contracted indices are keys in the right-hand side's ranges that are not
    # output indices; the default reduce is "+" (esm-spec). A contracted range's
    # bounds may be constant (expanded once, here) or expression-valued per
    # output cell (variable-valence unstructured reduction), which the per-cell
    # build expands at each cell (`_expand_contract_range`).
    contract_names = String[]
    contract_ranges = Vector{Any}[]
    contract_const = Union{AbstractVector{Int}, Nothing}[]
    oplus = "+"
    zerobar = 0.0
    gates = nothing
    filt = nothing
    if rhs_expr isa OpExpr && _is_faq_op((rhs_expr::OpExpr).op)
        rhs_op = rhs_expr::OpExpr
        oplus, zerobar = _aggregate_oplus_identity(rhs_op.semiring, rhs_op.reduce)
        # An array equation's right-hand side is array-valued: a numeric
        # evaluator refuses ⊕ = `or` there (CONFORMANCE_SPEC §5.6.1).
        _is_numeric_reducer(oplus) || _throw_array_bool_and_or(oplus)
        gates = rhs_op.join_gates
        filt = rhs_op.filter
        rhs_ranges = _ranges_dict(rhs_op)
        contract_names = _contracted_index_names(rhs_ranges, idx_names)
        for n in contract_names
            rspec = collect(rhs_ranges[n])
            push!(contract_ranges, _as_type(Vector{Any}, rspec))
            push!(
                contract_const,
                _is_const_int_range(rspec) ?
                    _dense_range_or_list(_expand_int_range(rspec)) : nothing
            )
        end
        # A POINTWISE aggregate (no contracted index) with a filter: each output
        # cell is one combination, which contributes its term where the
        # predicate holds and 0̄ where it does not (esm-schema `filter`, RFC
        # semiring-faq-unified-ir §5.3). That is the guard the expression-position
        # form builds for it (`_resolve_index_of_faq`: one term, `ifelse(filter,
        # term, 0̄)`, no seed), put on the body here so every tier below — none of
        # which reads the filter without a contracted index — computes it.
        if isempty(contract_names) && filt !== nothing
            rhs_body = OpExpr("ifelse", ASTExpr[filt, rhs_body, NumExpr(zerobar)])
            filt = nothing
        end
    end
    range_iters = _output_range_iters(ranges_dict, idx_names)
    # A tile that shares its code gives the affine tier this equation over its
    # whole-domain ranges (range_hooks.jl).
    rview = _faq_range_view(
        lhs_body, idx_names, range_iters, sc.cs.var_map, sc.cs.array_var_info, sc.xeq
    )
    label = label === nothing ? _faq_debug_label(lhs_body, idx_names, range_iters) : label
    return _FaqEq(
        eq, lhs_op, lhs_body, idx_names, ranges_dict, range_iters, rhs_expr, rhs_body,
        contract_names, contract_ranges, contract_const, oplus, zerobar, gates, filt,
        label, rview
    )
end

# `nothing` when the per-cell contraction loop (`_NK_CONTRACTION_LOOP`, one per
# output cell with the contracted indices kept symbolic) takes the equation, else
# why it does not. Gated as the scalar loop is (constant integer bounds,
# ⊕ ∈ {+,*,max,min}, no join or filter, total length ≥ `_contraction_loop_min()`),
# plus a loopability probe on the first output cell: a body that indexes STATE at
# a contracted index has no static per-k slot, and the probe declines.
function _loop_decline(a::_FaqEq, sc::_FaqScope)
    _contraction_loop_enabled() || return _Decline(:tier_off, "the per-cell contraction loop")
    isempty(a.contract_names) && return _Decline(:no_contracted_index)
    a.gates === nothing || return _Decline(:gated_reduction)
    a.filter === nothing || return _Decline(:filtered_reduction)
    _const_bounds(a) || return _Decline(:ragged_contraction)
    _is_numeric_reducer(a.oplus) ||
        return _Decline(:unsupported_op, "⊕ = $(a.oplus); the loop folds only +, *, max or min")
    isempty(a.range_iters) && return _Decline(:no_output_index)
    _contract_len(a) >= _contraction_loop_min() || return _Decline(:below_floor)
    first_idx = Dict{String, ASTExpr}(
        a.idx_names[d] => IntExpr(Int64(first(a.range_iters[d])))
            for d in 1:length(a.idx_names)
    )
    probe = _sub_preserving(a.rhs_body, first_idx)
    probe = isempty(sc.resolved_obs) ? probe : _sub_preserving(probe, sc.resolved_obs)
    pranges = [_expand_int_range(a.contract_ranges[d]) for d in 1:length(a.contract_names)]
    got = _try_build_contraction_loop(
        probe, a.contract_names, pranges, a.oplus, a.zerobar, _resolve_ctx(sc.cs)
    )
    return got isa _Decline ? got : nothing
end

function _loop_why!(st::_FaqRun, a::_FaqEq, sc::_FaqScope)
    st.loop_why === missing && (st.loop_why = _loop_decline(a, sc))
    return st.loop_why
end

# A LONG contraction — as many terms as the loop floor, the length at which a
# reduction is a loop candidate — never unrolls in the in-place build. The
# unroll writes one term per contracted index into the kernel, so its code and
# its compile grow with the contraction; such a contraction is the affine
# tier's run-time fold or the whole-array nest's, and when neither takes it a
# strict compiler refuses it by name rather than handing it to an unroll (the
# affine tier's, or the per-cell build's, which unrolls it into every output
# cell).
_long_contraction(a::_FaqEq, sc::_FaqScope) =
    !sc.oop && !_stencil_disabled() && !isempty(a.contract_names) && _const_bounds(a) &&
    _contract_len(a) >= _contraction_loop_min()

# The affine tier's LOOP form of the contraction (`_AffineReduce`): it keeps the
# contracted indices as loop dims and folds them at run time, so its build is
# O(#structural groups) whatever the contraction length. Only the in-place form
# has it. Its loops run ascending, so a reverse window, which folds descending,
# is not its (`_reverse_window`).
_affine_fold_form(a::_FaqEq, sc::_FaqScope) =
    (sc.oop || _stencil_disabled() || _reverse_window(a.filter, a.contract_names, a.idx_names)) ?
    nothing : _affine_reduce_form(a.contract_names, a.contract_const, a.gates, a.oplus, a.zerobar)

# ---- Products ----

# Kernels from the affine tier, and the scan fold over them when it is a scan;
# `tally` is the landing key.
struct _AffineProduct
    kernels::Vector{_AccKernel}
    scan_fold::Union{Nothing, _ScanFold}
    tally::Symbol
end

# An equation split into pieces the cascade takes as equations of their own:
# `(label, equation)` each. `keep_kernels` marks the kernels the pieces add as
# ones the class merge keeps apart (`_scatter_keep_now`).
struct _SplitProduct
    pieces::Vector{Tuple{String, Equation}}
    keep_kernels::Bool
end

struct _EmptyProduct end

_land!(sc::_FaqScope, ::_EmptyProduct) = _tally_cascade!(:empty_output)

function _land!(sc::_FaqScope, p::_AffineProduct)
    _tally_cascade!(p.tally)
    append!(sc.acc_kernels, p.kernels)
    p.scan_fold === nothing || push!(sc.scan_folds, p.scan_fold)
    return nothing
end

function _land!(sc::_FaqScope, p::_ArrayContraction)
    _tally_cascade!(:array_contraction_codegen)
    push!(sc.array_contractions, p)
    return nothing
end

function _land!(sc::_FaqScope, p::_SplitProduct)
    declines = _open_declines()
    for (plabel, peq) in p.pieces
        nk0 = length(sc.acc_kernels)
        keep = p.keep_kernels ? _scatter_keep_now() : nothing
        _compile_faq_equation!(sc, peq; rule_label = plabel, rule_declines = declines)
        if keep !== nothing
            for k in (nk0 + 1):length(sc.acc_kernels)
                keep[sc.acc_kernels[k]] = nothing
            end
        end
    end
    return nothing
end

# The label of one piece of a split equation, over the box `lo..hi`.
function _piece_label(a::_FaqEq, what::String, lo, hi)
    where_ = join(("$(a.idx_names[d])=$(lo[d])..$(hi[d])" for d in eachindex(a.idx_names)), ", ")
    return "$(a.label), $what ($where_)"
end

# ---- The tiers ----

abstract type _FaqTier end

# An EMPTY output range (an index set a metaparameter sizes to 0, say) has no
# cell to write: there is nothing for any tier to build or for the right-hand
# side to run, which is also what the per-cell build does with it (a loop over
# no cells). It lands here for every compiler, so a strict one never refuses an
# equation over no cells for what its body would cost. A tile's equation over
# none of its cells still offers the affine tier its whole-domain boxes, which
# run no cell; this tier then takes it once the affine tier has passed.
struct _EmptyOutputTier <: _FaqTier
    after_affine::Bool
end
_tier_name(::_EmptyOutputTier) = :empty_output
_admits(t::_EmptyOutputTier, a, sc, st) =
    _empty_output(a) && (t.after_affine || a.rview === nothing)
_offer(::_EmptyOutputTier, a, sc, st) = _EmptyProduct()

# One-pass equality scatter (scatter.jl). A filter that pins an output index by
# equality (`j == i + 1`) admits each contracted point into one output cell.
# Every form below would test every point at every cell, O(cells × points); the
# scatter folds the points into their cells in one pass, in the naive visit
# order, so it is offered first. When every key is a ±1 shift of its own
# contracted index the equation instead splits into pieces the cascade takes as
# ordinary equations (the shift form).
struct _ScatterTier <: _FaqTier end
_tier_name(::_ScatterTier) = :equality_scatter
_admits(::_ScatterTier, a, sc, st) =
    !sc.oop && !_stencil_disabled() && _array_contraction_enabled() &&
    !_empty_output(a) && !isempty(a.range_iters)
function _offer(::_ScatterTier, a::_FaqEq, sc::_FaqScope, st::_FaqRun)
    spec = _detect_equality_scatter(
        a.idx_names, a.contract_names, a.contract_ranges, a.contract_const,
        a.gates, a.filter, a.oplus
    )
    spec === nothing && return nothing
    pieces = _scatter_shift_pieces(
        spec, a.eq, a.rhs_expr::OpExpr, a.lhs_body, a.idx_names, a.range_iters,
        a.contract_names, a.contract_ranges, a.contract_const, a.rhs_body,
        a.oplus, a.zerobar
    )
    if pieces !== nothing
        _tally_cascade!(:equality_scatter_shift)
        return _SplitProduct(
            Tuple{String, Equation}[
                (
                    _piece_label(a, w == 0 ? "cells no point reaches" : "shifted scatter", plo, phi),
                    peq,
                ) for (w, plo, phi, peq) in pieces
            ], true
        )
    end
    push!(st.offered, :equality_scatter)
    return _try_compile_scatter(a, sc, spec)
end

# The affine polyhedral build (stencil_affine.jl): O(#structural groups),
# producing `_AccKernel`s that resolve gathers at run time; the default
# array-kernel build. With this tier off the equation takes the per-cell
# reference, which is the differential test's oracle.
#
# Three forms, tried in order:
#   * the RUN-TIME FOLD (`_AffineReduce`) of a contraction: the contracted
#     indices stay symbolic, as extra loop dims of the box, and the kernel folds
#     the body over them at run time. The unroll emits one term per contracted
#     index, so its kernel grows with the contraction; the fold's does not, and
#     its fold is the unroll's term order with the same seed and the same filter
#     guard. The out-of-place form keeps the unroll: its whole-array emitters
#     have no lowering of the run-time fold.
#   * a FORWARD CUMULATIVE (prefix) reduction split into a term and a fold
#     (scan.jl): the body with the contracted symbol renamed to the output
#     symbol goes through the box build as an ordinary elementwise body, and a
#     `_ScanFold` accumulates over the result after the kernel section. Both
#     passes are O(N); the unrolled guarded fold is O(N²).
#   * the elementwise body, or a short constant-bound contraction with no join
#     gate UNROLLED into a plain ⊕-fold body (`_unrolled_contraction_body`). A
#     variable-valence bound or a join gate (either can vary the term set per
#     output cell) is not the affine tier's, and neither is a long contraction
#     (`_long_contraction`): a declined unroll costs O(#output cells · ∏|k…|).
# Each form is tried with the compile-once template sites and, when that
# declines, retried fused (the expanded body as it stands).
#
# A contraction loop (out-of-place only) preempts this tier when it is the
# cheaper one (`_FaqRun.loop_preempts_affine`).
struct _AffineTier <: _FaqTier end
_tier_name(::_AffineTier) = :affine
_admits(::_AffineTier, a, sc, st) = !_stencil_disabled() && !st.loop_preempts_affine

# One affine build of `body` over `iters`: through the tile's view when it has
# one (and the equation is not a scan, whose fold walks the tile's cells).
function _affine_once(a::_FaqEq, sc::_FaqScope, body, iters, scan; kw...)
    return _attempt(:affine) do
        if a.rview === nothing || scan !== nothing || iters !== a.range_iters
            _try_affine_stencil(
                body, a.idx_names, iters, a.lhs_body, sc.resolved_obs,
                sc.cs.array_var_info, sc.cs.var_map, sc.cs.const_registry, sc.cs.pgather,
                sc.cs.param_index, sc.covered; xeq = sc.xeq, kw...
            )
        else
            rv = a.rview[1]
            _try_affine_stencil(
                body, a.idx_names, a.rview[2], a.lhs_body, sc.resolved_obs,
                rv.avi, rv.vm, sc.cs.const_registry, sc.cs.pgather,
                sc.cs.param_index, sc.covered; xeq = rv.xeq,
                view = rv, run_iters = a.range_iters, kw...
            )
        end
    end
end

function _offer(::_AffineTier, a::_FaqEq, sc::_FaqScope, st::_FaqRun)
    scan = _detect_prefix_scan(
        a.idx_names, a.range_iters, a.contract_names,
        a.contract_const, a.gates, a.filter, a.rhs_body
    )
    kernels = nothing
    first_try = false
    fold_form = scan !== nothing ? nothing : _affine_fold_form(a, sc)
    if fold_form !== nothing
        push!(st.offered, :affine_fold)
        loop_body = a.filter === nothing ? a.rhs_body :
            OpExpr("ifelse", ASTExpr[a.filter, a.rhs_body, NumExpr(a.zerobar)])
        kernels = _affine_once(
            a, sc, loop_body, a.range_iters, scan;
            template_sites = sc.template_sites, reduce = fold_form
        )
        first_try = kernels !== nothing
        if kernels === nothing && sc.template_sites !== nothing
            kernels = _affine_once(a, sc, loop_body, a.range_iters, scan; reduce = fold_form)
        end
        kernels === nothing || _tally_cascade!(:affine_reduce)
    end
    body = kernels !== nothing ? nothing :
        isempty(a.contract_names) ? a.rhs_body :
        scan !== nothing ?
        _sub_preserving(
            a.rhs_body, Dict{String, ASTExpr}(scan[3] => VarExpr(a.idx_names[scan[1]]))
        ) :
        (a.gates === nothing && _const_bounds(a) && !_long_contraction(a, sc)) ?
        _unrolled_contraction_body(
            a.rhs_body, a.contract_names, a.contract_const,
            a.filter, a.oplus, a.zerobar; out_names = a.idx_names
        ) :
        nothing
    body === nothing || push!(st.offered, scan !== nothing ? :scan : :affine)
    # The TERM build runs over the axis the TERMS live on — the output axis
    # itself for a same-range scan, its centres for a staggered one
    # (`scan[4]`, see `_scan_term_iters`). The FOLD below always walks the
    # full output axis.
    term_iters = (scan === nothing || scan[4] === nothing) ? a.range_iters : scan[4]
    if kernels === nothing && body !== nothing
        kernels = _affine_once(a, sc, body, term_iters, scan; template_sites = sc.template_sites)
        first_try = kernels !== nothing
        if kernels === nothing && sc.template_sites !== nothing
            kernels = _affine_once(a, sc, body, term_iters, scan)
        end
    end
    kernels === nothing && return nothing
    # The term kernels are in hand: resolve the slots they write, in scan
    # order, so the post-pass can fold them. Only now, so a declined affine
    # build costs nothing.
    scan_fold = nothing
    if scan !== nothing
        sf = _build_scan_fold(
            scan[1], scan[2], a.idx_names, a.range_iters,
            a.lhs_body, sc.cs.var_map, a.oplus, a.zerobar; reverse = scan[5]
        )
        scan_fold = _ScanFold(sf.slots, sf.len, sf.oplus, sf.zerobar, sf.inclusive, Any[kernels...])
    end
    tally = scan_fold !== nothing ? :scan : first_try ? :affine : :affine_fused_retry
    return _AffineProduct(kernels, scan_fold, tally)
end

# A whole-array `makearray`, one equation per region: `index(makearray(...), i…)`
# at this equation's own loops. The affine tier takes most of these itself: it
# resolves the makearray per cell, so each cell sees its region's value, and
# cuts its boxes at the region bounds. What it declines comes here, ahead of the
# nest, which resolves the term with the cell index symbolic and so could not
# pick a region at all. It is offered one equation per region instead
# (`_makearray_region_equations`), each through this whole cascade with its
# region's value as its right-hand side, under a label naming this equation and
# with the declines it collected so far.
#
# The out-of-place form keeps the equation whole. Below this point it has the
# per-cell contraction loop and the static nest, which both take only a
# contraction at the top of the right-hand side, and a region's piece has none
# (`_makearray_region_rhs`): every piece would reach the per-cell build, whose
# cells the whole equation's per-cell build already resolves to the same values.
struct _RegionSplitTier <: _FaqTier end
_tier_name(::_RegionSplitTier) = :makearray_regions
_admits(::_RegionSplitTier, a, sc, st) = !sc.oop && !_stencil_disabled()
function _offer(::_RegionSplitTier, a::_FaqEq, sc::_FaqScope, st::_FaqRun)
    parts = _makearray_region_equations(a.eq, a.lhs_op, a.lhs_body, a.idx_names, a.range_iters)
    parts === nothing && return nothing
    return _SplitProduct(
        Tuple{String, Equation}[
            (
                _piece_label(
                    a, w == 0 ? "outside every makearray region" : "makearray region $(w)",
                    plo, phi
                ),
                peq,
            ) for (w, plo, phi, peq) in parts
        ], false
    )
end

# The whole-array contraction nest (array_contraction.jl). Offered once every
# affine form has declined: what is left below it is the per-cell build, one
# resolve + `_compile` per OUTPUT CELL. The nest compiles ONE term with every
# index symbolic, plus the flat slot of each output cell, so its build is O(1)
# in the contracted extent and O(cells) machine words (not AST nodes) in the
# output extent. It takes what the per-cell build takes, in that build's fold
# order, term for term: a constant-bound contraction as static loops; a
# join-gated or ragged one with its admitted tuples as a table (`_ACFold`); a
# filter as the `ifelse(filter, term, 0̄)` guard the per-cell expansion wraps
# each term in; and an equation with no contraction as its bare term.
#
# It comes AFTER the affine tier: an equation affine accepts gets kernels that go
# on to the class merge and the codegen tier, and intercepting it would trade
# those for the nest. With the affine tier off it is not offered: that build is
# the per-cell reference, and a reference that went through the nest would not
# be one.
#
# The out-of-place form takes only the static form, at or above the length
# floor: its emitters compile the per-cell build's cells and have no arm for the
# nest's section, and below the floor that build is what they get.
struct _NestTier <: _FaqTier end
_tier_name(::_NestTier) = :array_contraction
function _admits(::_NestTier, a, sc, st)
    (!_stencil_disabled() && _array_contraction_enabled() && !isempty(a.range_iters)) ||
        return false
    sc.oop || return true
    return !isempty(a.contract_names) && a.gates === nothing && a.filter === nothing &&
        _const_bounds(a) && _is_numeric_reducer(a.oplus) &&
        _contract_len(a) >= _array_contraction_min()
end
function _offer(::_NestTier, a::_FaqEq, sc::_FaqScope, st::_FaqRun)
    sc.oop || push!(st.offered, :array_contraction)
    return _try_compile_array_contraction(a, sc)
end

# What is left: the per-cell build, one resolve and compile per output cell, a
# contraction unrolled into each. In the in-place form it is the interpreter's
# and takes a license, which a strict compiler refuses by name
# (`_faq_percell_license`); `:interpreter` turns the affine tier off and takes
# this build as its reference. The out-of-place form's per-cell cells are what
# its emitters compile (`_OopCells`, compiler.jl), and when the per-cell
# contraction loop takes the equation its cells are loops.
struct _PerCellTier <: _FaqTier end
_tier_name(::_PerCellTier) = :percell
_admits(::_PerCellTier, a, sc, st) = true
function _offer(::_PerCellTier, a::_FaqEq, sc::_FaqScope, st::_FaqRun)
    use_loop = sc.oop && _loop_why!(st, a, sc) === nothing
    cells_token = sc.oop ? _OopCells() : _faq_percell_license(a, sc, st)
    # A non-strict in-place build reaches here too, and a LONG contraction must
    # not unroll in it either: the per-cell build would write every one of its
    # terms into every output cell (and a 10^5-term fold is deep enough to
    # overflow the stack where it is compiled). It takes the per-cell
    # contraction loop when the loop takes it, and is refused by name when not.
    # (`:interpreter` never gets here: its affine tier is off, so the
    # contraction is not long and it unrolls, as the reference does.)
    if !sc.oop && _long_contraction(a, sc)
        why_not = _loop_why!(st, a, sc)
        use_loop = why_not === nothing
        use_loop || _refuse_rule(
            a.label,
            (
                isempty(st.offered) ? "no compile-once form was offered this contraction of " :
                    "every compile-once form offered declined this contraction of "
            ) *
                "$(_contract_len(a)) terms, and the per-cell contraction loop does not " *
                "take it: $(_decline_words(why_not)). What is left is the per-cell " *
                "build, which would unroll all of its terms into each of its " *
                "$(_output_cells(a)) output cells. Build with compiler=:interpreter to run it"
        )
    end
    # Anything the affine build cannot model takes the per-cell fallback, whose
    # cell entries merge into indirect-outs access kernels (acc_merge.jl) — or,
    # with the affine stencil tier off, stay plain per-cell scalar nodes (the
    # differential reference).
    _tally_cascade!(use_loop ? :percell_loop : _stencil_disabled() ? :percell_disabled : :percell_acc)
    _compile_faq_percell!(cells_token, a, sc; contraction_loop = use_loop)
    return nothing
end

# The tiers, in the order they are offered an equation.
const _FAQ_TIERS = (
    _EmptyOutputTier(false), _ScatterTier(), _AffineTier(), _EmptyOutputTier(true),
    _RegionSplitTier(), _NestTier(), _PerCellTier(),
)

"""
    _compile_faq_equation!(sc, eq; rule_label, rule_declines)

Offer the array equation `eq` to the tiers of `_FAQ_TIERS` in order and land
the first product. `rule_label` and `rule_declines` name a piece of an equation
split by makearray region or by scatter shift: the equation it came from, and
the declines that equation collected before the split.
"""
function _compile_faq_equation!(
        sc::_FaqScope, eq::Equation;
        rule_label::Union{Nothing, String} = nothing,
        rule_declines::Vector{_DeclineRow} = _DeclineRow[]
    )
    a = _analyse_faq_equation(eq, sc, rule_label)
    # Open this rule's report entry first: every tier either lands it (through
    # the routing tally) or refuses it, and a refusal raised several frames
    # deeper reads the label from here so it can name what it refused.
    _open_rule!(a.label, :equation)
    foreach(_note_decline!, rule_declines)
    st = _FaqRun(Symbol[], missing, false)
    # The per-cell contraction loop preempts the affine tier only when it is
    # the cheaper of the two. The loop costs one resolve + `_compile` per
    # output cell; the unroll one per structural group over a body of ∏|k…|
    # terms. `#groups ≥ 1`, so `#output cells < ∏|k…|` is the most optimistic
    # form of "the unroll cannot be cheaper", and the loop takes the equation
    # when it holds. Otherwise the affine tier is offered it first and the loop
    # stays behind as the per-cell build's form.
    if sc.oop && !(_empty_output(a) && a.rview === nothing) && _loop_why!(st, a, sc) === nothing
        st.loop_preempts_affine = _output_cells(a) < _contract_len(a)
    end
    for tier in _FAQ_TIERS
        _admits(tier, a, sc, st) || continue
        product = _attempt(() -> _offer(tier, a, sc, st), _tier_name(tier))
        product === nothing && continue
        _land!(sc, product)
        return nothing
    end
    return nothing
end

# The equations of a whole-array `makearray` right-hand side, one per region
# box, each over that box with the value `_resolve_index_of_makearray` picks for
# its cells: an array producer of the makearray's rank as the gather
# `index(<value>, i…)`; one of lower rank as the gather at the region's
# non-singleton axes; any other value as it is, and 0 where no region covers a
# cell. Later regions win, as there: the equation's box is cut at every region
# bound, each piece goes to the last region that covers it, and a region's
# pieces are one equation when they make up a box, one each otherwise. The
# pieces depend on the number of regions only, never on the extents.
#
# Each equation comes as `(region, lo, hi, equation)`: the region whose value it
# takes (0 for none) and the box it covers. `nothing` (the equation stays whole)
# unless the right-hand side is that gather at the equation's own loops, every
# loop a unit-step range, every region bound a constant integer and every
# region value one `_makearray_region_rhs` takes.
const _MA_REGION_MAX_PIECES = 256

# A region bound as an `Int`, or `nothing` for one that is not an integer an
# `Int` holds.
_ma_region_bound(x::Real) = _as_int64(x)
_ma_region_bound(x) = nothing

function _makearray_region_equations(
        eq::Equation, lhs_op::OpExpr, lhs_body::OpExpr,
        idx_names::Vector{String}, range_iters
    )
    rhs = eq.rhs
    # The lifted form of a whole-array equation gathers an `faq` whose body is
    # the makearray gather (`index(faq(index(makearray(…), i), i), _lp0)`, the
    # form a derived document writes): see through it to that gather.
    beta = _beta_identity_gather(rhs, idx_names)
    beta === nothing || (rhs = beta)
    nd = length(idx_names)
    nd >= 1 || return nothing
    ma = _identity_gather_operand(rhs, idx_names)
    (ma isa OpExpr && (ma::OpExpr).op == "makearray") || return nothing
    ma = ma::OpExpr
    (ma.regions === nothing || ma.values === nothing) && return nothing
    regions = ma.regions
    values = _bind_makearray_loops(ma, ma.values, ASTExpr[VarExpr(l) for l in idx_names])
    (isempty(regions) || length(regions) != length(values)) && return nothing
    all(r -> r isa UnitRange{Int} && !isempty(r), range_iters) || return nothing
    elo = Int[first(r) for r in range_iters]
    ehi = Int[last(r) for r in range_iters]
    boxes = Vector{Vector{Tuple{Int, Int}}}()
    for region in regions
        length(region) == nd || return nothing
        box = Tuple{Int, Int}[]
        for d in 1:nd
            length(region[d]) == 2 || return nothing
            lo = _ma_region_bound(region[d][1])
            hi = _ma_region_bound(region[d][2])
            (lo === nothing || hi === nothing) && return nothing
            push!(box, (lo, hi))
        end
        push!(boxes, box)
    end
    # Cut each axis of the equation's box at every region bound inside it.
    cuts = Vector{Vector{Int}}(undef, nd)
    for d in 1:nd
        c = Int[elo[d], ehi[d] + 1]
        for b in boxes
            lo, hi = b[d]
            elo[d] < lo <= ehi[d] && push!(c, lo)
            elo[d] <= hi < ehi[d] && push!(c, hi + 1)
        end
        cuts[d] = sort!(unique!(c))
    end
    npieces = prod(length(c) - 1 for c in cuts)
    npieces <= _MA_REGION_MAX_PIECES || return nothing
    # Each piece's region: the last whose box holds it, 0 for none.
    owner = Dict{Int, Vector{NTuple{2, Vector{Int}}}}()
    for I in CartesianIndices(Tuple(1:(length(c) - 1) for c in cuts))
        plo = Int[cuts[d][I[d]] for d in 1:nd]
        phi = Int[cuts[d][I[d] + 1] - 1 for d in 1:nd]
        w = 0
        for (r, b) in enumerate(boxes)
            all(d -> b[d][1] <= plo[d] && phi[d] <= b[d][2], 1:nd) && (w = r)
        end
        push!(get!(owner, w, NTuple{2, Vector{Int}}[]), (plo, phi))
    end
    loops = idx_names
    out = Tuple{Int, Vector{Int}, Vector{Int}, Equation}[]
    piece_eq(plo, phi, prhs) = Equation(
        OpExpr(
            "faq", ASTExpr[]; output_idx = Any[l for l in loops],
            ranges = Dict{String, Any}(loops[d] => Any[plo[d], phi[d]] for d in 1:nd),
            expr_body = lhs_body
        ),
        prhs; _comment = eq._comment
    )
    for w in sort!(collect(keys(owner)))
        pieces = owner[w]
        prhs = w == 0 ? NumExpr(0.0) : _makearray_region_rhs(values[w], boxes[w], loops)
        prhs === nothing && return nothing
        # One equation when the pieces tile their bounding box.
        blo = Int[minimum(p[1][d] for p in pieces) for d in 1:nd]
        bhi = Int[maximum(p[2][d] for p in pieces) for d in 1:nd]
        ncov = sum(prod(p[2][d] - p[1][d] + 1 for d in 1:nd) for p in pieces)
        if ncov == prod(bhi[d] - blo[d] + 1 for d in 1:nd)
            push!(out, (w, blo, bhi, piece_eq(blo, bhi, prhs)))
        else
            for (plo, phi) in pieces
                push!(out, (w, plo, phi, piece_eq(plo, phi, prhs)))
            end
        end
    end
    return out
end

# `index(faq(B), loops…)` — the identity gather, at this equation's own loop
# symbols in order, of an `faq` that contracts nothing and carries no filter or
# join — is `B` with the producer's output indices renamed onto the loops: at
# every cell the gather reads the producer's element there, which is `B` at that
# cell. A name free in `B` that is also a loop is that same loop, whose value at
# the cell is the subscript it is renamed to, so nothing is captured. `nothing`
# for any other expression.
function _beta_identity_gather(rhs::ASTExpr, idx_names::Vector{String})
    nd = length(idx_names)
    nd >= 1 || return nothing
    a = _identity_gather_operand(rhs, idx_names)
    (a isa OpExpr && _is_faq_op((a::OpExpr).op)) || return nothing
    a = a::OpExpr
    (a.expr_body === nothing || a.filter !== nothing || a.join_gates !== nothing) &&
        return nothing
    aout = _output_idx_strings(a)
    length(aout) == nd || return nothing
    isempty(_contracted_index_names(_ranges_dict(a), aout)) || return nothing
    ren = Dict{String, ASTExpr}()
    for d in 1:nd
        aout[d] == idx_names[d] || (ren[aout[d]] = VarExpr(idx_names[d]))
    end
    return isempty(ren) ? a.expr_body : _sub_preserving(a.expr_body, ren)
end

# A region's value as the right-hand side of the equation over its cells (see
# `_makearray_region_equations`); `nothing` when its rank fits neither the
# makearray nor the region, which the per-cell build then reports.
function _makearray_region_rhs(
        val::ASTExpr, box::Vector{Tuple{Int, Int}},
        loops::Vector{String}
    )
    nd = length(loops)
    if _is_array_producer(val)
        v = val::OpExpr
        rank = _producer_rank(v)
        sel = loops[_region_value_axes(rank, nd, d -> box[d][1] == box[d][2])]
        length(sel) == rank || return nothing
        return OpExpr("index", ASTExpr[v, (VarExpr(l) for l in sel)...])
    end
    return val
end

# The output slots of a whole-array nest whose LHS subscripts are affine, in
# `Iterators.product` order, each claimed in `covered`. A function of the
# ranges as a tuple, so the loop is compiled for their rank rather than
# dispatched per cell. Returns the number of cells.
function _ac_claim_outs!(
        outs::Vector{Int}, covered::_Covered, blk, var_map::AbstractDict{String, Int}, vname::String,
        cell::Vector{Int}, forms, iters::Tuple
    )
    c = 0
    for idx_tuple in Iterators.product(iters...)
        c += 1
        idx = _lhs_cell_slot(blk, var_map, vname, cell, forms, idx_tuple)
        idx == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", _cell_key(vname, cell)))
        covered[idx] && throw(
            TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", _cell_key(vname, cell))
        )
        covered[idx] = true
        outs[c] = idx
    end
    return c
end

# Thrown to stop the refusal diagnostic's enumeration at its term cap; caught
# by the diagnostic itself, never seen outside it.
struct _DiagnosticCap <: EarthSciASTError end

# The license for an array equation whose only form left is the in-place
# per-cell build (`_compile_faq_equation!`), and a strict compiler's refusal of
# it. The refusal's probe builds the first output cell, term by term the way
# the interpreter builds every cell, so that a body no form can build — an
# undeclared name, an out-of-range const gather — raises the document's own
# error rather than this refusal. Unrolling
# costs a tree per term, so the diagnostic is capped at
# `_REFUSAL_DIAGNOSTIC_TERMS` terms: past that only the first and last value of
# each contracted index are built (an undeclared name shows in any term, and an
# affine gather is out of range at an end if anywhere), and a join gate that
# drives its own enumeration stops at the cap. The note appended to the message
# says how much of the cell that was.
function _faq_percell_license(a::_FaqEq, sc::_FaqScope, st::_FaqRun)
    offered = st.offered
    probe(pr) = _faq_diagnostic_cell(pr, a, sc)
    return _percell_license(
        a.label, evaluated -> begin
            tier_words = Dict(
                :affine_fold => "the affine tier's run-time fold",
                :affine => "the affine tier",
                :scan => "the prefix-scan tier",
                :array_contraction => "the whole-array contraction tier",
                :equality_scatter => "the one-pass equality scatter"
            )
            # Why the affine tier had nothing to try, when it had nothing.
            unoffered = if any(in((:affine_fold, :affine, :scan)), offered)
                ""
            elseif a.gates !== nothing
                " (the affine tier takes no join-gated contraction, whose terms vary per output cell)"
            elseif !_const_bounds(a)
                " (the affine tier takes no ragged contraction, whose terms vary per output cell)"
            elseif _long_contraction(a, sc) && _affine_fold_form(a, sc) === nothing
                " (the affine tier does not unroll a contraction this long, and its " *
                    "run-time fold does not take this one: " * _fold_form_refusal(
                    a.contract_names, a.contract_const, a.oplus
                ) * ")"
            else
                ""
            end
            declines = _open_declines()
            why = isempty(declines) ? "" :
                " (" * join((_decline_text(d) for d in declines), "; ") * ")"
            offered_txt = isempty(offered) ?
                "no compile-once form was offered this array equation" :
                "this array equation was declined by " *
                join((tier_words[t] for t in offered), ", ", " and ") * why
            ncells = _output_cells(a)
            unroll = if isempty(a.contract_names)
                ""
            elseif _const_bounds(a)
                ", unrolling its contraction of $(_contract_len(a)) terms into each"
            else
                ", unrolling its contraction into each"
            end
            note = evaluated === :cell ? _ONE_CELL_NOTE :
                evaluated === :part ? _PART_CELL_NOTE : _NO_CELL_NOTE
            offered_txt * unoffered * ". What is left is the per-cell build, which " *
                "resolves and compiles the equation once per output cell ($(ncells) " *
                "cell" * (ncells == 1 ? "" : "s") * ")$(unroll), so the build grows " *
                "with the array. Build with compiler=:interpreter to run it. " * note
        end; probe = probe
    )
end

# Build the first output cell of an array equation the way the per-cell build
# does, for `_faq_percell_license`'s refusal probe, and say how much of it was
# built: `:cell` (every term), `:part` (the capped or ends-only subset) or
# `:none` (no term, e.g. a join gate that rejected every tuple tried).
function _faq_diagnostic_cell(::_PerCellAccess, a::_FaqEq, sc::_FaqScope)
    idx_names = a.idx_names
    contract_names = a.contract_names
    idx_env = Dict{String, Int}(
        idx_names[d] => first(a.range_iters[d])
            for d in eachindex(idx_names)
    )
    idx_exprs = Dict{String, ASTExpr}(k => IntExpr(Int64(v)) for (k, v) in idx_env)
    _lhs_cell_slot_at(a.lhs_body, idx_exprs, sc.cs.var_map)
    memo = _BuildMemo()
    build(term) = begin
        t = isempty(sc.resolved_obs) ? term : _sub_preserving(term, sc.resolved_obs)
        _compile_in(sc.cs, _resolve_in(sc.cs, t, memo), memo)
        nothing
    end
    sub_rhs = _sub_preserving(a.rhs_body, idx_exprs)
    # A scalar aggregate nested in the body unrolls, as it does in the per-cell
    # build (`_BuildState.array_cell_depth`).
    cell_state = _build_state()
    cell_state.array_cell_depth += 1
    try
        if isempty(contract_names)
            build(sub_rhs)
            return :cell
        end
        iters = _contract_iters_at(
            contract_names, a.contract_ranges, idx_env, sc.cs.const_registry, a.contract_const
        )
        whole = (iters isa _ContractNest ? length(iters.tuples) : _dynamic(prod, length, iters)::Int) <=
            _REFUSAL_DIAGNOSTIC_TERMS
        whole || (
            iters = iters isa _ContractNest ?
                _ContractNest(iters.tuples[1:_REFUSAL_DIAGNOSTIC_TERMS]) :
                Vector{Int}[unique!(Int[first(c), last(c)]) for c in iters]
        )
        filt = a.filter === nothing ? nothing : _sub_preserving(a.filter, idx_exprs)
        n = 0
        capped = false
        try
            _foreach_aggregate_term(
                sub_rhs, contract_names, iters, a.gates, filt,
                a.zerobar, idx_env
            ) do term
                build(term)
                n += 1
                n >= _REFUSAL_DIAGNOSTIC_TERMS && throw(_DiagnosticCap())
            end
        catch err
            err isa _DiagnosticCap || rethrow()
            capped = true
        end
        return (whole && !capped) ? :cell : n == 0 ? :none : :part
    finally
        cell_state.array_cell_depth -= 1
    end
end

# ---- A `faq` compiled once for every cell ----
# The term of an array `faq`, resolved and compiled ONCE with every index
# symbolic, and the fold around it: the program the whole-array nest runs at
# every output cell and the recurrence sweep at every cell of its block.
struct _CellProgram{F}
    out_refs::Vector{Base.RefValue{Int}}
    body::_Node
    # `nothing` with no contracted index; else the `_ACFold`: its STATIC form
    # (one step range per contracted index), or its TABLE form (each cell's
    # admitted tuples) for a join gate, a reverse window or a ragged bound.
    fold::F
end

# `cell_iters` are the output ranges the table form enumerates the cells of,
# dimension 1 fastest. The term is `body` guarded by `filt`
# (`ifelse(filt, body, 0̄)`, as the per-cell expansion wraps each term), with
# the build's observeds inlined, then `prepare`d. A `_Decline` when the term
# does not resolve with its indices symbolic, or, with `compile_declines`, when
# its compile raises a document-level refusal (an `EarthSciASTError`). Running
# out of memory, blowing the stack or being interrupted says nothing about
# whether a tier can model the equation (errors.jl), and swallowing one is worse
# for the whole-array nest than elsewhere — it is the tier that exists because
# the per-cell alternative exhausts memory — and a programming error is not a
# decline either, so neither is caught.
function _compile_cell_program(
        body::ASTExpr, idx_names::Vector{String}, cell_iters,
        contract_names::Vector{String}, contract_ranges, contract_const,
        gates, filt, oplus::String, zerobar::Float64, sc;
        prepare = identity, nest_scalar_loops::Bool = false, memo::_MaybeMemo = nothing,
        compile_declines::Bool = false
    )
    term = filt === nothing ? body : OpExpr("ifelse", ASTExpr[filt, body, NumExpr(zerobar)])
    isempty(sc.resolved_obs) || (term = _sub_preserving(term, sc.resolved_obs))
    term = prepare(term)
    got = _resolve_array_contraction_term(
        term, idx_names, contract_names, _resolve_ctx(sc.cs);
        nest_scalar_loops = nest_scalar_loops, memo = memo
    )
    got isa _Decline && return got
    out_refs, contract_refs, resolved = got
    node = try
        _compile_in(sc.cs, resolved, memo)
    catch err
        (compile_declines && err isa EarthSciASTError) || rethrow()
        return _Decline(:symbolic_body_did_not_lower, sprint(showerror, err))
    end
    isempty(contract_names) && return _CellProgram(out_refs, node, nothing)
    # A reverse window folds descending, which the static form's ascending
    # loops do not; its table lists each cell's entries from the top down.
    rev = _reverse_window(filt, contract_names, idx_names)
    fold = if gates !== nothing || rev || any(c -> c === nothing, contract_const)
        _array_contraction_table(
            contract_refs, idx_names, cell_iters, contract_names,
            contract_ranges, contract_const, gates, oplus, zerobar,
            sc.cs.const_registry; reverse = rev
        )
    else
        _ACFold(
            contract_refs, Symbol(oplus), zerobar,
            StepRange{Int, Int}[
                (r = _expand_int_range(c); first(r):step(r):last(r)) for c in contract_ranges
            ]
        )
    end
    return _CellProgram(out_refs, node, fold)
end

# ---- Stage: whole-array contraction loop nest ----
# Compile ONE body for the whole equation — output AND contracted indices kept
# symbolic — plus the flat `du` slot of every output cell, and return the
# `_ArrayContraction` the RHS section runs (array_contraction.jl). Declines
# (`_Decline`) for anything this tier cannot model, having touched nothing: the
# body is resolved and compiled BEFORE the LHS walk, and an emitter decline hands
# the claimed cells back, so a decline never leaves `covered` half-marked.
#
# Unlike `_compile_faq_percell!` this does NOT loop the output indices at
# build time to resolve or compile anything — the cell loop below only reads each
# cell's slot out of `var_map`, which is an integer lookup, not IR.
function _try_compile_array_contraction(a::_FaqEq, sc::_FaqScope)
    # A scalar reduction nested in the term stays a loop (`_ResolveCtx.nest_loops`).
    # A memo of this symbolic body's own: it shares nothing with the concrete
    # per-cell builds (the isolation the per-cell loop tier's compile relies
    # on), but a sub-tree the body reaches from several parents resolves and
    # compiles to one node, which the emitter's sharing then computes once.
    prog = _compile_cell_program(
        a.rhs_body, a.idx_names, a.range_iters, a.contract_names, a.contract_ranges,
        a.contract_const, a.gates, a.filter, a.oplus, a.zerobar, sc;
        nest_scalar_loops = true, memo = _BuildMemo(), compile_declines = true
    )
    prog isa _Decline && throw(prog)
    out_refs, node, fold = prog.out_refs, prog.body, prog.fold
    idx_names = a.idx_names
    outs = _ac_claim_all_outs!(sc.covered, a.lhs_body, idx_names, a.range_iters, sc.cs.var_map)
    los, stps, lens = _output_box(a)
    # Emit the nest (array_contraction.jl). The whole equation is ONE body, so
    # the emission is O(1) in both extents like the nest itself. A `_Decline`
    # back is the emitter's: this tier has no interpreted form, so the equation
    # goes back to the cascade, whose next and last form is the per-cell build
    # (refused by a strict compiler, with this reason).
    gen = _try_codegen_array_contraction(
        out_refs, los, stps, lens, outs, node;
        fold = fold, nst = sc.obs_nst
    )
    if gen isa _Decline
        # Hand the cells back untouched: every one was unclaimed on entry (the
        # claim throws on a second claim), so clearing restores `covered`.
        _uncover!(sc.covered, outs)
        throw(gen)
    end
    # On the two-buffer slot space an observed's nest can take in the state
    # kernel that consumes it (`_ac_take_consumers`), which needs it emitted again.
    sc.obs_nst > 0 || return gen
    return _with_remit(
        gen, outs,
        cons -> _try_codegen_array_contraction(
            out_refs, los, stps, lens, outs, node;
            fold = fold, nst = sc.obs_nst, consumer = cons
        )
    )
end

# The output loop geometry of an array equation: each output range's first
# value, step and length, in `idx_names` order.
function _output_box(a::_FaqEq)
    rngs = [_expand_int_range(a.ranges_dict[n]) for n in a.idx_names]
    return Int[first(r) for r in rngs], Int[step(r) for r in rngs], Int[length(r) for r in rngs]
end

# The output cells' slots, in `Iterators.product` order (dimension 1 fastest)
# — the order the emitted odometer reconstructs the loop counters in — each
# claimed in `covered`.
function _ac_claim_all_outs!(
        covered::_Covered, lhs_body::OpExpr, idx_names::Vector{String},
        range_iters, var_map::AbstractDict{String, Int}
    )
    n_cells = prod(length(r) for r in range_iters)
    outs = Vector{Int}(undef, n_cells)
    c = 0
    target = _lhs_affine_target(lhs_body, idx_names)
    if target !== nothing
        vname, forms = target
        cell = Vector{Int}(undef, length(forms))
        blk = _vm_block(var_map, vname)
        c = _ac_claim_outs!(
            outs, covered, blk, var_map, vname, cell, forms,
            Tuple(range_iters)
        )
    else
        for idx_tuple in Iterators.product(range_iters...)
            c += 1
            idx_exprs = Dict{String, ASTExpr}(
                idx_names[d] => IntExpr(Int64(idx_tuple[d]))
                    for d in eachindex(idx_names)
            )
            outs[c] = _claim_cell!(covered, _lhs_cell_slot_at(lhs_body, idx_exprs, var_map)...)
        end
    end
    return outs
end

# The flat slot and cell key of one output cell of an array equation's
# left-hand side `D(index(var, i…))`, the output indices bound to integer
# literals by `idx_exprs`. The arithmetic reading of the same thing, for a
# left-hand side whose subscripts are affine, is `_lhs_affine_target` /
# `_lhs_cell_slot`.
function _lhs_cell_slot_at(lhs_body::OpExpr, idx_exprs::Dict{String, ASTExpr}, var_map::AbstractDict{String, Int})
    sub_lhs = _sub_preserving(lhs_body, idx_exprs)
    malformed(why) = throw(TreeWalkError("E_TREEWALK_ARRAYOP_MALFORMED_LHS", why))
    sub_lhs isa OpExpr && sub_lhs.op == "D" || malformed("expected D(index(...)) in faq body")
    inner = sub_lhs.args[1]
    inner isa OpExpr && inner.op == "index" || malformed("expected index(var,...) inside D")
    ve = inner.args[1]
    ve isa VarExpr || malformed("index first arg must be a variable name")
    cname = _cell_key(ve.name, [_eval_const_int(x, _EMPTY_IDX_ENV) for x in inner.args[2:end]])
    idx = get(var_map, cname, 0)
    idx == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", cname))
    return idx, cname
end

# Mark output slot `idx` (cell key `cname`) written; a second writer is a
# duplicate derivative.
function _claim_cell!(covered::_Covered, idx::Int, cname::AbstractString)
    covered[idx] && throw(TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", cname))
    covered[idx] = true
    return idx
end

# The admitted contracted tuples of every output cell, as the TABLE form of
# `_ACFold` the nest walks. Enumerated by the SAME `_foreach_aggregate_term` the
# per-cell expansion runs, with the same per-cell iterators (a ragged bound
# expanded at the cell) and the same join admission, so each cell's entries are
# exactly the terms that expansion folds, in its order. One pass over the
# admitted tuples, no resolve or compile per cell.
function _array_contraction_table(
        contract_refs::Vector{Base.RefValue{Int}},
        idx_names::Vector{String}, range_iters, contract_names::Vector{String},
        contract_ranges, contract_const, agg_gates::Union{Vector{_JoinGate}, Nothing}, oplus::String, zerobar::Float64,
        const_registry::AbstractDict; reverse::Bool = false
    )
    nc = length(contract_names)
    contract_const = _contract_lists(contract_const)
    n_cells = prod(length(r) for r in range_iters)
    seg = Vector{Int}(undef, n_cells + 1)
    seg[1] = 1
    cols = [Int[] for _ in 1:nc]
    iters = Vector{Vector{Int}}(undef, nc)
    # A constant contracted range expands to the same list at every cell.
    fixed = Bool[_is_const_int_range(contract_ranges[d]) for d in 1:nc]
    idx_env = Dict{String, Int}()
    cells = length(range_iters) == 1 ? ((i,) for i in range_iters[1]) :
        Iterators.product(range_iters...)
    _ac_table_fill!(
        seg, cols, iters, fixed, idx_env, cells, idx_names, contract_names,
        contract_ranges, contract_const, agg_gates, zerobar, const_registry,
        reverse
    )
    return _ACFold(contract_refs, Symbol(oplus), zerobar, seg, cols)
end

# `_array_contraction_table`'s cell loop, behind a barrier so it runs at the
# concrete type of the cell iterator.
function _ac_table_fill!(
        seg, cols, iters, fixed, idx_env, cells, idx_names::Vector{String},
        contract_names, contract_ranges, contract_const, agg_gates::Union{Vector{_JoinGate}, Nothing},
        zerobar, const_registry, reverse::Bool = false
    )
    nc = length(contract_names)
    # A ragged range whose parent is contracted: each cell lists its nest.
    deps = _contracted_parent_deps(contract_names, contract_ranges)
    c = 0
    for idx_tuple in cells
        c += 1
        for d in eachindex(idx_names)
            idx_env[idx_names[d]] = idx_tuple[d]
        end
        for d in 1:nc
            deps === nothing || break
            cc = contract_const === nothing ? nothing : contract_const[d]
            if cc !== nothing
                iters[d] = cc
            elseif c == 1 || !fixed[d]
                iters[d] = _expand_contract_range(contract_ranges[d], idx_env, const_registry)
            end
        end
        # A reverse window's entries run from the top down (`_reverse_window`).
        run = deps !== nothing ?
            _contract_nest(contract_names, contract_ranges, deps, idx_env, const_registry) :
            reverse ? [collect(Int, Iterators.reverse(iters[1]))] : iters
        _foreach_aggregate_term(
            nothing, contract_names, run, agg_gates, nothing,
            zerobar, idx_env
        ) do ks
            @inbounds for d in 1:nc
                push!(cols[d], Int(ks[d]))
            end
        end
        seg[c + 1] = length(cols[1]) + 1
    end
    return nothing
end

# ---- Stage: faq per-cell fallback ----
# Compile one representative per structural group: all cells of this equation
# share the same resolve/compile context, so a per-equation memo (a plain
# local, passed explicitly) lets every subexpression shared across cells
# resolve and compile exactly once instead of once per cell. A contracted
# (einsum) equation expands its reduction through the shared
# `_foreach_aggregate_term` core and accumulates at runtime via
# `_NK_CONTRACTION`; the per-cell nodes are then merged into whole-array
# kernels — structurally-identical cells collapse to one template; ghost
# boundaries / makearray regions / distinct valences form their own
# (N-independent) groups. The DEFAULT merge target is the unified access-kernel
# IR (`_acc_from_cell_entries`, acc_merge.jl → indirect-outs `_AccKernel`s,
# codegen-compiled or interpreted); with the affine stencil tier off the merge
# is skipped and the compiled per-cell nodes stay plain scalar entries (`percell_scalar`
# → `rhs_list`, evaluated by `_eval_node`) — the maximally independent
# reference the acc≡per-cell differentials compare against.
function _compile_faq_percell!(
        ::Union{_PerCellLicense, _OopCells}, a::_FaqEq, sc::_FaqScope;
        contraction_loop::Bool = false
    )
    idx_names = a.idx_names
    contract_names = a.contract_names
    contract_ranges = a.contract_ranges
    rhs_oplus = a.oplus
    rhs_zerobar = a.zerobar
    agg_gates = a.gates
    agg_filter = a.filter
    resolved_obs = sc.resolved_obs
    cs = sc.cs
    var_map = cs.var_map
    const_registry = cs.const_registry
    covered = sc.covered
    contract_const = _contract_lists(a.contract_const)
    cell_entries = Tuple{Int, _Node}[]
    cell_memo = _BuildMemo()
    # A scalar aggregate NESTED in this array-equation cell body must keep
    # unrolling: its node flows into the stencil / access-kernel merge, which
    # models unrolled scalar terms. Mark the array-cell resolve so
    # `_resolve_scalar_faq` confines the runtime contraction loop to scalar
    # contexts. try/finally: the guard must unwind even
    # if a cell resolve throws.
    cell_state = _build_state()
    cell_state.array_cell_depth += 1
    try
        for idx_tuple in Iterators.product(a.range_iters...)
            idx_env = Dict{String, Int}(
                idx_names[d] => idx_tuple[d]
                    for d in 1:length(idx_names)
            )
            idx_exprs = Dict{String, ASTExpr}(
                k => IntExpr(Int64(v))
                    for (k, v) in idx_env
            )
            # The cell the LHS writes to.
            idx = _claim_cell!(covered, _lhs_cell_slot_at(a.lhs_body, idx_exprs, var_map)...)

            # Substitute output loop vars into the RHS body.
            sub_rhs_outer = _sub_preserving(a.rhs_body, idx_exprs)

            if isempty(contract_names)
                # No contracted indices — standard unrolled-body path.
                sub_rhs = isempty(resolved_obs) ? sub_rhs_outer :
                    _sub_preserving(sub_rhs_outer, resolved_obs)
                rhs_r = _resolve_in(cs, sub_rhs, cell_memo)
                push!(cell_entries, (idx, _compile_in(cs, rhs_r, cell_memo)))
            elseif contraction_loop
                # Runtime contraction loop: compile the inner
                # reduction ONCE into an `_NK_CONTRACTION_LOOP` for THIS output cell —
                # the output indices are already concrete in `sub_rhs_outer`; the
                # contracted indices stay symbolic and iterate at eval time. Constant
                # bounds + no join/filter are guaranteed by the caller's gate; the
                # loopability probe already passed, so a per-cell failure is a build
                # invariant break (raised loudly, never silently miscompiled).
                body2 = isempty(resolved_obs) ? sub_rhs_outer :
                    _sub_preserving(sub_rhs_outer, resolved_obs)
                pranges = [
                    _expand_int_range(contract_ranges[d])
                        for d in 1:length(contract_names)
                ]
                marker = _try_build_contraction_loop(
                    body2, contract_names, pranges, rhs_oplus, rhs_zerobar,
                    _ResolveCtx(cs.array_var_info, var_map, const_registry, cs.pgather)
                )
                marker isa _Decline &&
                    throw(
                    TreeWalkError(
                        "E_TREEWALK_CONTRACTION_LOOP_INTERNAL",
                        "einsum contraction-loop build failed for a cell after the " *
                            "loopability probe passed (build invariant break)"
                    )
                )
                push!(
                    cell_entries, (
                        idx, _compile_in(cs, marker, cell_memo),
                    )
                )
            else
                # Generalized einsum: compile each contracted-index term
                # separately, then accumulate at runtime using _NK_CONTRACTION
                # (`_eval_contraction`: an allocation-free sequential ⊕-fold for
                # every semiring).
                # Constant-bound contracted ranges reuse the global iterator;
                # expression-valued ones are expanded for THIS output cell from
                # the current `idx_env` (variable-valence segment reduction —
                # the per-cell bound is the cell's true valence, so absent
                # neighbour slots are never iterated; no host-side padding).
                # A ragged range whose parent is contracted lists the cell's
                # nest instead (`_contract_iters_at`).
                cell_contract_iters = _contract_iters_at(
                    contract_names, contract_ranges, idx_env,
                    const_registry, contract_const
                )
                # Joins and filters (§5.3 / §7.2) via the shared `_foreach_aggregate_term` core:
                # a join-rejected combination is dropped (so a degenerate join
                # keeps every term and is byte-identical); a filter-rejected one
                # contributes 0̄ at runtime via an `ifelse` guard. The filter
                # carries this cell's (fixed) output-index substitution already,
                # matching the hoisted `sub_rhs_outer`; the join binding seeds
                # from this cell's `idx_env`.
                filt_cell = agg_filter === nothing ? nothing :
                    _sub_preserving(agg_filter, idx_exprs)
                cell_contract_iters = _window_iters(
                    cell_contract_iters, agg_filter,
                    contract_names, idx_names
                )
                k_nodes = _Node[]
                _foreach_aggregate_term(
                    sub_rhs_outer, contract_names,
                    cell_contract_iters, agg_gates, filt_cell,
                    rhs_zerobar, idx_env
                ) do term
                    term = isempty(resolved_obs) ? term :
                        _sub_preserving(term, resolved_obs)
                    rhs_r = _resolve_in(cs, term, cell_memo)
                    push!(k_nodes, _compile_in(cs, rhs_r, cell_memo))
                end
                if isempty(k_nodes)
                    # A per-cell dynamic bound can be empty (e.g. an isolated
                    # cell with zero neighbours). Emit the semiring's 0̄
                    # empty-⊕-reduction identity (§5.1): 0 for sum_product,
                    # +∞ for min_sum, -∞ for max_*, 1 for the legacy ×-reduce.
                    push!(cell_entries, (idx, _mknode(kind = _NK_LITERAL, literal = rhs_zerobar)))
                else
                    # Carry 0̄ on the contraction node so the runtime fold is
                    # seeded from the registry table, never a hardcoded value.
                    push!(
                        cell_entries, (
                            idx, _mknode(
                                kind = _NK_CONTRACTION,
                                op = Symbol(rhs_oplus),
                                literal = rhs_zerobar,
                                children = k_nodes
                            ),
                        )
                    )
                end
            end
        end
    finally
        cell_state.array_cell_depth -= 1
    end
    if contraction_loop || _stencil_disabled() ||
            _anyof(e -> _acc_scalar_only(e[2]), cell_entries)
        # Loop cells, and cells holding another kind an access kernel has no
        # form for (a state read at a slot computed per call), evaluate through
        # the plain scalar walker (`_eval_node`), bypassing the affine /
        # acc-merge / access-kernel / oop-merge / codegen passes entirely — this
        # IS the stencil-disabled reference path, so the result is the
        # reference result.
        append!(sc.percell_scalar, cell_entries)
    elseif sc.pooled_cells !== nothing
        # Cross-equation direct class emission: defer to the ONE
        # `_acc_from_cell_entries` call sited above the equation loop
        # (`_compile_derivative_equations`), so cells of identical shape in
        # DIFFERENT equations share a class kernel directly.
        append!(sc.pooled_cells, cell_entries)
    else
        append!(sc.acc_kernels, _acc_from_cell_entries(cell_entries))
    end
    return nothing
end
