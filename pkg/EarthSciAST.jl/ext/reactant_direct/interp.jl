# ========================================================================
# ext/reactant_direct/interp.jl — closed functions (`:fn`) under direct
# emission.
# ========================================================================
#
# WHAT IS LOWERED. The six `interp.*` forms: linear, bilinear and searchsorted,
# each with a shared table or with per-lane table columns (the kernel-class
# merge's `_Interp*LaneSpec`).
#
# HOW. Through the SAME lane evaluators the vectorized interpreter and the
# traced backend use (`_oop_interp_*_lanes`, src/tree_walk/oop.jl) over this
# emitter's own values, wrapped as traced arrays. Those evaluators are pure
# locate → gather → blend: no branch on the query, no opaque scalar core. Their
# three knot-addressing SEAMS (`_oop_knot_count`, `_oop_knot_pair` /
# `_oop_knot_pair2`, `_oop_bilinear_corners`) are already specialized in this
# extension to constant-time `stablehlo.gather`s of a constant table
# (EarthSciASTReactantExt.jl, "interp knot addressing"), so what lands in the
# module is the gather lowering, not the O(table) select ladder — the same ops
# the traced backend emits for the same node.
#
# WHY REUSE RATHER THAN RE-EMIT. The seams are where the interp lowering's
# correctness lives: the count is exact because its terms are 0/1 integers, the
# gather is exact because it selects rather than blends, and the clamp and NaN
# arms mirror the scalar `_interp_*_core` kernels branch for branch — all of it
# pinned against those cores over dense query sweeps by
# test/tree_walk_oop_test.jl. Re-deriving that in a second dialect would buy
# nothing and could only diverge. The cost is that this ONE subtree is built
# through Reactant's broadcast tracing rather than op by op; it is O(1) in the
# grid and in the table, so the program stays IR-shaped.
#
# WHAT IS REFUSED. Every other closed function: a registry-declared typed scalar
# core (`_FnTypedCoreSpec` — the calendar/datetime family) and an all-scalar
# closed function with no typed-core row. Both reach an opaque Julia callee that
# a compiled program has nowhere to put; the interpreter's own trace path fails
# loudly inside the callee, and here it is a named refusal instead.

function _de_fn(ctx::_DECtx, nd::_E._Node, ev::F)::_DEVal where {F}
    pl = nd.payload
    ch = nd.children
    q(i::Int) = _de_traced(ev(ch[i]))
    if pl isa Tuple{String,_E._InterpLinearSpec} ||
       pl isa Tuple{String,_E._InterpLinearLaneSpec}
        _de_tally!(ctx, :interp_linear)
        return _de_untraced(_E._oop_interp_linear_lanes(pl[2], q(1),
                                                        TracedRNumber{Float64}))
    elseif pl isa Tuple{String,_E._InterpBilinearSpec} ||
           pl isa Tuple{String,_E._InterpBilinearLaneSpec}
        _de_tally!(ctx, :interp_bilinear)
        x = q(1); y = q(2)
        return _de_untraced(_E._oop_interp_bilinear_lanes(pl[2], x, y,
                                                          TracedRNumber{Float64}))
    elseif pl isa Tuple{String,_E._InterpSearchsortedSpec} ||
           pl isa Tuple{String,_E._InterpSearchsortedLaneSpec}
        _de_tally!(ctx, :interp_searchsorted)
        return _de_untraced(_E._oop_interp_searchsorted_lanes(pl[2], q(1),
                                                              TracedRNumber{Float64}))
    elseif pl isa Tuple{String,_E._FnTypedCoreSpec}
        _de_refuse("the closed function `$(pl[1])` (a registry typed scalar core)",
            "its body is an opaque Julia callee — the calendar/datetime family " *
            "decomposes dates on the host — and a StableHLO program has nowhere " *
            "to put one. Lower the call away before the backend (a frozen " *
            "`const_arrays` table, or a forcing buffer) or evaluate this model " *
            "with the interpreter.")
    elseif pl isa Tuple{String,Nothing}
        _de_refuse("the closed function `$(pl[1])`",
            "it has no typed scalar core and no interp specification, so the " *
            "interpreter calls it once per lane through an opaque Julia " *
            "callee; there is no StableHLO form of that.")
    end
    _de_refuse("a `:fn` node with a payload of type $(typeof(pl))",
        "it is neither a typed interp specification tuple nor a " *
        "`(name, nothing)` closed-function pair.")
end
