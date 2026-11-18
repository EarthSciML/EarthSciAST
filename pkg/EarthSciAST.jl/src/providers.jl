# What a run needs to know about a data provider, read once (`_provider_traits`),
# and the gated providers' selective fetch after value invention.
#
# A provider is written against the protocol functions of data_refresh.jl
# (`provider_refresh_times`, `provider_sample` and the optional selection, gate
# and extent functions). `esm_problem` asks those functions once per provider,
# when it describes the provider, so a provider missing a required method is
# reported then, before a build that can take hours; every later decision reads
# the description.

# One native axis of a gate (the per-axis `select` vocabulary of esm-spec
# §8.9.2, which the pushdown rewrite also generates; see `provider_gate_spec`).
struct _AllAxis end                       # "all": the whole axis
struct _FixedAxis                         # {"fixed": [i]}: 0-based `i`, axis dropped
    index::Int
end
struct _RangeAxis                         # {"range": {start, stop, step}}: 0-based
    start::Int                            # half-open window, axis kept
    stop::Int
    step::Int
end
struct _GatedAxis                         # {"gated_by": set}: the derived set's members
    set::String
end
const _GateAxisSpec = Union{_AllAxis, _FixedAxis, _RangeAxis, _GatedAxis}

"""
    _GateSpec(axes, applies_to)

A projection-pushdown gate (see [`provider_gate_spec`](@ref)), typed: one axis
per native array axis, exactly one of them gated on a derived index set, and
the fetched variable names the slab is published under.
"""
struct _GateSpec
    axes::Vector{_GateAxisSpec}
    applies_to::Vector{String}
end

# The typed gate of `raw` (the `Dict("axes" => …, "applies_to" => …)` a provider
# or the pushdown record writes), for provider `key`'s diagnostics.
function _GateSpec(raw::AbstractDict, key::AbstractString)
    axes = get(raw, "axes", nothing)
    applies = get(raw, "applies_to", nothing)
    (axes === nothing || applies === nothing) && throw(
        RefreshError(
            "gated provider '$key' gate spec needs both `axes` and `applies_to`"
        )
    )
    typed = _GateAxisSpec[_gate_axis(ax, ax_i, key) for (ax_i, ax) in enumerate(axes)]
    any(a -> a isa _GatedAxis, typed) || throw(
        RefreshError(
            "gated provider '$key' declares no {\"gated_by\":…} axis"
        )
    )
    return _GateSpec(typed, String[String(n) for n in applies])
end
_GateSpec(g::_GateSpec, ::AbstractString) = g

function _gate_axis(ax, ax_i::Int, key::AbstractString)::_GateAxisSpec
    ax == "all" && return _AllAxis()
    if ax isa AbstractDict && haskey(ax, "fixed")
        fx = ax["fixed"]
        return _FixedAxis(fx isa AbstractVector ? Int(first(fx)) : Int(fx))
    elseif ax isa AbstractDict && haskey(ax, "range")
        # Bounds are integers here: a metaparameter name resolves where the
        # select is parsed.
        r = ax["range"]
        step = Int(get(r, "step", 1))
        step >= 1 || throw(
            RefreshError(
                "gated provider '$key' axis $ax_i: range.step must be >= 1, got $step"
            )
        )
        return _RangeAxis(Int(get(r, "start", 0)), Int(r["stop"]), step)
    elseif ax isa AbstractDict && haskey(ax, "gated_by")
        return _GatedAxis(String(ax["gated_by"]))
    end
    throw(
        RefreshError(
            "gated provider '$key' axis $ax_i is malformed " *
                "(expected \"all\", {\"fixed\":[i]}, {\"range\":{start,stop,step}}, " *
                "or {\"gated_by\":set})"
        )
    )
end

"""
    _ProviderTraits

What a run reads off a provider, asked once (`_provider_traits`):

* `gate` — its projection-pushdown gate, or `nothing` for an ordinary provider;
* `is_const` — time-invariant (sampled once, no refresh);
* `refresh_times` — its cadence anchors (empty for a const or gated provider);
* `extent_metaparameter` — the metaparameter its own extent binds, or `nothing`;
* `supports_selection` — whether `provider_sample` takes a `selection`.
"""
struct _ProviderTraits
    gate::Union{Nothing, _GateSpec}
    is_const::Bool
    refresh_times::Vector{Float64}
    extent_metaparameter::Union{Nothing, String}
    supports_selection::Bool
end

# Whether `f` has a method for `(p, t)` other than the protocol's throwing
# fallback.
_implements(f, p) = which(f, Tuple{typeof(p), Float64}) !== which(f, Tuple{Any, Real})

"""
    _provider_traits(prov, key; gate = nothing) -> _ProviderTraits

Describe provider `prov` (bound under `key`): read every protocol function once
and check it implements the required `provider_sample`, and
`provider_refresh_times` unless it is gated (a gated provider is fetched once,
after value invention, and never refreshed). `gate` is a gate the caller derived
(the pushdown rewrite's record), which takes precedence over the provider's own
`provider_gate_spec`.
"""
function _provider_traits(prov, key::AbstractString; gate = nothing)
    _implements(provider_sample, prov) || throw(
        RefreshError(
            "provider '$key': provider_sample not implemented for $(typeof(prov)); " *
                "the data binding (EarthSciIO) or a mock must add a method"
        )
    )
    raw = gate === nothing ? provider_gate_spec(prov) : gate
    g = raw === nothing ? nothing : _GateSpec(raw, key)
    mp = provider_extent_metaparameter(prov)
    if g === nothing
        times = collect(Float64, provider_refresh_times(prov))
        is_const = provider_is_const(prov)
    else
        times = Float64[]
        is_const = true
    end
    return _ProviderTraits(
        g, is_const, times, mp === nothing ? nothing : String(mp),
        provider_supports_selection(prov)
    )
end

# A gated provider deferred to the build: fetched pre-sliced once value
# invention has materialized its gating set's members (`_build_run`).
struct _GatedProvider
    prov::Any
    gate::_GateSpec
end

# ============================================================================
# Gated providers: the selective fetch after value invention
# ============================================================================

# The const-array keys ONE GATED PROVIDER may publish its fetched variable `nm`
# under, given every gate issued in the same fetch.
#
# `_const_factor_aliases` resolves a bare authored name against EVERY model
# variable whose final dotted segment matches it. That is exactly what a
# document-scoped `member_factor` wants, and it is WRONG for a gated provider:
# sibling loaders may expose the SAME variable name — `ISRM_SR_L0.SOA`,
# `ISRM_SR_L1.SOA` and `ISRM_SR_L2.SOA` are three DIFFERENT slabs of one zarr
# store, told apart only by which loader they came from — so tail-matching makes
# each of those three providers claim all three aliases, and whichever provider
# the collection visits last would win for all of them, in hash order.
#
# A provider claims an alias when it is the SOLE claimant, or when the alias IS
# its own provider key — the post-flatten `"<Loader>.<var>"` spelling of exactly
# that provider's variable, which no sibling can also be. An alias that several
# providers claim and none owns is AMBIGUOUS and is left unwritten: a missing
# const array is a loud failure at gather time, an arbitrarily chosen one is
# a wrong answer.
function _gated_alias_claims(gated::AbstractDict{String, _GatedProvider}, model)
    claims = Dict{String, Set{String}}()      # alias => the provider keys claiming it
    for (key, entry) in gated, name in entry.gate.applies_to
        for a in _const_factor_aliases(model, name)
            push!(get!(claims, a, Set{String}()), key)
        end
    end
    return claims
end

function _gated_const_keys(
        claims::AbstractDict, model, key::AbstractString,
        nm::AbstractString
    )
    aliases = _const_factor_aliases(model, nm)
    ks = String[
        a for a in aliases
            if length(get(claims, a, Set{String}([String(key)]))) == 1 ||
            a == String(key)
    ]
    isempty(ks) && throw(
        RefreshError(
            "gated provider '$key' variable '$nm': every const-array key it resolves " *
                "to ($(sort!(collect(aliases)))) is also claimed by another gated " *
                "provider, so the fetched slab has no unambiguous name to be published " *
                "under. Key the provider \"<Loader>.<var>\" so its own spelling can win, " *
                "or give the sibling loaders' variables distinct names"
        )
    )
    return ks
end

"""
    _fetch_gated_providers(gated, index_sets, vi, t0, model) -> Dict{String,Any}

Resolve each gated provider's `selection` from the materialized value-invention
members (`vi`), fetch ONLY the compact slab, and return the const arrays to add
to the build's registry: model variable name => compact `Float64` array.

Each `gated_by` axis becomes the set's members (1-based, in set order) and the
new compact axis, whose length is checked against the set's materialized
extent; a `fixed` axis is dropped; a `range` axis is a kept strided window. A
provider that cannot take a selection is fetched whole and sliced by the same
per-axis selection, so the two give the same slab.
"""
function _fetch_gated_providers(
        gated::AbstractDict{String, _GatedProvider}, index_sets, vi, t0::Float64, model
    )
    out = Dict{String, Any}()
    (vi === nothing) && isempty(gated) && return out
    # Who may publish under which const-array key — computed over ALL the gates
    # up front, because "am I the only claimant?" is not a per-provider question.
    alias_claims = _gated_alias_claims(gated, model)
    # derived set name → its producer faq id (for `gated_by` resolution).
    set_to_faq = Dict{String, String}()
    if index_sets !== nothing
        for (sname, is) in index_sets
            is isa IndexSet || continue
            is.kind == "derived" && is.from_faq !== nothing &&
                (set_to_faq[String(sname)] = String(is.from_faq))
        end
    end
    vi_members = vi === nothing ? Dict{String, Vector{Any}}() : vi.members
    vi_extents = vi === nothing ? Dict{String, Int}() : vi.extents

    for (key, entry) in gated
        prov, gate = entry.prov, entry.gate
        selection = Vector{Any}(undef, length(gate.axes))
        drop_axes = Int[]                 # positions of `fixed` axes (dropped)
        gated_pos = 0                     # position of the single gated axis
        gated_extent = 0
        for (ax_i, ax) in enumerate(gate.axes)
            if ax isa _AllAxis
                selection[ax_i] = Colon()
            elseif ax isa _FixedAxis
                selection[ax_i] = ax.index + 1          # 0-based native → 1-based
                push!(drop_axes, ax_i)
            elseif ax isa _RangeAxis
                selection[ax_i] = collect((ax.start + 1):ax.step:ax.stop)
            else
                sname = ax.set
                haskey(set_to_faq, sname) || throw(
                    RefreshError(
                        "gated provider '$key' gates on '$sname' which is not a " *
                            "derived index set with a from_faq"
                    )
                )
                faq = set_to_faq[sname]
                haskey(vi_members, faq) || throw(
                    RefreshError(
                        "gated provider '$key' gates on '$sname' (faq '$faq') but its " *
                            "value-invention members were not materialised"
                    )
                )
                mem = Int[Int(m) for m in vi_members[faq]]   # 1-based ids, set order
                selection[ax_i] = mem
                gated_pos = ax_i
                gated_extent = get(vi_extents, faq, length(mem))
            end
        end

        # position of the compact gated axis AFTER dropping the fixed axes.
        gated_pos_out = gated_pos - count(<(gated_pos), drop_axes)
        drop_tuple = Tuple(drop_axes)
        pushed = provider_supports_selection(prov)
        sample = pushed ? provider_sample(prov, t0; selection = selection) :
            provider_sample(prov, t0)
        for nm in gate.applies_to
            field = _sample_field(sample, nm)
            if pushed
                isempty(drop_tuple) || (field = dropdims(field; dims = drop_tuple))
            else
                field = field[selection...]
            end
            # The slab takes the conversion a whole sample does
            # (`forcing_from_sample`).
            arr = forcing_from_sample(field, nm)
            size(arr, gated_pos_out) == gated_extent || throw(
                RefreshError(
                    "gated provider '$key' variable '$nm'" *
                        (pushed ? ": fetched compact axis is " : " (fallback slice): compact axis is ") *
                        "$(size(arr, gated_pos_out)) but the gating set extent is $gated_extent"
                )
            )
            for k in _gated_const_keys(alias_claims, model, key, nm)
                out[k] = arr
            end
        end
    end
    return out
end
