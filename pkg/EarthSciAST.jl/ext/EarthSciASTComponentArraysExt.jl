"""
    EarthSciASTComponentArraysExt

ONE METHOD: how to get the dense data vector out of a `ComponentVector` used as
the RHS's parameter container `p`. Loaded automatically when ComponentArrays is in
the session.

WHY A `ComponentVector` IS THE PARAMETER-VECTOR SHAPE WE WANT. An optimizer, a
sensitivity driver and an AD backend all want `p` to be an `AbstractVector`: a
dense buffer they can perturb, seed, and accumulate a gradient into. A person
wants `p` to be named. A `ComponentVector` is both, and costs nothing at runtime
for it, because the name → index axis lives in the TYPE — `getdata` hands out the
plain `Vector` with no copy, and the naming is erased before any arithmetic
happens. (`build_evaluator`'s `p` NamedTuple converts straight into one:
`ComponentVector(p)`, in the same order `param_map(p)` reports.)

WHY THE UNWRAP IS A SEAM RATHER THAN A CALL. `_read_param` (tree_walk/compile.jl)
resolves a `_NK_PARAM` node against whatever container `p` is, and it is split in
two on purpose:

    _read_param(p::AbstractVector, sym, idx) = _read_param_data(_param_data(p), idx)
                                               └ Reactant ext ┘  └ this ext ┘

`_param_data` answers "where do the numbers live", `_read_param_data` answers "how
do I read one scalar from there". They are overridden by DIFFERENT extensions and
compose without either knowing about the other: this file makes a traced
`ComponentVector` unwrap to a `TracedRArray`, and the Reactant extension already
knows how to read one scalar out of a `TracedRArray`. Neither package needs the
other loaded, and a `ComponentVector` of `Float64` on the host still lands on the
plain `@inline d[idx]`.

Indexing the `ComponentVector` DIRECTLY is not an option, which is the reason this
file exists at all: `getfield(::ComponentVector, ::Symbol)` throws (a
ComponentArray's fields are `data` and `axes`, not its components — `getproperty`
is the component accessor), and under tracing `q[idx::Int]` is an AMBIGUOUS
`getindex` rather than a scalar-indexing error. Unwrapping first sidesteps both.
"""
module EarthSciASTComponentArraysExt

using ComponentArrays: ComponentArrays, ComponentVector

import EarthSciAST: _param_data

@inline _param_data(p::ComponentVector) = ComponentArrays.getdata(p)

end # module
