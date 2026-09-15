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
# traced backend use (`_interp_*_lanes`, src/tree_walk/interp_lanes.jl) over this
# emitter's own values, wrapped as traced arrays. Those evaluators are pure
# locate → gather → blend: no branch on the query, no opaque scalar core. Their
# three knot-addressing SEAMS (`_knot_count`, `_knot_pair` /
# `_knot_pair2`, `_bilinear_corners`) are already specialized in this
# extension to constant-time `stablehlo.gather`s of a constant table
# (ext/reactant_interp.jl), so what lands in the
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
# THE OTHER LOWERED FAMILY: the nine `datetime.*` functions, through their
# registry rows' ELTYPE-GENERIC KERNELS (`_fn_typed_core_kernel`,
# src/registered_functions.jl). The calendar those kernels are written from is
# branch-free arithmetic by construction — a floored divmod of `t_utc` into
# (days since the epoch, milliseconds of day), then Howard Hinnant's
# `civil_from_days`, then the Fliegel–van Flandern integer Julian day — so
# lowering it is `multiply`/`divide`/`floor`/`subtract`/`compare`/`select` and
# nothing else, and `_de_fn_lanes` broadcasts one kernel over the lane vector to
# emit exactly that. The results stay Float64 tensors carrying integer values,
# which is what the interpreter returns for these fields (`_cal_i32`'s `Int32`
# is widened straight back at every call site) and what the surrounding
# expression consumes — `local_hour = datetime.hour(t) + lon/15` is ordinary
# arithmetic on the result, not an integer-typed one.
#
# WHY THE KERNEL AND NOT A SECOND CALENDAR. Same reason as `interp.*` above, and
# said outright at the calendar's own section header: two implementations of one
# calendar is two calendars — they drift, and the drift surfaces as a
# compiled-vs-interpreted mismatch in a model rather than as a test failure
# here. `test/datetime_arithmetic_test.jl` pins the ONE implementation against
# `Dates` exhaustively over 1600–2400; emitting the ops the same kernel is
# written from inherits that, including the negative-time floored division and
# the millisecond truncation, and leaves nothing to re-derive.
#
# WHAT IS REFUSED. An all-scalar closed function with NO typed-core row: it
# reaches an opaque Julia callee, one call per lane, that a compiled program has
# nowhere to put. The v0.3.0 registry has no such entry — every `datetime.*` row
# declares a kernel and every `interp.*` form carries a typed spec — so this is
# the door a FUTURE closed function arrives at, not one any model reaches today.

# WHY THESE THREE CALLS GO THROUGH `call_with_reactant` BY HAND. The walk is
# marked `Reactant.@skip_rewrite_func` at its entry (`_de_emit!`, device.jl), so
# everything below it — this file included — runs NATIVELY inside
# `Reactant.@compile`: Reactant's interpreter does not rewrite its calls, and
# `@reactant_overlay` methods therefore do not apply. Every other lowering in
# this backend is happy with that, because it builds `stablehlo.*` ops from
# `mlir_data` and reads host data. The lane evaluators are the exception named
# in the file header above: they are the ONE subtree built through Reactant's
# broadcast tracing, and they reach Julia's generic array machinery on traced
# arrays — the reduce-tier knot count's `sum(...; dims = 2)` is the sharp case,
# because without the `Base.mapreduce` overlay Base's own `mapreducedim!` and
# `mapreduce` call each other for ever. So the subtree is handed back to the
# interpreter explicitly, which is exactly what the rewrite used to do for it.
#
# This does NOT reintroduce the nesting the skip removed. The children are
# emitted by the walk BEFORE the call (`q(i)` is evaluated as an argument), and
# the evaluators are O(1) in the grid and in the table, so each interp node
# costs one generator and no two of them are ever stacked.
#
# The FOURTH such call is the calendar's, immediately below, for the same
# reason and with the same cost shape.

# One typed-core kernel over a whole lane vector. The kernel is a scalar
# function of the value type, so the broadcast is where it becomes ops: Reactant
# traces it ONCE against a scalar of the lane's element type and applies the
# result to the whole tensor, so the emitted program is the calendar's ~35
# arithmetic ops regardless of how many lanes the vector carries — never a
# per-lane loop, and never a per-lane call.
_de_fn_lanes(k::F, x::TracedRArray{Float64,1}) where {F} = k.(x)

_de_fn(ctx::_DECtx, nd::_E._Node, ev::F) where {F} =
    _de_fn_pl(ctx, nd.payload, _DEVal[ev(ch) for ch in nd.children])

# The `:fn` lowering, taking the payload and the ALREADY-EMITTED argument
# values, so the scalar walk, the access-kernel walk and the lane-batched walk
# reach it the same way.
function _de_fn_pl(ctx::_DECtx, pl, args::Vector{_DEVal})::_DEVal
    ch = args
    q(i::Int) = _de_traced(args[i])
    if pl isa Tuple{String,_E._InterpLinearSpec} ||
       pl isa Tuple{String,_E._InterpLinearLaneSpec}
        _de_tally!(ctx, :interp_linear)
        return _de_untraced(Reactant.call_with_reactant(
            _E._interp_linear_lanes, pl[2], q(1), TracedRNumber{Float64}))
    elseif pl isa Tuple{String,_E._InterpBilinearSpec} ||
           pl isa Tuple{String,_E._InterpBilinearLaneSpec}
        _de_tally!(ctx, :interp_bilinear)
        x = q(1); y = q(2)
        return _de_untraced(Reactant.call_with_reactant(
            _E._interp_bilinear_lanes, pl[2], x, y, TracedRNumber{Float64}))
    elseif pl isa Tuple{String,_E._InterpSearchsortedSpec} ||
           pl isa Tuple{String,_E._InterpSearchsortedLaneSpec}
        _de_tally!(ctx, :interp_searchsorted)
        return _de_untraced(Reactant.call_with_reactant(
            _E._interp_searchsorted_lanes, pl[2], q(1), TracedRNumber{Float64}))
    elseif pl isa Tuple{String,_E._FnTypedCoreSpec}
        spec = pl[2]
        (spec.arity == 1 && length(ch) == 1) ||
            _de_refuse("the closed function `$(pl[1])` with $(length(ch)) argument(s)",
                "this backend lowers the UNARY typed-core form, which is the whole " *
                "v0.3.0 all-scalar set; a wider row needs its own lowering here.")
        _de_tally!(ctx, :closed_scalar)
        return _de_untraced(Reactant.call_with_reactant(
            _de_fn_lanes, _E._fn_typed_core_kernel(spec.id), q(1)))
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
