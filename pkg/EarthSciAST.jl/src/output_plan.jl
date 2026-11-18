# The output plan (streaming-output-sinks RFC §7–§9): the shape, names and
# metadata a writer lays the flat state out in, derived from a `var_map` and the
# run document. Checked across bindings by the output-derivation conformance
# corpus (`test/output_derivation_conformance_test.jl`).

# --------------------------------------------------------------------------- #
# Flat→gridded inversion (RFC §7). The shared, language-neutral piece: invert the
# column-major `name[i,j]` cell-key scheme (`_parse_cell_key`) so a flat `u` slab
# scatters into per-variable gridded arrays. Pure EarthSciAST (no EarthSciIO), so
# the same derivation feeds any Writer backend and can be specified once in the
# shared conformance spec.
#
# Dimension NAMES start POSITIONAL (`<base>_d0`, …) and are bound to their real
# `index_sets` names + the `coordinates` registry (CF metadata) by the
# doc-aware method below, which takes an [`OutputMeta`](@ref).
# --------------------------------------------------------------------------- #

"""
    VarGridding

The gridded layout of one output base-variable, derived from a flat `var_map`
(RFC §7). Scatter a flat state vector `u` into this variable's gridded array with
`grid[cart[k]] = u[flat_indices[k]]` — placement is by explicit `CartesianIndex`,
so it is correct regardless of enumeration order.

* `base::String` — the variable's base name (the cell key minus its `[…]`).
* `shape::Vector{Int}` — the gridded spatial shape. **Empty** for a scalar
  variable: a scalar is genuinely 0-spatial-dimensional, its gridded array is a
  0-d `Array{Float64,0}`, and its on-disk dims are exactly `[time_dim]` (RFC
  §16.12; see the reconciliation note there).
* `dimnames::Vector{String}` — one positional dim name per axis of `shape`
  (`"<base>_d0"`, …), replaced by the real `index_sets` names once an
  [`OutputMeta`](@ref) has been applied. Empty for a scalar.
* `flat_indices::Vector{Int}` — the flat `u` indices of this variable's cells.
* `cart::Vector{CartesianIndex}` — the 1-based grid position of each
  `flat_indices` entry (same order); `CartesianIndex()` for a scalar.
"""
struct VarGridding
    base::String
    shape::Vector{Int}
    dimnames::Vector{String}
    flat_indices::Vector{Int}
    cart::Vector{CartesianIndex}
end

"""
    derive_output_gridding(var_map) -> Vector{VarGridding}

Invert the flat `var_map` (state-element name → flat index) into one
[`VarGridding`](@ref) per output base-variable (RFC §7). Groups the cell keys by
base name via [`_parse_cell_key`](@ref) (a key with no `[…]` suffix is a scalar
variable), derives each axis length as the max cell index along that axis, and
records the flat-index → `CartesianIndex` scatter map. Base-variable order is the
first-seen order in `var_map`'s iteration, made deterministic by sorting on the
base name so the derived schema is reproducible.

A gridded variable's cells must be **dense**: exactly one cell per grid position.
An incomplete grid (a hole, which would leave an uninitialized value on disk) or a
double-covered one (which would silently drop a cell) is an [`OutputError`](@ref),
not a silent mis-write.
"""
function derive_output_gridding(var_map::AbstractDict)
    groups = Dict{String, Vector{Tuple{Int, Vector{Int}}}}()  # base => [(flat_idx, indices)]
    for (key, idx) in var_map
        parsed = _parse_cell_key(String(key))
        base, inds = parsed === nothing ? (String(key), Int[]) : parsed
        push!(get!(groups, base, Tuple{Int, Vector{Int}}[]), (Int(idx), inds))
    end
    out = VarGridding[]
    for base in sort!(collect(keys(groups)))
        entries = groups[base]
        ndim = maximum(length(e[2]) for e in entries)
        if ndim == 0
            length(entries) == 1 || throw(
                OutputError(
                    "scalar variable '$base' maps to $(length(entries)) flat indices; a " *
                        "scalar cell key must be unique"
                )
            )
            fi = entries[1][1]
            # A scalar carries NO spatial axis: shape `[]`, no dim names, a 0-d
            # grid. See the `VarGridding` docstring and RFC §16.12.
            push!(out, VarGridding(base, Int[], String[], [fi], [CartesianIndex()]))
        else
            shape = zeros(Int, ndim)
            for (_, inds) in entries
                length(inds) == ndim || throw(
                    OutputError(
                        "variable '$base' has cells of differing dimensionality " *
                            "($(length(inds)) vs $ndim); a gridded variable must be rectangular"
                    )
                )
                @inbounds for d in 1:ndim
                    inds[d] >= 1 || throw(
                        OutputError(
                            "variable '$base' has cell index 0 on axis $(d - 1); cell keys " *
                                "are 1-based"
                        )
                    )
                    shape[d] = max(shape[d], inds[d])
                end
            end
            flat = Int[e[1] for e in entries]
            cart = CartesianIndex[CartesianIndex(Tuple(e[2])...) for e in entries]
            _check_dense(base, shape, cart)
            dimnames = String["$(base)_d$(d - 1)" for d in 1:ndim]
            push!(out, VarGridding(base, shape, dimnames, flat, cart))
        end
    end
    return out
end

# The grid must be covered exactly once. Without this a gap left an uninitialized
# hole in the written array and a repeated cell silently dropped a flat slot —
# both are wrong science written out as if it were right.
function _check_dense(
        base::AbstractString, shape::Vector{Int},
        cart::Vector{CartesianIndex}
    )
    total = prod(shape)
    length(cart) == total || throw(
        OutputError(
            "variable '$base' supplies $(length(cart)) cell(s) for a $shape grid of " *
                "$total; a gridded output variable must be dense"
        )
    )
    lin = LinearIndices(Tuple(shape))
    seen = falses(total)
    for c in cart
        o = lin[c]
        seen[o] && throw(
            OutputError(
                "variable '$base' maps two flat slots to grid cell $(collect(Tuple(c)))"
            )
        )
        seen[o] = true
    end
    return nothing
end

"""
    row_major_flat_indices(g::VarGridding) -> Vector{Int}

`g`'s flat state indices re-expressed as a dense vector indexed by ROW-MAJOR
(C-order) offset within `g.shape`, with the column-major → row-major
transposition already applied — the layout a Zarr writer's buffer wants, and the
representation `earthsci-ast-rs`'s `VarGridding::flat_indices` stores natively.
Length is `prod(g.shape)` (1 for a scalar). Indices stay 1-based, as everywhere
else in Julia.

This is what lets the two bindings be compared on ONE representation in the
cross-language derivation corpus (`tests/conformance/output_derivation/`).
"""
function row_major_flat_indices(g::VarGridding)
    n = prod(g.shape)
    out = zeros(Int, n)
    nd = length(g.shape)
    for k in eachindex(g.flat_indices)
        c = g.cart[k]
        off = 0
        @inbounds for d in 1:nd
            off = off * g.shape[d] + (c[d] - 1)
        end
        out[off + 1] = g.flat_indices[k]
    end
    return out
end

"""
    scatter_grid!(grid, g::VarGridding, u) -> grid

Scatter the flat state `u` into the pre-allocated gridded `grid` for variable
`g`: `grid[cart[k]] = u[flat_indices[k]]`. `grid` must have size `Tuple(g.shape)`
— for a scalar that is the 0-d `Array{Float64}(undef)`, whose single element
`CartesianIndex()` addresses.
"""
function scatter_grid!(grid::AbstractArray, g::VarGridding, u::AbstractVector)
    @inbounds for k in eachindex(g.flat_indices)
        grid[g.cart[k]] = u[g.flat_indices[k]]
    end
    return grid
end

"""
    gather_flat!(u, g::VarGridding, grid) -> u

The inverse of [`scatter_grid!`](@ref): read a variable's gridded `grid` back into
the flat state `u`, `u[flat_indices[k]] = grid[cart[k]]`. This is the restart-read
direction (streaming-output-sinks RFC §10, §16.7) — reconstruct a flat `u0` from a
checkpoint store's gridded arrays. `grid` must have size `Tuple(g.shape)`.
"""
function gather_flat!(u::AbstractVector, g::VarGridding, grid::AbstractArray)
    @inbounds for k in eachindex(g.flat_indices)
        u[g.flat_indices[k]] = grid[g.cart[k]]
    end
    return u
end

# --------------------------------------------------------------------------- #
# Output metadata (RFC §7, §8). The flat `var_map` gives SHAPE (§7); the
# run document gives the REAL axis NAMES (a variable's declared `shape` = ordered
# index-set names), the per-axis sizes (`index_sets`), the per-variable CF attrs
# (`units`, …), and the additive `coordinates` registry (§8.3). `OutputMeta`
# distills exactly that slice of the run doc so a sink emits `lon`/`lat` dims (not
# positional `<base>_d0`) and CF dimension-coordinates, WITHOUT the sink or the
# writer importing the document model. Built once by [`derive_output_meta`] in
# `esm_problem` (the doc is in scope there; `EsmProblem` carries the result).
# --------------------------------------------------------------------------- #

"""
    OutputMeta

The document-derived output metadata carried by an [`EsmProblem`](@ref) so a
streaming sink can name axes and emit CF coordinates (RFC §7–§8). Distilled from
the flattened run document by [`derive_output_meta`](@ref).

* `model_name::String` — the first flattened model's key (namespacing prefix of
  the `var_map`'s base names).
* `index_sets::Dict{String,Int}` — index-set name → axis length (interval `size`;
  categorical member count).
* `var_dims::Dict{String,Vector{String}}` — base variable name → its declared
  `shape` (ordered index-set / dim names). Absent for scalars. Keyed by BOTH the
  bare name and its `Model.`-qualified form, because a flat state's element names
  are namespaced on the coupled/flattened path and bare on the single-model path;
  a bare name two models would make ambiguous is dropped, so an ambiguous lookup
  falls back to positional axis names rather than guessing.
* `var_attrs::Dict{String,Dict{String,Any}}` — base variable name → CF variable
  attributes retained from the doc (`units`, `standard_name`, `description` when
  present). Keyed like `var_dims`.
* `var_types::Dict{String,String}` — base variable name → its DERIVED kind
  (`"observed"` for an unknown a bare-variable-LHS equation defines, else the
  declared `"unknown"` / `"parameter"`), so observed fields can be gated on the
  caller's request list (RFC decision 8). Derived rather than read off the
  declaration because esm 1.0.0 declares only two types (esm-spec §6.3.1).
  Keyed like `var_dims`.
* `coordinates::Dict{String,Any}` — the additive `coordinates` registry (§8.3),
  verbatim: entry name → `{values|source, standard_name, units, axis}`. Empty when
  the document declares none.
* `time_dim::String` — the record-axis name: the document's
  `domain.independent_variable` (RFC §7), falling back to `"time"`.
"""
struct OutputMeta
    model_name::String
    index_sets::Dict{String, Int}
    var_dims::Dict{String, Vector{String}}
    var_attrs::Dict{String, Dict{String, Any}}
    var_types::Dict{String, String}
    coordinates::Dict{String, Any}
    time_dim::String
end

"Fallback record-axis name when the document declares no `independent_variable`."
const DEFAULT_TIME_DIM = "time"

# Look `base` up in one of the `var_*` tables: exact first (bare or namespaced),
# then the last dotted segment — so a nested namespace the exact keys do not
# cover still resolves.
function _meta_lookup(table::AbstractDict, base::AbstractString)
    haskey(table, base) && return table[base]
    bare = last(split(base, '.'))
    bare == base && return nothing
    return get(table, String(bare), nothing)
end

# Static axis length of an index set: interval `size`; categorical member count;
# 0 (unknown here) for a derived or ragged set whose extent needs the build.
function _index_set_axis_len(is::IndexSet)
    if is.kind == "interval"
        return something(is.size, 0)
    elseif is.kind == "categorical"
        return is.members === nothing ? 0 : length(is.members)
    else
        return something(is.size, 0)
    end
end

"""
    derive_output_meta(file::EsmFile) -> OutputMeta
    derive_output_meta(doc::AbstractDict) -> OutputMeta

Distill the flattened run document into [`OutputMeta`](@ref): the model names, the
`index_sets` axis lengths, each variable's declared `shape` (real dim names) +
retained CF attrs + declared kind, the additive `coordinates` registry (§8.3), and
the record-axis name (`domain.independent_variable`). Returns an empty
`OutputMeta` for a document with no `models` (nothing to name). Reads only the
document — no build artifacts — so it composes with `derive_output_gridding`. A
native document is coerced first.

Variable tables are keyed by BOTH the bare name and its `Model.`-qualified form,
so a namespaced flat state (`Model.u[…]`) resolves its real dim names instead of
silently falling back to positional ones. A bare name claimed by more than one
model is ambiguous and only the qualified key survives.
"""
function derive_output_meta(doc::AbstractDict)
    meta = derive_output_meta(coerce_esm_file(doc))
    # The `coordinates` registry and the independent variable as the document
    # writes them: coercion does not keep the first, and an authored
    # `independent_variable` names the record axis even when it is `t`.
    coords = get(doc, "coordinates", nothing)
    dom = get(doc, "domain", nothing)
    iv = dom isa AbstractDict ? get(dom, "independent_variable", nothing) : nothing
    return OutputMeta(
        meta.model_name, meta.index_sets, meta.var_dims, meta.var_attrs, meta.var_types,
        coords isa AbstractDict ? Dict{String, Any}(String(k) => v for (k, v) in coords) :
            Dict{String, Any}(),
        iv === nothing ? DEFAULT_TIME_DIM : String(iv)
    )
end

function derive_output_meta(file::EsmFile)
    idx = Dict{String, Int}(k => _index_set_axis_len(is) for (k, is) in file.index_sets)
    cdict = file.coordinates === nothing ? Dict{String, Any}() :
        Dict{String, Any}(String(k) => v for (k, v) in file.coordinates)
    # The domain's independent variable names the record axis; the default `t`
    # (which a run document does not spell out) falls back to `"time"`.
    iv = file.domain === nothing ? "t" : file.domain.independent_variable
    tdim = iv == "t" ? DEFAULT_TIME_DIM : iv
    models = file.models
    (models === nothing || isempty(models)) && return OutputMeta(
        "", idx, Dict{String, Vector{String}}(), Dict{String, Dict{String, Any}}(),
        Dict{String, String}(), cdict, tdim
    )
    mnames = sort!(String[String(k) for k in keys(models)])
    sname = mnames[1]

    # A bare variable name claimed by two models cannot disambiguate a flat base
    # name, so only the qualified key is registered for it.
    bare_counts = Dict{String, Int}()
    for mn in mnames, vn in keys(models[mn].variables)
        bare_counts[vn] = get(bare_counts, vn, 0) + 1
    end

    vdims = Dict{String, Vector{String}}()
    vattrs = Dict{String, Dict{String, Any}}()
    vtypes = Dict{String, String}()
    for mn in mnames
        model = models[mn]
        observed = _output_observed_names(model)
        for vn in sort!(collect(String, keys(model.variables)))
            v = model.variables[vn]
            keys_for_var = String["$mn.$vn"]
            get(bare_counts, vn, 0) > 1 || push!(keys_for_var, vn)
            a = Dict{String, Any}()
            v.units === nothing || (a["units"] = v.units)
            v.description === nothing || (a["description"] = v.description)
            # The kind recorded here is the DERIVED role, not the declared type
            # (esm-spec §6.3.1). From esm 1.0.0 every solved-for quantity
            # declares `type: "unknown"`, so gating observed output on the
            # declared string would gate on a constant and write every observed
            # unconditionally. An unknown DEFINED by a bare-variable-LHS
            # equation is the observed one.
            vt = vn in observed ? "observed" : serialize_model_variable_type(v.type)
            for key in keys_for_var
                v.shape === nothing || (vdims[key] = copy(v.shape))
                isempty(a) || (vattrs[key] = copy(a))
                vtypes[key] = vt
            end
        end
    end

    return OutputMeta(sname, idx, vdims, vattrs, vtypes, cdict, tdim)
end

# The OBSERVED unknowns of `model`: those an equation defines with a
# bare-variable left-hand side (esm-spec §6.3.1).
function _output_observed_names(model::Model)
    out = Set{String}()
    for eq in model.equations
        eq.lhs isa VarExpr || continue
        name = (eq.lhs::VarExpr).name
        v = get(model.variables, name, nothing)
        (v !== nothing && serialize_model_variable_type(v.type) == "unknown") && push!(out, name)
    end
    return out
end

"""
    derive_output_gridding(var_map, meta::OutputMeta) -> Vector{VarGridding}

Doc-aware [`derive_output_gridding`](@ref): first invert the flat `var_map`
(shape + scatter map, the language-neutral core), then rename each variable's axes
from positional `<base>_d0` to its REAL declared dim names via `meta.var_dims`
(RFC §7 → §8). A variable with no declared `shape` in `meta` (a scalar, or a
`var_map` built without a document) keeps its positional names. Validates that the
declared dim count and each `index_sets` length agree with the shape recovered
from the flat state — a mismatch means the document and the built state disagree,
which must fail loudly rather than mislabel an axis.
"""
function derive_output_gridding(var_map::AbstractDict, meta::OutputMeta)
    return VarGridding[_name_gridding(g, meta) for g in derive_output_gridding(var_map)]
end

function _name_gridding(g::VarGridding, meta::OutputMeta)
    dims = _meta_lookup(meta.var_dims, g.base)
    dims === nothing && return g                      # scalar / undeclared → positional
    length(dims) == length(g.shape) || throw(
        OutputError(
            "output metadata for '$(g.base)' declares $(length(dims)) dim(s) $(dims), but the " *
                "flat state grids it to $(length(g.shape)) axis/axes $(g.shape)"
        )
    )
    for d in eachindex(dims)
        sz = get(meta.index_sets, dims[d], nothing)
        (sz === nothing || sz == 0 || sz == g.shape[d]) || throw(
            OutputError(
                "output metadata: '$(g.base)' axis $d is index set '$(dims[d])' of size $sz, " *
                    "but the flat state grids that axis to length $(g.shape[d])"
            )
        )
    end
    return VarGridding(g.base, g.shape, copy(dims), g.flat_indices, g.cart)
end

"""
    group_gridding_by_grid(gridding) -> Vector{Vector{VarGridding}}

Partition output variables into GRIDS by their spatial-dim signature (RFC §9):
variables that live on the same set of axes form one grid, so an atmosphere over
`[lev, lat, lon]` and an ocean over `[depth, lat, lon]` split into two grids by
construction (grids are emergent, not declared). The signature is the SORTED set of
a variable's `dimnames`, so axis order does not fragment a grid and every scalar
(empty signature) lands in ONE shared 0-D grid. Groups come back in
first-seen signature order (deterministic). One Sink per returned group is the RFC's
recommended multi-grid decomposition — each grid gets its own cadence, chunking, and
checkpoint frequency; restrict a sink to a grid's variables via `build_zarr_sink`'s
`variables` keyword.
"""
function group_gridding_by_grid(gridding::AbstractVector{VarGridding})
    order = Vector{String}[]
    groups = Dict{Vector{String}, Vector{VarGridding}}()
    for g in gridding
        sig = sort(collect(String, g.dimnames))
        haskey(groups, sig) || push!(order, sig)
        push!(get!(groups, sig, VarGridding[]), g)
    end
    return Vector{VarGridding}[groups[sig] for sig in order]
end

"""
    DimCoord(name, values, attrs)

A CF **dimension coordinate** (§8.3): a 1-D coordinate variable named exactly like
its dimension, its monotonic `values`, and its CF `attrs` (`standard_name` /
`units` / `axis`). Emitted once at [`sink_open!`](@ref). Auxiliary (unstructured /
curvilinear) coordinates — whose registry key differs from the dim name and whose
values come from a `source` array — are a later drop-in on the same registry; v1
emits inline-`values` dimension coordinates.
"""
struct DimCoord
    name::String
    values::Vector{Float64}
    attrs::Dict{String, Any}
end

"""
    plan_dimension_coordinates(gridding, meta::OutputMeta) -> Vector{DimCoord}

Resolve the `coordinates` registry (§8.3) into the CF **dimension coordinates**
for a set of [`VarGridding`](@ref)s: for each distinct spatial dim, if the registry
has an entry KEYED BY THAT DIM NAME carrying inline `values`, emit a [`DimCoord`](@ref)
(validating its length against the dim's grid length) with the entry's
`standard_name`/`units`/`axis` attrs. Registry entries whose key is not a dim name
(auxiliary coordinates) and `source`-backed entries are skipped in v1 (the
dimension-coordinate path handles inline values); they are the documented next
drop-in. Dims with no registry entry emit no coordinate (bare integer axis, as before).
"""
function plan_dimension_coordinates(gridding::AbstractVector{VarGridding}, meta::OutputMeta)
    dimlen = Dict{String, Int}()
    order = String[]
    for g in gridding, d in eachindex(g.dimnames)
        nm = g.dimnames[d]
        haskey(dimlen, nm) || push!(order, nm)
        dimlen[nm] = g.shape[d]
    end
    coords = DimCoord[]
    for nm in order
        entry = get(meta.coordinates, nm, nothing)
        entry isa AbstractDict || continue
        vals = get(entry, "values", nothing)
        vals isa AbstractVector || continue           # source/aux: not the inline-dim path
        v = Float64[Float64(x) for x in vals]
        length(v) == dimlen[nm] || throw(
            OutputError(
                "coordinate '$nm' supplies $(length(v)) value(s) but dimension '$nm' has " *
                    "length $(dimlen[nm])"
            )
        )
        attrs = Dict{String, Any}()
        for k in ("standard_name", "units", "axis")
            haskey(entry, k) && entry[k] !== nothing && (attrs[k] = entry[k])
        end
        push!(coords, DimCoord(nm, v, attrs))
    end
    return coords
end

# --------------------------------------------------------------------------- #
# The output PLAN (RFC §7–§9). The single source of truth for the shape a writer
# is handed: which grids exist, each grid's ordered dims and CF coordinates, and
# each variable's ON-DISK dimension list. `ZarrSink` builds its `OutputSchema`
# from a `GridPlan` rather than assembling one itself, and the cross-language
# derivation conformance corpus (`tests/conformance/output_derivation/`) compares
# exactly this structure against `earthsci-ast-rs`'s `OutputPlan`, so the two
# derivations cannot drift apart unnoticed (RFC §16.12).
#
# DIMENSION ORDER: the record axis comes FIRST, then the variable's spatial axes
# — CF's T,Z,Y,X recommendation, the order EarthSciIO's shared write-conformance
# spec already pins, the order a NetCDF record dimension requires, and the order
# that keeps one appended record contiguous on disk.
# --------------------------------------------------------------------------- #

"""
    VarPlan(name, dims, attrs, dtype, gridding)

One output variable as a writer sees it: the on-disk `name`, its ordered on-disk
`dims` (record axis first, then spatial axes — a scalar's dims are exactly
`[time_dim]`), the CF `attrs` retained from the document, the element `dtype`, and
the [`VarGridding`](@ref) that scatters a flat state into it.
"""
struct VarPlan
    name::String
    dims::Vector{String}
    attrs::Dict{String, Any}
    dtype::String
    gridding::VarGridding
end

"""
    GridPlan(dims, time_dim, coords, vars)

One emergent grid (RFC §9): the ordered SPATIAL `dims` (`name => length`; empty
for the scalar grid — the record axis is not included, see `time_dim`), the
record-axis name, the grid's CF dimension [`DimCoord`](@ref)s, and its
[`VarPlan`](@ref)s. The record COUNT is deliberately not part of the plan: a plan
is derived once and stays valid however many records get written.
"""
struct GridPlan
    dims::Vector{Pair{String, Int}}
    time_dim::String
    coords::Vector{DimCoord}
    vars::Vector{VarPlan}
end

"""
    OutputPlan(grids)

The full derived output plan: one [`GridPlan`](@ref) per emergent grid, in
first-seen signature order.
"""
struct OutputPlan
    grids::Vector{GridPlan}
end

"The element type of every output array; the flat solver state is `Float64`."
const DTYPE_FLOAT64 = "float64"

"""
    derive_output_plan(doc, var_map; observed = String[]) -> OutputPlan
    derive_output_plan(var_map, meta::OutputMeta; observed = String[]) -> OutputPlan

Derive the whole output plan for a run (RFC §7–§9) — the Julia mirror of
`earthsci_ast::data_output::derive_output_plan`.

* `doc` — the (flattened) run document: axis names, axis lengths, CF attributes,
  the `coordinates` registry, and the record-axis name.
* `var_map` — the flat state-element name → flat index map.
* `observed` — the caller-named observed/derived fields to write alongside the
  state (RFC decision 8): output is the state PLUS these, not every observed
  field. A name selects the variable it names exactly; failing that, the ONE
  variable whose last dotted segment equals the name's (so `flux` selects
  `Box.flux`). A name whose last segment several variables share is refused with
  code `ambiguous_output_name`, and a name with no slot in the flat state is
  refused too — silently dropping or silently choosing a requested output is
  worse than refusing. A name an `operator_compose` merge deleted is NOT resolved
  here: the caller resolves it through `merged_variable_renames` first
  (CONFORMANCE_SPEC §5.17.4).
"""
function derive_output_plan(
        doc::AbstractDict, var_map::AbstractDict;
        observed = String[]
    )
    return derive_output_plan(var_map, derive_output_meta(doc); observed = observed)
end

function derive_output_plan(
        var_map::AbstractDict, meta::OutputMeta;
        observed = String[]
    )
    gridding = derive_output_gridding(var_map, meta)

    requested = _resolve_output_requests(observed, String[g.base for g in gridding])
    kept = VarGridding[
        g for g in gridding
            if _meta_lookup(meta.var_types, g.base) != "observed" ||
            g.base in requested
    ]

    return OutputPlan(
        GridPlan[
            _build_grid_plan(grp, meta)
                for grp in group_gridding_by_grid(kept)
        ]
    )
end

_last_segment(name::AbstractString) = String(last(split(name, '.')))

# The variable bases the `observed` request names (CONFORMANCE_SPEC §5.17.4):
# the exact base, else the ONE base sharing the request's last dotted segment.
# Mirrors `match_output_request` in `earthsci-ast-rs/src/data_output.rs`.
function _resolve_output_requests(observed, bases::Vector{String})
    selected = Set{String}()
    for req in observed
        name = String(req)
        if name in bases
            push!(selected, name)
            continue
        end
        tail = _last_segment(name)
        hits = sort!(unique!([b for b in bases if _last_segment(b) == tail]))
        if length(hits) == 1
            push!(selected, only(hits))
        elseif isempty(hits)
            throw(
                OutputError(
                    "requested observed output '$name' has no slot in the flat state; the " *
                        "runner must evaluate and append it before the plan is derived"
                )
            )
        else
            throw(
                OutputError(
                    "requested output '$name' names no variable exactly, and its last " *
                        "segment '$tail' is shared by $(join(hits, ", ")); name one of them " *
                        "in full", ERROR_CODES.AMBIGUOUS_OUTPUT_NAME
                )
            )
        end
    end
    return selected
end

function _build_grid_plan(group::Vector{VarGridding}, meta::OutputMeta)
    dims = Pair{String, Int}[]
    owner = Dict{String, String}()
    for g in group, d in eachindex(g.dimnames)
        nm = g.dimnames[d]
        nm == meta.time_dim && throw(
            OutputError(
                "variable '$(g.base)' has a spatial dimension named '$nm', which collides " *
                    "with the record axis"
            )
        )
        k = findfirst(p -> first(p) == nm, dims)
        if k === nothing
            push!(dims, nm => g.shape[d])
            owner[nm] = g.base
        elseif last(dims[k]) != g.shape[d]
            throw(
                OutputError(
                    "dimension '$nm' has length $(last(dims[k])) on variable " *
                        "'$(owner[nm])' but length $(g.shape[d]) on variable '$(g.base)'"
                )
            )
        end
    end

    coords = plan_dimension_coordinates(group, meta)
    vars = VarPlan[]
    for g in group
        attrs = _meta_lookup(meta.var_attrs, g.base)
        push!(
            vars, VarPlan(
                g.base, output_var_dims(g, meta.time_dim),
                attrs === nothing ? Dict{String, Any}() : copy(attrs),
                DTYPE_FLOAT64, g
            )
        )
    end
    return GridPlan(dims, meta.time_dim, coords, vars)
end

"""
    output_var_dims(g::VarGridding, time_dim) -> Vector{String}

One variable's ON-DISK dimension list: the record axis first, then its spatial
axes. A scalar's dims are exactly `[time_dim]`. The single place this order is
decided — see the section comment above for why the record axis leads.
"""
output_var_dims(g::VarGridding, time_dim::AbstractString) =
    String[String(time_dim), g.dimnames...]
