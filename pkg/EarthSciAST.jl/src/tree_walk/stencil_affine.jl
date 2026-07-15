# ========================================================================
# tree_walk/stencil_affine.jl — part of the tree-walk evaluator (ess-affine).
# Included by src/tree_walk.jl AFTER stencil.jl; see that file for the layout.
#
# The POLYHEDRAL affine build: turn a lowered `makearray` rule body into a small
# set of `_AccKernel`s (access_kernel.jl) in O(#structural groups), NOT O(#cells).
# This is the replacement for the per-cell / per-branch symbolic-stencil path
# (stencil.jl), whose cost is O(#cells × body) and made the monotone-PPM build
# take tens of minutes (see esd-ess-build-oom-memoless-substitution).
#
# HOW IT WILL WORK (the box processor, built incrementally):
#   1. Reuse `_build_branch_template` (stencil.jl) to compile ONE sentinel spine
#      per structural signature — a `_Node` tree whose loop-var-dependent gather
#      leaves are `_NK_STATE(idx = -k)` placeholders (lane k ↔ `recipes[k]`).
#   2. Decompose the index space into BOXES on which the region selection, the
#      ghost pattern, and every gather's affine Δ are CONSTANT. Cut points per
#      loop dim come from region + ghost boundaries (an O(N) per-dim line sweep);
#      the product of per-dim intervals is the candidate box set.
#   3. Per box: evaluate the lane recipes at the box's REPRESENTATIVE cell to get
#      each gather's slot / const value / ghost flag, and DERIVE its access
#      descriptor by finite differences (Δ = slot(rep) − oln(rep) for state; per-
#      dim strides from unit-step differences for a const on its own grid). VERIFY
#      the derivation is uniform across the box CORNERS; if not, fall back.
#   4. Lower the sentinel spine to an access spine with `_lower_to_access` (below)
#      and emit one `_AccKernel` with the box's `_CellSet`.
#
# `_lower_to_access` is the analog of `_lower_template` (stencil.jl): same tree
# shape, but each `_NK_STATE(idx=-k)` lane leaf becomes either a literal (ghost /
# invariant-folded lane) or an `_NK_ACCESS` into a per-kernel descriptor table,
# and each invariant fixed-slot leaf (`_NK_STATE idx≥0`, `_NK_PARAM_GATHER`)
# becomes a fixed-read descriptor. Because the spine's OP structure is the exact
# `_compile` output (only leaves are swapped), the arithmetic — operand order,
# associativity, n-ary grouping — is byte-for-byte the per-cell path's, which is
# what makes the emitted kernel bit-identical.
# ========================================================================

# Per-lane lowering decision, computed by the box processor from the recipe
# values at the box's representative cell: a lane is either a constant (a ghost
# gather → 0.0, or a value that is invariant across the box) or an access
# descriptor resolved per cell at runtime.
abstract type _LaneRepl end
struct _LitRepl <: _LaneRepl
    v::Float64
end
struct _AccRepl <: _LaneRepl
    desc::_Access
end

# Lower a compiled sentinel template `tmpl` to an access spine, appending each
# access leaf's descriptor to `acc` (the kernel's descriptor table, `_NK_ACCESS.idx`
# indexes it). `lane_repl[k]` is the lowering decision for lane sentinel k
# (`_NK_STATE(idx = -k)`). Non-lane leaves:
#   * `_NK_STATE(idx ≥ 0)`     invariant fixed state slot  → `_AccStateFixed`
#   * `_NK_PARAM_GATHER`       invariant forcing gather    → `_AccArrFixed`
#   * `_NK_LITERAL/PARAM/TIME`  pass through (the access evaluator handles them)
# Anything not modelled (a contraction node, an interp `:fn`) throws
# `_StencilFallback` so the caller runs the per-cell path — never a wrong kernel.
function _lower_to_access(tmpl::_Node, lane_repl::Vector{<:_LaneRepl},
                          acc::Vector{_Access})::_Node
    k = tmpl.kind
    if k === _NK_STATE
        if tmpl.idx < 0
            rep = lane_repl[-tmpl.idx]
            if rep isa _LitRepl
                return _alit(rep.v)
            else
                push!(acc, (rep::_AccRepl).desc)
                return _acc(length(acc))
            end
        else
            push!(acc, _AccStateFixed(tmpl.idx))
            return _acc(length(acc))
        end
    elseif k === _NK_LITERAL || k === _NK_PARAM || k === _NK_TIME
        return tmpl                    # evaluator reads these kinds directly
    elseif k === _NK_PARAM_GATHER
        push!(acc, _AccArrFixed(tmpl.payload::Vector{Float64}, tmpl.idx))
        return _acc(length(acc))
    elseif k === _NK_CONTRACTION
        throw(_StencilFallback("affine lowering: contraction node in template"))
    elseif k === _NK_OP
        tmpl.op === :fn &&
            throw(_StencilFallback("affine lowering: fn (interp) not yet modelled"))
        ch = _Node[_lower_to_access(c, lane_repl, acc) for c in tmpl.children]
        return _mknode(kind=_NK_OP, op=tmpl.op, children=ch)
    end
    throw(_StencilFallback("affine lowering: unhandled node kind $(Int(k))"))
end
