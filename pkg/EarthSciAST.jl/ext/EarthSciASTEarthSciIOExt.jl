"""
    EarthSciASTEarthSciIOExt

Wires the EarthSciIO Julia `Provider` into EarthSciAST's data-provider seam
([`provider_refresh_times`](@ref) / [`provider_sample`](@ref)), loaded
automatically whenever `EarthSciIO` is in the session alongside
EarthSciAST. Before this extension existed the adapter shipped only as
a doc comment on the seam (`data_refresh.jl`), so every run script had to repeat
it; now `simulate(...; providers = Dict("<ModelPath>.<param>" => provider))`
accepts an EarthSciIO provider with no per-script glue. The key is the CONSUMING
PARAMETER's flattened name: from esm 1.0.0 a data source declares no variables of
its own, so the parameter IS the loaded field (esm-spec §8.5).

DELIBERATELY THIN. EarthSciAST is agnostic to dimension order: the provider sample is
handed straight to the forcing-write / const-array fold, which
linearizes it column-major against the CONSUMER's declared shape and never
inspects the data's named dims or coordinates (`_write_forcing!`,
`_provider_const_field`, the `LinearIndices(pg.dims)` gather). So this adapter
does NOT reproject, transpose, or reorder — it returns the provider's array in
its native file order. Any grid/orientation reconciliation is the model's job
(declare the loader field in the source's native dim order, then regrid/reindex
in a coupling expression), exactly as it would be for any other provider.

Kept a `weakdep` extension (mirroring `MTKExt` / `DataRefreshExt`) so the base
package carries no EarthSciIO dependency; without it loaded, the core seam throws
a `RefreshError` naming what to load.
"""
module EarthSciASTEarthSciIOExt

using EarthSciAST: RefreshError, OutputError, StateSnapshot, VarGridding,
    derive_output_gridding, scatter_grid!, gather_flat!, OutputMeta, DimCoord,
    plan_dimension_coordinates, output_var_dims, DEFAULT_TIME_DIM
# The declared §8.5 unit conversion, parsed once per loader variable and applied
# at delivery (see `_convert_units`).
using EarthSciAST: parse_unit_conversion, apply_unit_conversion

# Explicit imports so we can add the extension methods to these generics.
import EarthSciAST: provider_refresh_times, provider_sample, provider_supports_selection
import EarthSciAST: provider_gate_spec, provider_extent_metaparameter
import EarthSciAST: providers_from_document
import EarthSciAST: build_zarr_sink, sink_output_times, sink_open!, sink_write!,
    sink_flush!, sink_close!, sink_observed_names, zarr_restart_state
import EarthSciIO

# The cadence anchors, straight from the provider (empty ⇒ CONST, which makes the
# default `provider_is_const` — `isempty(provider_refresh_times(p))` — report true
# with no extra method).
provider_refresh_times(p::EarthSciIO.Provider) = EarthSciIO.refresh_times(p)

# Capability bridge: whether this provider can push a projection down (true for a
# store-backed zarr provider, false for a whole-file reader). The generic default
# (`provider_supports_selection(::Any) = false`, data_refresh.jl) already covers
# every non-EarthSciIO source.
provider_supports_selection(p::EarthSciIO.Provider) = EarthSciIO.supports_selection(p)

# Translate the provider-NEUTRAL, 1-based, per-axis positional `selection` into
# EarthSciIO's native `Dict("axes" => [...])` with 0-based indices:
#   Colon()                       → "all"                     (whole axis)
#   Integer i                     → Dict("indices" => [i-1])  (single fixed index)
#   AbstractVector v (of Integer) → Dict("indices" => v .- 1) (ordered index list)
# 1-based is validated here (every index ≥ 1) so an accidental 0-based caller gets
# a clear error rather than a silently-shifted, off-by-one slice.
function _neutral_selection_to_native(selection::AbstractVector)
    axes = Any[]
    for (d, ax) in enumerate(selection)
        if ax isa Colon
            push!(axes, "all")
        elseif ax isa Integer
            ax >= 1 || throw(RefreshError(
                "selection axis $d: index must be 1-based (≥ 1), got $ax"))
            push!(axes, Dict("indices" => [Int(ax) - 1]))
        elseif ax isa AbstractVector{<:Integer}
            idx = collect(Int, ax)
            all(>=(1), idx) || throw(RefreshError(
                "selection axis $d: indices must be 1-based (≥ 1), got $idx"))
            push!(axes, Dict("indices" => idx .- 1))
        else
            throw(RefreshError(
                "selection axis $d: unrecognized entry $(ax)::$(typeof(ax)); use " *
                "Colon() (whole axis), an Integer (1-based single index), or an " *
                "AbstractVector{<:Integer} (1-based ordered index list)"))
        end
    end
    return Dict("axes" => axes)
end
_neutral_selection_to_native(selection) = throw(RefreshError(
    "selection must be an AbstractVector with one entry per native axis " *
    "(Colon / Integer / integer vector), got $(typeof(selection))"))

# One forcing field at cadence tick `t`, in the source's NATIVE layout (no
# reorder — see the module docstring). `providers` is keyed one entry per consumer
# variable, so a sample carries exactly one data variable; a multi-variable blob
# is a binding error the caller must split (EarthSciAST can't know which field a bare
# array means). Returns the bare `AbstractArray` that `_write_forcing!` /
# `_provider_const_field` expect for a single-variable sample.
#
# `selection===nothing` (default) samples the whole array — byte-identical to the
# pre-pushdown path. A non-nothing `selection` is translated to the native zarr
# `select` and pushed down so only the intersecting chunks are fetched; the gated
# axis is returned in EXACTLY the requested index order (the reader gathers in the
# order of the index vector — see EarthSciIO `_resolve_axis`/`_assemble`).
function provider_sample(p::EarthSciIO.Provider, t::Real; selection = nothing)
    if selection === nothing
        nds = EarthSciIO.refresh(p, Float64(t))          # == materialize(p, t)
    else
        provider_supports_selection(p) || throw(RefreshError(
            "provider does not support selection/pushdown: $(typeof(p)) is not a " *
            "store-backed reader (provider_supports_selection is false). Sample it " *
            "without a `selection`, or bind a pushdown-capable provider (zarr)"))
        native = _neutral_selection_to_native(selection)
        nds = EarthSciIO.refresh(p, Float64(t); select = native)
    end
    vars = EarthSciIO.variable_names(nds)
    length(vars) == 1 || throw(RefreshError(
        "EarthSciIO provider yields $(length(vars)) variables $(vars); bind one " *
        "provider per consumer variable (providers[\"<ModelPath>.<param>\"] => " *
        "provider) so " *
        "each sample is a single field, or slice the provider upstream"))
    return nds[vars[1]].data
end

# --------------------------------------------------------------------------- #
# providers_from_document — document-declared provider construction (Phase 1
# clean consolidation). The document's `data_sources` say WHAT to read (source
# URL, ingest options) and `metadata.esio_format` says HOW (the EarthSciIO
# format registry name). This closes the loop: the runner no longer
# hand-constructs providers — it asks the document.
#
# esm 1.0.0 moved the BINDING from the source to the consumer: a source exposes
# no variables of its own, and a model reads one by declaring a PARAMETER whose
# `update` names the source and binds a `file_variable` (esm-spec §8.5). So the
# walk is over the models' parameters rather than over a loader's variable
# table, and each provider is keyed by the CONSUMING PARAMETER's flattened name
# ("<ModelPath>.<param>") — which is exactly the name `prepare`'s providers
# contract binds ("one provider per consumer variable"), the name the
# single-variable `provider_sample` adapter returns, and the name the
# record-derived pushdown path attaches its per-key gate to. All the parameters
# drawing from one source share that source's Cache (a per-source subdir under
# `cache_root`), so a store's metadata objects are fetched once.
# --------------------------------------------------------------------------- #

# Raw document from any accepted carrier — a native `Dict`, a path, or an
# `EsmFile`. `providers_from_document` needs the WHOLE document, not just its
# `data_sources`: a `select` range bound may name a `metaparameters` entry, and
# the bindings live on the models' parameters.
_doc_raw(doc::AbstractDict) = doc
_doc_raw(doc::AbstractString) = _doc_raw(EarthSciAST.load(doc))
# EsmFile (or anything typed that serializes): reuse the round-trip emitter.
_doc_raw(file) = _doc_raw(EarthSciAST.serialize_esm_file(file))

# --------------------------------------------------------------------------- #
# The DECLARED ingest (esm-spec §8.9). Between the bytes and a usable array sit
# four document fields — how the format decodes (`reader_options`), how a text
# column becomes numbers (`codes`), which records are real (`record_filter`),
# and what the loader delivers (`select`) — plus a fifth, `extent`, by which a
# loader tells `prepare` its own record count. NONE of them is a caller-side
# transform any more: a runner that does not know this model can run it.
# --------------------------------------------------------------------------- #

"""A loader variable's declared string→number code map (`codes`, §8.9.1).
`unmapped` is `:drop` (lose the whole record), `:error`, or a `Float64`."""
struct CodeMap
    map::Dict{String,Float64}
    case_insensitive::Bool
    unmapped::Union{Symbol,Float64}
end

# The code for one raw cell, or `nothing` when it is unmapped and the declared
# policy is to drop the record. Surrounding whitespace is always trimmed.
function _code_lookup(cm::CodeMap, raw::AbstractString, var::AbstractString)
    key = strip(String(raw))
    cm.case_insensitive && (key = uppercase(key))
    haskey(cm.map, key) && return cm.map[key]
    cm.unmapped isa Float64 && return cm.unmapped::Float64
    cm.unmapped === :drop && return nothing
    throw(RefreshError(
        "loader variable '$var': value $(repr(String(raw))) is not in its declared " *
        "`codes` map (set codes.unmapped to \"drop\" or a number to accept it)"))
end

"""One column of a record-table loader: where it comes from, how it decodes."""
struct ColumnSpec
    # The CONSUMING PARAMETER's flattened name ("Ingest.lon") — the column's
    # identity, because two models may bind a same-named parameter to one source
    # with different `file_variable`s and their columns must not collide.
    name::String
    file_variable::String     # the on-disk column
    codes::Union{Nothing,CodeMap}
    # The declared `unit_conversion` (esm-spec §8.5), parsed; `nothing` when the
    # variable declares none.
    unit_conversion::Any
end

"""
A record-table loader's decode, SHARED by its per-variable providers.

A `points` loader declaring a `record_filter` or a `codes` map is a TABLE, not a
bag of independent arrays: which rows survive is a property of the whole
RECORD, so every column must be filtered by the same mask or the columns
silently misalign (esm-spec §8.9.3). That forces one decode — this type —
rather than one per variable, which also means the 69 MB FF10 zip is unzipped
and parsed once for all eight of its columns instead of eight times.

Materialized lazily on first use and then held: `prepare` samples the providers
one after another (single-threaded, which is why the memo needs no lock), and
the second must not re-read.
"""
mutable struct RecordTable
    loader::String
    provider::EarthSciIO.Provider
    columns::Vector{ColumnSpec}
    require_finite::Vector{String}      # FILE variable names (esm-spec §8.9)
    cache::Union{Nothing,Dict{String,Vector{Float64}}}
end

# One numeric EarthSciIO column widened to Float64. A TEXT column with no
# `codes` map is a modelling mistake, not a silent drop: a model forcing must be
# numeric, so it is refused at the loader boundary (§8.9.1).
function _widen_column(name::AbstractString, data)
    eltype(data) <: Real && return Float64[Float64(x) for x in data]
    throw(RefreshError(
        "loader variable '$name' decoded as strings; a model forcing must be " *
        "numeric (declare a `codes` map for it)"))
end

"""Decode + filter once; every later column read is free."""
function _table_columns(t::RecordTable)
    t.cache === nothing || return t.cache
    nds = EarthSciIO.materialize(t.provider)

    # Raw columns (unfiltered), plus the per-record keep mask that the `codes`
    # drops and the finite requirement build up together.
    raw = Dict{String,Vector{Float64}}()
    keep = Bool[]
    nrec = -1
    for spec in t.columns
        haskey(nds.variables, spec.file_variable) || throw(RefreshError(
            "loader '$(t.loader)': the reader returned no column " *
            "'$(spec.file_variable)' for variable '$(spec.name)' " *
            "(present: $(EarthSciIO.variable_names(nds)))"))
        f = nds.variables[spec.file_variable]
        ndims(f.data) == 1 || throw(RefreshError(
            "loader '$(t.loader)' declares a record filter, but variable " *
            "'$(spec.name)' is rank $(ndims(f.data)) $(size(f.data)); a record " *
            "filter needs a single record axis"))
        n = length(f.data)
        if nrec < 0
            nrec = n
            keep = trues(n)
        elseif nrec != n
            throw(RefreshError(
                "loader '$(t.loader)': column '$(spec.name)' has $n records but an " *
                "earlier column has $nrec; the reader did not return one aligned table"))
        end
        raw[spec.name] = if spec.codes === nothing
            _widen_column(spec.name, f.data)
        elseif eltype(f.data) <: AbstractString
            col = Vector{Float64}(undef, n)
            for i in 1:n
                v = _code_lookup(spec.codes, f.data[i], spec.name)
                if v === nothing
                    keep[i] = false
                    col[i] = NaN
                else
                    col[i] = v
                end
            end
            col
        else
            throw(RefreshError(
                "loader '$(t.loader)' variable '$(spec.name)' declares `codes`, but " *
                "the column decoded as $(eltype(f.data)); a code map maps a TEXT " *
                "column to numbers"))
        end
    end
    nrec < 0 && (nrec = 0)

    # `require_finite` names FILE variables (esm-spec §8.9): from 1.0.0 a source
    # declares no variables of its own, so the filter is stated in the reader's
    # vocabulary. Resolve it there — through a bound parameter's already-decoded
    # column when one reads it, and straight from the reader otherwise, since a
    # source may filter on a column no parameter goes on to read.
    by_file = Dict{String,Vector{Float64}}()
    for spec in t.columns
        get!(by_file, spec.file_variable) do
            raw[spec.name]
        end
    end
    for name in t.require_finite
        col = if haskey(by_file, name)
            by_file[name]
        elseif haskey(nds.variables, name)
            _widen_column(name, nds.variables[name].data)
        else
            throw(RefreshError(
                "loader '$(t.loader)': record_filter.require_finite names file " *
                "variable '$name', which the source does not deliver (present: " *
                "$(EarthSciIO.variable_names(nds)))"))
        end
        length(col) == nrec || throw(RefreshError(
            "loader '$(t.loader)': record_filter.require_finite column '$name' has " *
            "$(length(col)) records but the table has $nrec"))
        for i in 1:nrec
            isfinite(col[i]) || (keep[i] = false)
        end
    end

    kept = count(keep)
    out = Dict{String,Vector{Float64}}(name => col[keep] for (name, col) in raw)
    kept == nrec || println("  [esio] loader '$(t.loader)': $nrec records read, ",
                            "$kept kept by its declared record filter")
    t.cache = out
    return out
end

function _table_column(t::RecordTable, name::AbstractString)
    cols = _table_columns(t)
    haskey(cols, name) || throw(RefreshError(
        "loader '$(t.loader)' has no column '$name' (declared: $(sort!(collect(keys(cols)))))"))
    return cols[name]
end

# --- `select`: the per-axis vocabulary, parsed once (§8.9.2) ----------------- #

# A `range` bound may be an integer or the NAME of a metaparameter, which
# resolves to that metaparameter's document default — so a loader can say
# `W[0:N_SRC]` in the model's own terms instead of repeating 52411 and drifting
# from the index set sized by the same metaparameter.
function _resolve_bound(doc, ctx::AbstractString, what::AbstractString, v)
    v isa Integer && return Int(v)
    v isa AbstractString || throw(RefreshError(
        "$ctx: range.$what must be an integer or a metaparameter name, got $(repr(v))"))
    mps = get(doc, "metaparameters", nothing)
    mp = mps isa AbstractDict ? get(mps, String(v), nothing) : nothing
    d = mp isa AbstractDict ? get(mp, "default", nothing) : nothing
    d isa Integer || throw(RefreshError(
        "$ctx: range.$what names $(repr(String(v))), which is not a metaparameter " *
        "with an integer default"))
    return Int(d)
end

# One axis of a `select.axes`, normalized to the gate vocabulary EarthSciAST's
# build already speaks ("all" / fixed / range / gated_by) — one spelling,
# whether an author wrote it or the pushdown rewrite generated it.
function _parse_select_axis(doc, ctx::AbstractString, i::Int, ax)
    (ax == "all") && return "all"
    ax isa AbstractDict || throw(RefreshError(
        "$ctx axis $i: expected \"all\" or an object, got $(repr(ax))"))
    ks = Set(String(k) for k in keys(ax))
    if ks == Set(["fixed"])
        fx = ax["fixed"]
        return Dict{String,Any}("fixed" => Int(fx isa AbstractVector ? first(fx) : fx))
    elseif ks == Set(["range"])
        r = ax["range"]
        r isa AbstractDict && haskey(r, "stop") || throw(RefreshError(
            "$ctx axis $i: range needs a \"stop\""))
        start = haskey(r, "start") ? _resolve_bound(doc, "$ctx axis $i", "start", r["start"]) : 0
        stop = _resolve_bound(doc, "$ctx axis $i", "stop", r["stop"])
        step = haskey(r, "step") ? _resolve_bound(doc, "$ctx axis $i", "step", r["step"]) : 1
        step >= 1 || throw(RefreshError("$ctx axis $i: range.step must be >= 1, got $step"))
        return Dict{String,Any}("range" =>
            Dict{String,Any}("start" => start, "stop" => stop, "step" => step))
    elseif ks == Set(["gated_by"])
        return Dict{String,Any}("gated_by" => String(ax["gated_by"]))
    end
    throw(RefreshError(
        "$ctx axis $i: unrecognised axis selector keys $(sort!(collect(ks))); one axis " *
        "is \"all\", {\"fixed\": i}, {\"range\": {start, stop, step}} or " *
        "{\"gated_by\": \"<derived set>\"}"))
end

function _parse_declared_select(doc, ctx::AbstractString, node)
    sel = get(node, "select", nothing)
    sel === nothing && return nothing
    sel isa AbstractDict || throw(RefreshError("$ctx.select must be an object"))
    axes = get(sel, "axes", nothing)
    axes isa AbstractVector || throw(RefreshError("$ctx.select needs an \"axes\" array"))
    return Any[_parse_select_axis(doc, "$ctx.select", i, ax) for (i, ax) in enumerate(axes)]
end

function _parse_codes(ctx::AbstractString, vd)
    codes = get(vd, "codes", nothing)
    codes === nothing && return nothing
    codes isa AbstractDict || throw(RefreshError("$ctx.codes must be an object"))
    m = get(codes, "map", nothing)
    m isa AbstractDict || throw(RefreshError("$ctx.codes needs a \"map\" object"))
    ci = Bool(get(codes, "case_insensitive", false))
    unmapped = if !haskey(codes, "unmapped")
        :error                                   # fail-closed default
    else
        u = codes["unmapped"]
        u == "drop" ? :drop : u == "error" ? :error :
        u isa Real ? Float64(u) :
        throw(RefreshError("$ctx.codes.unmapped must be \"drop\", \"error\" or a number"))
    end
    out = Dict{String,Float64}()
    for (k, v) in m
        v isa Real || throw(RefreshError("$ctx.codes.map[$(repr(String(k)))] must be a number"))
        out[ci ? uppercase(String(k)) : String(k)] = Float64(v)
    end
    return CodeMap(out, ci, unmapped)
end

# The declared axes as EarthSciIO's native selection. A contiguous `range` stays
# a `slice` rather than expanding to a 52,411-long index list, so a store-backed
# reader fetches only the intersecting chunks.
function _declared_to_native(axes)
    native = Any[]
    for ax in axes
        if ax == "all"
            push!(native, "all")
        elseif haskey(ax, "fixed")
            push!(native, Dict("indices" => [ax["fixed"]]))
        elseif haskey(ax, "range")
            r = ax["range"]
            push!(native, Dict("slice" => [r["start"], r["stop"], r["step"]]))
        else
            # Unreachable: a gated axis is deferred, never pushed eagerly.
            push!(native, "all")
        end
    end
    return Dict("axes" => native)
end

# Apply the declared axes to an ALREADY-materialized array: take each axis's
# indices, then DROP the `fixed` axes (a fixed index is a choice, not a
# dimension). The reader-pushed and engine-applied paths MUST agree exactly;
# this is the second of the two.
function _apply_declared_select(key::AbstractString, arr::AbstractArray, axes)
    all(ax == "all" for ax in axes) && return arr
    length(axes) == ndims(arr) || throw(RefreshError(
        "provider '$key': the declared select has $(length(axes)) axes but the array " *
        "is rank $(ndims(arr)) $(size(arr))"))
    idx = Any[]
    drop = Int[]
    for (i, ax) in enumerate(axes)
        dim = size(arr, i)
        if ax == "all"
            push!(idx, Colon())
        elseif haskey(ax, "fixed")
            g = ax["fixed"]
            0 <= g < dim || throw(RefreshError(
                "provider '$key': the declared select reaches index $g on axis $i, " *
                "whose native length is $dim"))
            push!(idx, (g + 1):(g + 1))
            push!(drop, i)
        elseif haskey(ax, "range")
            r = ax["range"]
            r["stop"] <= dim || throw(RefreshError(
                "provider '$key': the declared select reaches index $(r["stop"] - 1) on " *
                "axis $i, whose native length is $dim"))
            push!(idx, (r["start"] + 1):r["step"]:r["stop"])
        else
            throw(RefreshError(
                "provider '$key': axis $i gates on '$(ax["gated_by"])', which is " *
                "resolved by value-invention inside prepare, not by an eager sample"))
        end
    end
    out = arr[idx...]
    isempty(drop) && return out
    return dropdims(out; dims = Tuple(drop))
end

"""
    DeclaredProvider

One loader VARIABLE, served with the ingest its document declares (§8.9): the
format's decode options, an optional shared [`RecordTable`], the per-axis
`select`, and the metaparameter its extent binds. A loader with none of those
degenerates to a bare EarthSciIO provider read whole — the pre-§8.9 behaviour.
"""
struct DeclaredProvider
    key::String                                   # "<ModelPath>.<param>"
    varname::String                               # its LOCAL name (the model array)
    inner::EarthSciIO.Provider
    table::Union{Nothing,RecordTable}
    column::String
    select::Union{Nothing,Vector{Any}}
    push_to_reader::Bool                          # where `select` is honoured
    extent_mp::Union{Nothing,String}
    unit_conversion::Any                          # the declared §8.5 conversion
end

provider_refresh_times(p::DeclaredProvider) = EarthSciIO.refresh_times(p.inner)

# A record-table column never supports a pushed-down selection: its rows are
# chosen by the loader's declared filter AFTER the decode, so an index pushed to
# the reader would address raw rows rather than delivered ones.
provider_supports_selection(p::DeclaredProvider) =
    p.table === nothing && EarthSciIO.supports_selection(p.inner)

provider_extent_metaparameter(p::DeclaredProvider) = p.extent_mp

# A declared select carrying a `gated_by` axis IS a provider-declared gate:
# `prepare` defers it past value-invention and fetches it pre-sliced to the
# materialised members, through the machinery the record-derived gate uses.
function provider_gate_spec(p::DeclaredProvider)
    p.select === nothing && return nothing
    any(ax isa AbstractDict && haskey(ax, "gated_by") for ax in p.select) || return nothing
    return Dict{String,Any}("axes" => p.select, "applies_to" => Any[p.varname])
end

# Produce the values in the variable's DECLARED `units` (esm-spec §8.5).
#
# Applied at DELIVERY — after the loader's decode, `codes`, `record_filter` and
# `select` — so the filter still reasons about the raw column (a conversion
# cannot turn a dropped record into a kept one) and every delivered array is
# converted exactly once, whether it arrived through the record table, a
# reader-pushed select, or the engine's gated fetch.
#
# A variable with no declared conversion returns the array untouched: this is a
# no-op for every document that does not declare one.
function _convert_units(p::DeclaredProvider, arr)
    p.unit_conversion === nothing && return arr
    return apply_unit_conversion(arr, p.unit_conversion; variable_name = p.key)
end

function provider_sample(p::DeclaredProvider, t::Real; selection = nothing)
    if selection !== nothing
        # The GATED path: `prepare` resolved the members and is asking for that
        # slab. It supersedes the declared select it was derived from — but NOT
        # the declared unit_conversion, which is a property of the VALUES rather
        # than of which of them were fetched.
        return _convert_units(p, provider_sample(p.inner, t; selection = selection))
    end
    arr = if p.table !== nothing
        _table_column(p.table, p.column)
    elseif p.select !== nothing && p.push_to_reader
        nds = EarthSciIO.refresh(p.inner, Float64(t); select = _declared_to_native(p.select))
        vars = EarthSciIO.variable_names(nds)
        length(vars) == 1 || throw(RefreshError(
            "provider '$(p.key)': the reader returned $(length(vars)) variables $vars"))
        nds[vars[1]].data
    else
        provider_sample(p.inner, Float64(t))
    end
    # Pushed to the reader, only the `fixed` axes still need dropping; applied
    # engine-side, the whole select does. Both produce the same array.
    p.select === nothing && return _convert_units(p, arr)
    axes = p.push_to_reader ?
        Any[ax isa AbstractDict && haskey(ax, "fixed") ?
            Dict{String,Any}("fixed" => 0) : "all" for ax in p.select] : p.select
    return _convert_units(p, _apply_declared_select(p.key, arr, axes))
end

# Every (flattened-name, variable-dict) pair of a raw model tree, recursing
# through `subsystems` exactly as `flatten` namespaces them.
function _walk_model_variables(models, prefix::String, cb)
    models isa AbstractDict || return
    for mname0 in sort!(String[String(k) for k in keys(models)])
        m = models[mname0]
        m isa AbstractDict || continue
        path = isempty(prefix) ? mname0 : "$(prefix).$(mname0)"
        vars = get(m, "variables", nothing)
        if vars isa AbstractDict
            for vname0 in sort!(String[String(k) for k in keys(vars)])
                cb("$(path).$(vname0)", vname0, vars[vname0])
            end
        end
        _walk_model_variables(get(m, "subsystems", nothing), path, cb)
    end
    return
end

# The FIRST `data` rule of a parameter's `update`, or `nothing`. `update` is a
# single rule object or an ordered array of two or more (esm-spec §5.4).
function _data_update_rule(vd)
    vd isa AbstractDict || return nothing
    u = get(vd, "update", nothing)
    rules = u isa AbstractVector ? u : (u isa AbstractDict ? Any[u] : Any[])
    for r in rules
        r isa AbstractDict && get(r, "kind", nothing) == "data" && return r
    end
    return nothing
end

function providers_from_document(doc;
                                 cache_root::AbstractString,
                                 loaders = nothing,
                                 url_overrides::AbstractDict = Dict{String,String}())
    raw = _doc_raw(doc)
    dss = get(raw, "data_sources", nothing)
    dss isa AbstractDict || throw(RefreshError(
        "providers_from_document: the document declares no data_sources"))
    want = loaders === nothing ? nothing : Set(String(l) for l in loaders)

    # Group the consuming parameters by the source they name, so one source's
    # Cache and RecordTable are built once and shared.
    consumers = Dict{String,Vector{NamedTuple}}()
    _walk_model_variables(get(raw, "models", nothing), "", (key, local_name, vd) -> begin
        rule = _data_update_rule(vd)
        rule === nothing && return
        sname = get(rule, "source", nothing)
        sname isa AbstractString || return
        from = get(rule, "from", nothing)
        from isa AbstractDict || return
        push!(get!(() -> NamedTuple[], consumers, String(sname)),
              (key = key, local_name = local_name, from = from))
    end)

    out = Dict{String,Any}()
    for lname0 in sort!(String[String(k) for k in keys(dss)])
        lname = lname0
        want !== nothing && !(lname in want) && continue
        ld = dss[lname]
        ld isa AbstractDict || continue
        binds = get(consumers, lname, NamedTuple[])
        isempty(binds) && continue   # a source nothing reads needs no provider
        md = get(ld, "metadata", nothing)
        fmt = md isa AbstractDict ? get(md, "esio_format", nothing) : nothing
        if fmt === nothing
            # An explicitly requested source MUST be constructible; an
            # unrestricted sweep just skips format-less sources.
            want === nothing && continue
            throw(RefreshError(
                "providers_from_document: data_sources.$lname declares no " *
                "metadata.esio_format — cannot construct a provider for it"))
        end
        src = get(ld, "source", nothing)
        url = get(url_overrides, lname,
                  src isa AbstractDict ? get(src, "url_template", nothing) : nothing)
        url isa AbstractString || throw(RefreshError(
            "providers_from_document: data_sources.$lname has no source.url_template " *
            "(and no url_overrides entry)"))
        cache = EarthSciIO.Cache(; root = joinpath(String(cache_root), lname))

        # ---- the source's DECLARED ingest (esm-spec §8.9) -------------------
        # `reader_options` is the document's spelling of EarthSciIO's
        # `reader_kwargs`; handing it over verbatim is the whole point, and an
        # unrecognised key fails at Provider construction rather than decoding
        # something else silently (spec/registries.md §2.1).
        ropts = get(ld, "reader_options", nothing)
        reader_kwargs = ropts isa AbstractDict ?
            Dict{Symbol,Any}(Symbol(k) => v for (k, v) in ropts) : Dict{Symbol,Any}()
        loader_select = _parse_declared_select(raw, "data_sources.$lname", ld)
        ext = get(ld, "extent", nothing)
        extent_mp = ext isa AbstractDict && get(ext, "metaparameter", nothing) isa AbstractString ?
            String(ext["metaparameter"]) : nothing
        rf = get(ld, "record_filter", nothing)
        require_finite = String[]
        if rf isa AbstractDict && get(rf, "require_finite", nothing) isa AbstractVector
            require_finite = String[String(v) for v in rf["require_finite"]]
        end

        sort!(binds; by = b -> b.key)
        columns = ColumnSpec[]
        for b in binds
            fv = String(get(b.from, "file_variable", b.local_name))
            push!(columns, ColumnSpec(b.key, fv,
                _parse_codes("$(b.key).update.from", b.from),
                parse_unit_conversion(get(b.from, "unit_conversion", nothing);
                                      variable_name = b.key)))
        end

        # A record filter or a code map makes the source a TABLE: one decode,
        # one keep mask, columns that stay aligned.
        table = nothing
        if !isempty(require_finite) || any(c.codes !== nothing for c in columns)
            # A `require_finite` column no parameter reads is still needed to
            # compute the mask, so it is fetched alongside the bound ones.
            file_vars = sort!(unique(vcat(String[c.file_variable for c in columns],
                                          require_finite)))
            table = RecordTable(lname,
                EarthSciIO.const_provider(cache, String(url); format = String(fmt),
                                          variables = file_vars, source_loader = lname,
                                          reader_kwargs = reader_kwargs),
                columns, require_finite, nothing)
        end

        for (b, spec) in zip(binds, columns)
            key = b.key
            sel = _parse_declared_select(raw, "$(key).update.from", b.from)
            sel === nothing && (sel = loader_select)
            inner = EarthSciIO.const_provider(
                cache, String(url); format = String(fmt),
                variables = [spec.file_variable], source_loader = lname,
                reader_kwargs = reader_kwargs)
            # A declared select goes to the reader when it can fetch pre-sliced
            # AND no rows are filtered in front of it; otherwise engine-side.
            # Where it is applied is an optimization, never a semantic.
            push_down = sel !== nothing && table === nothing &&
                        EarthSciIO.supports_selection(inner) &&
                        !any(ax isa AbstractDict && haskey(ax, "gated_by") for ax in sel)
            # `varname` is the LOCAL name — it is what the gate's `applies_to`
            # names, i.e. the model array. `column` is the flattened name, which
            # is how the shared decode indexes this parameter's column.
            out[key] = DeclaredProvider(key, b.local_name, inner, table, spec.name,
                                        sel, push_down, extent_mp,
                                        spec.unit_conversion)
        end
    end
    return out
end

# --------------------------------------------------------------------------- #
# ZarrSink — the concrete streaming output sink (RFC §5, §16). Binds the
# EarthSciAST Sink protocol to EarthSciIO's Zarr v3 `ZarrWriter`: it derives a
# gridded `OutputSchema` from the flat state, scatters each `StateSnapshot` slab
# into gridded arrays (column-major, via `scatter_grid!`), and streams them as
# atomically-committed time-shards. The write-side mirror of the read-side
# `Provider` adapter above.
#
# Wave 2: state-only, host-gather, positional dim names, one store.
# Wave 3: REAL index-set dim names + CF dimension-coordinate emission (values +
# standard_name/units/axis) from the document's `coordinates` registry, plus
# per-variable CF attrs (units, …) — all carried in via the `OutputMeta` a
# `PreparedModel` derives. Observed fields, auxiliary/source coordinates,
# checkpoint profiles, and object stores are later waves; the protocol is unchanged.
# --------------------------------------------------------------------------- #

mutable struct ZarrSink
    base_url::String                 # file:// URL or path of the output store
    gridding::Vector{VarGridding}    # per-base-variable flat→gridded layout (RFC §7)
    coords::Vector{DimCoord}         # CF dimension coordinates (§8.3; may be empty)
    var_attrs::Dict{String,Dict{String,Any}}  # base var => CF variable attrs (units, …)
    output_times::Vector{Float64}    # solver-second write anchors
    profile::Symbol                  # :diagnostic | :checkpoint (codec params)
    records_per_shard::Int           # time records packed per flushed shard object
    time_dim::String                 # growable time axis name
    writer::Any                      # EarthSciIO.ZarrWriter (set at open)
    handle::Any                      # write handle (set at open)
    manifest::Any                    # EarthSciIO.OutputManifest (set at close)
end

"""
    build_zarr_sink(prep::PreparedModel, base_url; output_times, kwargs...) -> ZarrSink
    build_zarr_sink(var_map::AbstractDict, base_url; output_times, meta=nothing, kwargs...) -> ZarrSink

Construct a [`ZarrSink`](@ref) streaming the flat state to the Zarr v3 store at
`base_url`. The gridded layout is derived from the model's `var_map`
([`derive_output_gridding`](@ref), RFC §7). Given a `PreparedModel` (or an
[`OutputMeta`](@ref) via the `meta` keyword), axes are named by their REAL
index-set names and the document's `coordinates` registry is emitted as CF
dimension coordinates (RFC §8); with a bare `var_map` and no `meta`, axes keep
positional names and no coordinates are written. Keyword `output_times` are the
solver-second anchors; `profile` (`:diagnostic`/`:checkpoint`) selects codec
params; `records_per_shard` sets how many time records pack into one shard object;
`time_dim` overrides the growable axis name, which otherwise comes from the
document's `domain.independent_variable` via `meta` (RFC §7), falling back to
`"time"`.

Every variable's on-disk dims are the record axis FIRST, then its spatial axes
(`output_var_dims`), so a scalar variable's dims are exactly `[time_dim]`.
"""
function build_zarr_sink(var_map::AbstractDict, base_url::AbstractString;
                         output_times, profile::Symbol = :diagnostic,
                         records_per_shard::Integer = 8,
                         time_dim::Union{Nothing,AbstractString} = nothing,
                         meta::Union{Nothing,OutputMeta} = nothing,
                         variables::Union{Nothing,AbstractVector} = nothing)
    # The record-axis name is the document's `domain.independent_variable`
    # (RFC §7), carried on the OutputMeta; an explicit kwarg still wins.
    tdim = time_dim !== nothing ? String(time_dim) :
           meta !== nothing ? meta.time_dim : DEFAULT_TIME_DIM
    g = meta === nothing ? derive_output_gridding(var_map) :
        derive_output_gridding(var_map, meta)
    # Optional per-grid restriction (RFC §9): keep only the named base variables, so
    # one sink writes exactly one grid's variables to its own store.
    if variables !== nothing
        want = Set(String(v) for v in variables)
        available = String[x.base for x in g]
        g = VarGridding[x for x in g if x.base in want]
        isempty(g) && throw(OutputError(
            "build_zarr_sink: `variables` $(collect(want)) selected no variables from " *
            "$(available)"))
    end
    coords = meta === nothing ? DimCoord[] : plan_dimension_coordinates(g, meta)
    vattrs = meta === nothing ? Dict{String,Dict{String,Any}}() : meta.var_attrs
    return ZarrSink(String(base_url), g, coords, vattrs, collect(Float64, output_times),
                    profile, Int(records_per_shard), tdim, nothing, nothing, nothing)
end

build_zarr_sink(prep, base_url::AbstractString; kwargs...) =
    build_zarr_sink(prep.var_map, base_url; meta = prep.output_meta, kwargs...)

sink_output_times(s::ZarrSink) = s.output_times
sink_observed_names(::ZarrSink) = String[]      # Wave 2/3: state only

function sink_open!(s::ZarrSink)
    # The growable time axis FIRST (length 0 placeholder — it grows one shard per
    # flush), then the distinct spatial dims in first-seen order. Record-axis-first
    # is the one ordering decision, and it is made once in `output_var_dims`.
    dims = Pair{String,Int}[s.time_dim => 0]
    seen = Set{String}()
    for g in s.gridding, d in eachindex(g.dimnames)
        nm = g.dimnames[d]
        if !(nm in seen)
            push!(dims, nm => g.shape[d]); push!(seen, nm)
        end
    end

    # Per-variable CF attrs (units, standard_name, description) from the doc.
    vars = Pair{String,EarthSciIO.OutputVar}[]
    for g in s.gridding
        odims = output_var_dims(g, s.time_dim)                    # time FIRST
        attrs = Dict{String,Any}(get(s.var_attrs, g.base, Dict{String,Any}()))
        push!(vars, g.base => EarthSciIO.OutputVar(odims, Float64; attrs = attrs))
    end

    # CF dimension coordinates (§8.3): name == dim, 1-D values + standard_name/units/axis.
    coords = Pair{String,Tuple{Vector,Dict{String,Any}}}[]
    for c in s.coords
        push!(coords, c.name => (c.values, c.attrs))
    end

    # Default chunk/shard: whole spatial extent per chunk (one map per read); time
    # inner-chunk = 1 record, shard packs `records_per_shard` records per object.
    chunk = Dict{String,Int}(); shard = Dict{String,Int}()
    for (nm, len) in dims
        if nm == s.time_dim
            chunk[nm] = 1
            shard[nm] = max(1, s.records_per_shard)
        else
            chunk[nm] = len
            shard[nm] = len
        end
    end

    schema = EarthSciIO.OutputSchema(; dims = dims, time_dim = s.time_dim, vars = vars,
                                     coords = coords,
                                     chunk_shape = chunk, shard_shape = shard,
                                     profile = s.profile)
    # The registry is the discovery seam (WRITER_REGISTRY["zarr"] is :active); the
    # binding knows it wants zarr, so it constructs the writer directly.
    s.writer = EarthSciIO.ZarrWriter()
    s.handle = EarthSciIO.write_open!(s.writer, nothing, s.base_url, schema)
    return s
end

function sink_write!(s::ZarrSink, snap::StateSnapshot; selection = nothing)
    selection === nothing || throw(OutputError(
        "ZarrSink: `selection`/partial writes are inert in v1 (host-gather delivers " *
        "the whole state as a single offset-0 slab)"))
    s.handle === nothing && throw(OutputError(
        "ZarrSink.sink_write! before sink_open!; open the sink first"))
    isempty(snap.state) && throw(OutputError("ZarrSink: empty StateSnapshot.state"))
    u = snap.state[1][1]::AbstractArray            # v1: the whole flat state, offset 0
    arrays = Dict{String,Any}()
    for g in s.gridding
        # A scalar's shape is `[]`, so this is a 0-d `Array{Float64,0}` — the
        # gridded array of a variable whose only on-disk axis is the record axis.
        grid = Array{Float64}(undef, Tuple(g.shape))
        scatter_grid!(grid, g, u)
        arrays[g.base] = grid
    end
    EarthSciIO.write_record!(s.writer, s.handle, snap.t, arrays)
    return nothing
end

# The checkpoint durable barrier (RFC §10, §16.7): force any buffered records out
# as a durable partial shard + refresh the output manifest, so a restart reading the
# manifest sees everything written so far as committed. A no-op before open or with
# an empty buffer (already durable, e.g. records_per_shard = 1).
function sink_flush!(s::ZarrSink)
    s.handle === nothing && return nothing
    EarthSciIO.write_flush!(s.writer, s.handle)
    return nothing
end

function sink_close!(s::ZarrSink)
    s.handle === nothing && return nothing
    s.manifest = EarthSciIO.write_close!(s.writer, s.handle)
    return s.manifest
end

# --------------------------------------------------------------------------- #
# zarr_restart_state — the manifest-driven restart read (RFC §10, §16.7). The
# inverse direction of the sink: read the last committed checkpoint slab back into
# a flat `u0`. Uses the SAME `derive_output_gridding(var_map, meta)` the sink wrote
# with, so the flat↔gridded scatter/gather are exact inverses.
# --------------------------------------------------------------------------- #

function zarr_restart_state(prep, base_url::AbstractString; cache_dir = nothing)
    meta = prep.output_meta
    gridding = derive_output_gridding(prep.var_map, meta)
    base = EarthSciIO._output_base(String(base_url))

    man = EarthSciIO.read_output_manifest(joinpath(base, "output_manifest.json"))
    man === nothing && throw(OutputError(
        "no output manifest under $base; nothing to restart from (was the store " *
        "opened by a ZarrSink and at least one shard committed?)"))
    man.last_t === nothing && throw(OutputError(
        "output manifest at $base has no committed record (last_t is null); a shard " *
        "must commit — via a full shard, sink_flush!, or sink_close! — before restart"))
    nrec = man.n_records
    nrec >= 1 || throw(OutputError("output manifest reports 0 committed records"))

    cd = cache_dir === nothing ? joinpath(base, "_restart_cache") : String(cache_dir)
    cache = EarthSciIO.Cache(EarthSciIO.LocalStore(cd); offline = false)
    varnames = String[g.base for g in gridding]
    nds = EarthSciIO.read_store(EarthSciIO.ZarrReader(), cache, base_url;
                                variables = varnames)

    u0 = zeros(Float64, length(prep.var_map))
    tname = meta.time_dim
    for g in gridding
        v = nds.variables[g.base]
        tdim = findfirst(==(tname), v.dims)
        tdim === nothing && throw(OutputError(
            "restart: variable '$(g.base)' has no '$tname' axis (dims $(v.dims))"))
        # last COMMITTED time index (1-based); the array may be longer only if a
        # crash left an uncommitted shape bump, so clamp to the manifest count.
        ti = min(nrec, size(v.data, tdim))
        # Slice with a length-1 RANGE and drop the axis, so a scalar variable
        # (dims == [time_dim], rank 1) yields a 0-d array rather than a bare
        # Float64 that `gather_flat!` could not accept.
        slab = dropdims(v.data[ntuple(d -> d == tdim ? (ti:ti) : Colon(),
                                      ndims(v.data))...]; dims = tdim)
        # reorder the sliced spatial slab into the gridding's dim order if the reader
        # returned the axes in a different order (robust to dim reordering).
        spatial = String[d for d in v.dims if d != tname]
        if spatial != g.dimnames
            perm = Int[findfirst(==(dn), spatial) for dn in g.dimnames]
            any(isnothing, perm) && throw(OutputError(
                "restart: variable '$(g.base)' on-disk dims $(spatial) do not match " *
                "the model gridding dims $(g.dimnames)"))
            slab = permutedims(slab, perm)
        end
        gather_flat!(u0, g, slab)
    end
    return (Float64(man.last_t), u0)
end

end # module
