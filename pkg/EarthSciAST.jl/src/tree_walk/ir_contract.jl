# ========================================================================
# src/tree_walk/ir_contract.jl — what a back end may rely on when it consumes
# the compiled intermediate representation (`_CompiledIR`, oop.jl).
# ========================================================================
#
# The out-of-place build product (`_OopRHS`) carries a `_CompiledIR` under
# stable field names. A back end (the direct StableHLO emitter in
# ext/reactant_direct/) walks it as data. This file declares the parts of that
# contract that are not already a named field: the names of the node and access
# descriptor kinds, the layout of one materialization level, and the two
# subscript-to-position rules of the gather nodes.

# ---- kind names --------------------------------------------------------------
#
# Built from the module's own `_NK_*` / `_AK_*` constants, so a kind added next to
# the others is named here without anyone remembering to.

function _kind_name_table(prefix::String)
    t = Dict{UInt8, String}()
    for n in names(@__MODULE__; all = true)
        s = String(n)
        startswith(s, prefix) || continue
        v = getfield(@__MODULE__, n)
        v isa UInt8 || continue
        haskey(t, v) && error("kind code $(Int(v)) is both $(t[v]) and $s")
        t[v] = s
    end
    return t
end

const _NODE_KIND_NAMES = _kind_name_table("_NK_")
const _ACCESS_KIND_NAMES = _kind_name_table("_AK_")

"""
    _node_kind_name(k::UInt8) -> String

The constant name (`"_NK_AREDUCE"`) of a `_Node` kind, for messages.
"""
_node_kind_name(k::UInt8) = get(_NODE_KIND_NAMES, k, "node kind $(Int(k))")

"""
    _access_kind_name(k::UInt8) -> String

The constant name (`"_AK_STATE_AFFINE"`) of an access descriptor kind.
"""
_access_kind_name(k::UInt8) = get(_ACCESS_KIND_NAMES, k, "access descriptor kind $(Int(k))")

# ---- one materialization level -----------------------------------------------
#
# `_CompiledIR.mat_levels` is a tuple of `_OopFillLevel`s in fill order; a level
# reads only the levels before it. A backend reads a level through the
# accessors below.

_mat_scalars(lvl::_OopFillLevel) = lvl.scalars
_mat_kernels(lvl::_OopFillLevel) = lvl.kernels
_mat_plans(lvl::_OopFillLevel) = lvl.plans
_mat_scans(lvl::_OopFillLevel) = lvl.scans
_mat_contractions(lvl::_OopFillLevel) = lvl.contractions

# ---- the gather rules ----------------------------------------------------------

"""
    _const_gather_offset(cg::_ConstGatherArray, n::Int, sub) -> Int

The 1-based position in `cg.flat` that a `_NK_CONST_GATHER` /
`_NK_LIVE_GATHER` with `n` subscripts (its children) reads, where
`sub(d)::Int` is the subscript on axis `d`. Each
subscript is resolved on its own axis by `_const_gather_sub` (boundary policy,
or a refusal). `_eval_node` and `_index_int` apply the same rule inline on the
evaluation path.
"""
@inline function _const_gather_offset(cg::_ConstGatherArray, n::Int, sub::F) where {F}
    off = 1
    @inbounds for d in 1:n
        off += (_const_gather_sub(cg, d, sub(d)::Int) - 1) * cg.strides[d]
    end
    return off
end

"""
    _state_gather_slot(sg::_StateGather, n::Int, sub) -> Int

The flat state slot a `_NK_STATE_GATHER` with `n` subscripts reads, where
`sub(d)::Int` is the
subscript on axis `d`, or `0` for a ghost cell (a subscript outside
`[sg.lo[d], sg.hi[d]]`), which reads as zero. Subscripts are taken in axis order
and the first ghost axis stops the walk. `_eval_state_gather` applies the same
rule inline on the evaluation path.
"""
@inline function _state_gather_slot(sg::_StateGather, n::Int, sub::F) where {F}
    off = 0
    @inbounds for d in 1:n
        s = sub(d)::Int
        (sg.lo[d] <= s <= sg.hi[d]) || return 0
        off += (s - sg.lo[d]) * sg.strides[d]
    end
    return _sg_slot(sg, off)
end
