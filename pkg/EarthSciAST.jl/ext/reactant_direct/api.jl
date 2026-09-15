# ========================================================================
# ext/reactant_direct/api.jl — the public entry points of the compiled lane.
# ========================================================================

"""
    DirectRHS

Callable wrapper over an out-of-place RHS (`build_evaluator(model; form = :oop)`)
whose body, under `Reactant.@compile`, constructs StableHLO DIRECTLY from the
compiled tree-walk IR rather than tracing the broadcast emitter.

Build one with [`direct_rhs`](@ref); call it as `d(u, p, t)`. A model that binds
live forcing buffers must be compiled through [`direct_rhs_with_buffers`](@ref)
instead, which takes the buffers as a fourth ARGUMENT.

`stats` holds the op tallies of the last emission (kernels, folds, constants,
reads), for reports and for the tests' op census. It is informational: nothing
gates on it.

The second type parameter is a `Bool` saying whether the wrapper was built with
a cell-axis shard. It exists so that the unsharded specialization of the traced
body does not contain the `sharding_constraint` call at all; see `_de_constrain`
below for why that matters.
"""
mutable struct DirectRHS{F,SHARDED} <: DirectCallable{SHARDED}
    # THESE THREE FIELDS AND NO OTHERS. `Reactant.@compile d(u, p, t)` traces
    # the callable itself, so every field here is walked by Reactant and
    # inferred through at the call site. WHERE the program runs — the XLA
    # client, the mesh, the shardings — is therefore held BESIDE the wrapper,
    # in device.jl's `_DE_PLACES`, not in it; a placement field wedges the
    # compile (see the long note in device.jl). Read the placement with
    # `direct_client` / `direct_shard`.
    f::F
    names::Dict{Int,String}
    stats::Dict{Symbol,Int}
end

"""
    DirectRHSBuffers

The explicit-buffers form of [`DirectRHS`](@ref) — `d(u, p, t, buffers)` — the
explicit-buffers form. `buffers` is a container aligned with
`forcing_buffers(f)` (same length, same name-sorted order); pass device arrays
(`ConcreteRArray`s) and refresh them in place with `copyto!` / `sync_forcing!`
at each cadence boundary. Because they arrive through the argument list they are
real program INPUTS, so a refresh is seen by the already-compiled program and
nothing recompiles.

Build one with [`direct_rhs_with_buffers`](@ref). It shares the wrapped RHS and
the `stats` dictionary with the `DirectRHS` it came from.
"""
struct DirectRHSBuffers{F,SHARDED} <: DirectCallable{SHARDED}
    d::DirectRHS{F,SHARDED}
end

"""
    direct_rhs(f; var_map = nothing) -> DirectRHS

Wrap the out-of-place RHS `f` (`build_evaluator(model; form = :oop)[1]`) in the
direct StableHLO emitter, and return a callable `(u, p, t) -> du` to compile:

```julia
fo, u0, p, _, vmap = build_evaluator(doc; form = :oop)
d   = EarthSciASTReactantExt.direct_rhs(fo; var_map = vmap)
ur  = Reactant.ConcreteRArray(u0)
pr  = NamedTuple{keys(p)}(map(Reactant.ConcreteRNumber, values(p)))
tr  = Reactant.ConcreteRNumber(0.0)
xla = Reactant.@compile d(ur, pr, tr)
du  = Array(xla(ur, pr, tr))
```

`var_map` is the evaluator's flat variable map; it NAMES the originating rule in
a refusal, and it is what the cell-axis sharding checks the slab cut against. It
may be omitted (refusals then say "flat slot 17", and the shard's block-alignment
check is skipped because there are no block names to check).

`client` chooses WHERE the program compiles and runs: `nothing` (Reactant's
default backend), `:cpu`, `:gpu`, or an `XLA.AbstractClient`. `sharding` cuts the
flat state's cell axis across several devices of that client: `nothing` (one
device, the default), `:cells` (all addressable devices), or a device count.
Build the device inputs with [`direct_state`](@ref), [`direct_params`](@ref) and
[`direct_time`](@ref) so they land on the chosen client with the chosen shard;
see device.jl for what a slab shard means and when it is refused.

DIRECT EMISSION IS THE COMPILED PATH. A model containing any node kind or kernel
shape the emitter cannot lower raises `EarthSciAST.DirectEmitError` naming the
construct and the rule it came from. There is no fallback to the interpreter and
no fallback to the traced emitter — a compiled lane that silently answered with
a different evaluator would make the `compiled_rhs` conformance tier report
agreement between the interpreter and itself. The traced emitter (`@compile
fo(u, p, t)`) remains available as an ORACLE for tests that ask for it by name.

AGREEMENT WITH THE INTERPRETER is numerical, within the tolerance classes of
tests/conformance/compiled_rhs/README.md, never bit-for-bit: `stablehlo.power`
is not Julia's `^`, `stablehlo.maximum`/`minimum` do not pin Julia's NaN
propagation, and a long `⊕`-fold becomes one `stablehlo.reduce`, which XLA may
reassociate (see ops.jl). Emitted programs are never compared.
"""
function direct_rhs(f::_E._OopRHS; var_map = nothing, client = nothing,
                    sharding = nothing)
    names = Dict{Int,String}()
    if var_map !== nothing
        for (nm, idx) in var_map
            names[Int(idx)] = String(nm)
        end
    end
    cl = direct_client(client)
    n_states = getfield(f.rhs, :n_states)::Int
    shard = _de_rule!("the flat state's cell axis") do
        _de_resolve_shard(sharding, cl, n_states, names)
    end
    return _de_register_place!(
        DirectRHS{typeof(f),shard !== nothing}(f, names, Dict{Symbol,Int}()),
        DirectPlace(cl, shard))
end

"""
    direct_rhs_with_buffers(d) -> DirectRHSBuffers
    direct_rhs_with_buffers(f; var_map = nothing) -> DirectRHSBuffers

The explicit-buffers form:

```julia
fo  = build_evaluator(model; form = :oop, param_arrays = forcing)[1]
db  = EarthSciASTReactantExt.direct_rhs_with_buffers(fo)
dev = map(Reactant.ConcreteRArray, forcing_buffers(fo))
xla = Reactant.@compile db(ur, pr, tr, dev)
# at each cadence boundary, after the host refresh:
sync_forcing!(dev, forcing_buffers(fo))
```

See [`DirectRHSBuffers`](@ref).
"""
# The placement of a wrapper, looked up beside it. `DirectRHSBuffers` shares the
# `DirectRHS` it was built from, so it shares its placement too.
_de_place(d::DirectRHS) = _de_lookup_place(d)
_de_place(b::DirectRHSBuffers) = _de_lookup_place(b.d)

direct_rhs_with_buffers(d::DirectRHS) = DirectRHSBuffers(d)
direct_rhs_with_buffers(f::_E._OopRHS; kwargs...) =
    DirectRHSBuffers(direct_rhs(f; kwargs...))

# ---- the emission itself -----------------------------------------------------

function _de_run(d::DirectRHS, u::TracedRArray{Float64,1}, p, t, bufs,
                 hostkeys::Vector{Vector{Float64}})
    rhs = d.f.rhs
    n_states = getfield(rhs, :n_states)::Int
    n_total = getfield(rhs, :n_total)::Int
    length(u) == n_states ||
        _de_refuse("a state vector of length $(length(u))",
            "this model's flat state has $n_states elements.")
    ctx = _DECtx(n_states, n_total, p, _de_time(t), _DEVal(u.mlir_data, n_states),
                 bufs, hostkeys, d.names)
    out = _de_rule!("the right-hand side") do
        _de_emit!(ctx, rhs)
    end
    d.stats = copy(ctx.stats)
    out.len == n_states ||
        _de_refuse("an assembled `du` of length $(out.len)",
            "the output slot map assembled to the wrong width; expected " *
            "$n_states.")
    du = TracedRArray{Float64,1}((), out.v, (n_states,))
    return _de_constrain(du, d)
end

# Pin `du` to the SAME cell-axis slab as `u`. Shardy would propagate a sharding
# through the body on its own, but the assembled `du` is one `concatenate` of
# many slot runs, and propagation through a concatenate is not guaranteed to
# land back on the state's partition; saying it outright keeps the result
# resident where the caller's next step expects it.
#
# WHY THE SHARDEDNESS IS A TYPE PARAMETER AND NOT AN `if`. This is the tail of
# the TRACED body, so Julia infers it, through GPUCompiler, as part of compiling
# the program. Written as a runtime branch on `direct_shard(d)`, inference has to
# descend into `Reactant.Ops.sharding_constraint` with an abstractly typed
# `AbstractSharding` on EVERY compile, sharded or not. This lane already infers
# close enough to Julia's stack-overflow guard to trip it several times per
# compile (see the note above `compile_rhs` in scripts/compiled_rhs_adapter.jl),
# and an unwind at the wrong point leaves the process stuck inside `typeinf`
# with no error and no progress, so an avoidable descent is not affordable.
# Selecting the tail on the wrapper's `SHARDED` parameter means the unsharded
# specialization does not CONTAIN the call, so nothing infers it. The parameter
# is a `Bool`: it widens the wrapper's type with an inert value, not with the
# mesh's and the sharding's own recursive types.
_de_constrain(du, ::DirectCallable{false}) = du
function _de_constrain(du, d::DirectCallable{true})
    sh = direct_shard(d)::DirectShard
    return Reactant.Ops.sharding_constraint(du, sh.state)
end

function (d::DirectRHS)(u::TracedRArray{Float64,1}, p, t)
    host = _E.forcing_buffers(d.f)
    named = join(String[String(k) for k in keys(host)], ", ")
    isempty(host) ||
        _de_refuse("a live forcing buffer under the three-argument form",
            "this model binds $(length(host)) live forcing buffer(s) " *
            "($named). The three-argument " *
            "form would forward the build's HOST arrays, which a compiled " *
            "program can only bake in as constants — the silent-staleness " *
            "configuration. Compile `direct_rhs_with_buffers(d)` and pass " *
            "`map(ConcreteRArray, forcing_buffers(f))` as a fourth argument.")
    return _de_run(d, u, p, t, (), Vector{Float64}[])
end

function (b::DirectRHSBuffers)(u::TracedRArray{Float64,1}, p, t, buffers)
    d = b.d
    host = _E.forcing_buffers(d.f)
    length(buffers) == length(host) ||
        _de_refuse("a `buffers` argument of length $(length(buffers))",
            "it must be aligned with `forcing_buffers(f)`, which has " *
            "$(length(host)) entry/entries in name-sorted order.")
    hostkeys = Vector{Float64}[v for v in values(host)]
    return _de_run(d, u, p, t, buffers, hostkeys)
end

# PRECISION. Every emitted value is a `tensor<Lxf64>`, so a state in any other
# element type is refused by name rather than silently widened. A
# precision-changing model (a Float32 `element_type`) is out of scope for this
# phase — answering it in a precision the document did not declare is a wrong
# number with nothing in the result to say so — and the `compiled_rhs` manifest
# excludes exactly those fixtures for the same reason.
(d::DirectRHS)(u::TracedRArray{T,1}, p, t) where {T} = _de_wrong_eltype(T)
(b::DirectRHSBuffers)(u::TracedRArray{T,1}, p, t, buffers) where {T} =
    _de_wrong_eltype(T)

_de_wrong_eltype(::Type{T}) where {T} =
    _de_refuse("a state vector with element type $T",
        "direct emission is Float64 throughout — every emitted value is a " *
        "`tensor<Lxf64>` — and it will not widen a narrower state into Float64 " *
        "behind the author's back. Precision-changing models are out of scope " *
        "for this phase; run them with the interpreter.")

# Called outside a trace: say so, rather than failing somewhere in MLIR.
(d::DirectRHS)(u, p, t) = _de_not_traced(u)
(b::DirectRHSBuffers)(u, p, t, buffers) = _de_not_traced(u)

_de_not_traced(u) = _de_refuse("a call on a state vector of type $(typeof(u))",
    "direct emission builds StableHLO and only runs under `Reactant.@compile`. " *
    "Pass a `ConcreteRArray{Float64,1}` (which the trace turns into a " *
    "`TracedRArray`), or call the out-of-place RHS itself for a host " *
    "evaluation.")
