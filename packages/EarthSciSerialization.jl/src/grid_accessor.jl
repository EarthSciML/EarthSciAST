# GridAccessor interface (gt-hvl4).
#
# This file defines the *interface* that concrete grid impls must satisfy
# for ESS to query grid geometry during discretization, tree-walk, and
# codegen. Concrete per-family implementations live in the
# EarthSciDiscretizations (ESD) binding per the 2026-04-22 grid-inversion
# decision: ESS owns the trait + registration hook; ESD owns the concrete
# subtypes and registers them on package init.
#
# Signature surface (per EarthSciDiscretizations/docs/GRIDS_API.md):
#   cell_centers(g, idx...)            — cell-center coordinates
#   neighbors(g, cell)                 — adjacent cells
#   metric_eval(g, name, idx...)       — named metric field (dx, dy, area, …)
#
# Index shape is family-dependent:
#   rectilinear 2D:     idx = (i, j)         cell = (i, j)
#   rectilinear 3D:     idx = (i, j, k)      cell = (i, j, k)
#   unstructured:       idx = (cell_id,)     cell = cell_id
#
# Options keys are snake_case on the wire (GRIDS_API.md §2.2); this file
# only defines the accessor surface, not the generator surface.

"""
    GridAccessor

Abstract supertype for grid-accessor types. Concrete subtypes live in the
ESD (EarthSciDiscretizations) binding and register themselves via
[`register_grid_accessor!`](@ref).

Concrete `T <: GridAccessor` must implement:

- [`cell_centers`](@ref)`(g::T, idx...)` — cell-center coordinate tuple
- [`neighbors`](@ref)`(g::T, cell)` — iterable of adjacent cells
- [`metric_eval`](@ref)`(g::T, name::AbstractString, idx...)` — metric field value
"""
abstract type GridAccessor end

"""
    GridAccessorError(message)

Thrown by the default (unimplemented) generic stubs and by
[`grid_accessor_factory`](@ref) / [`make_grid_accessor`](@ref) when a
family has no registered factory.
"""
struct GridAccessorError <: Exception
    message::String
end
Base.showerror(io::IO, e::GridAccessorError) = print(io, "GridAccessorError: ", e.message)

"""
    cell_centers(grid::GridAccessor, idx...)

Cell-center coordinates of the cell at `idx`. Return shape is
family-dependent (e.g. `(lon, lat)` for spherical families,
`(x, y, z)` for 3D cartesian).
"""
function cell_centers end

"""
    neighbors(grid::GridAccessor, cell)

Iterable of cells adjacent to `cell`. `cell` uses the index convention
matching the family's `cell_centers` signature.
"""
function neighbors end

"""
    metric_eval(grid::GridAccessor, name::AbstractString, idx...)

Value of the named metric field at `idx`. Valid names are family-defined
(typical: `"dx"`, `"dy"`, `"dz"`, `"area"`, `"volume"`). Implementations
throw [`GridAccessorError`](@ref) for unknown names.
"""
function metric_eval end

# Default unimplemented methods. Subtypes opt in by overriding these with
# more specific signatures; the fallbacks guarantee a clean error with the
# concrete type name instead of a bare `MethodError`.
cell_centers(g::GridAccessor, args...) =
    throw(GridAccessorError("cell_centers not implemented for $(typeof(g))"))
neighbors(g::GridAccessor, cell) =
    throw(GridAccessorError("neighbors not implemented for $(typeof(g))"))
metric_eval(g::GridAccessor, name::AbstractString, args...) =
    throw(GridAccessorError("metric_eval not implemented for $(typeof(g))"))

# ---------------------------------------------------------------------------
# Registration hook: ESD concrete impls call register_grid_accessor! on
# package init. ESS code dispatches into the registry by the RFC §6
# `family` string.
# ---------------------------------------------------------------------------

const _GRID_ACCESSOR_REGISTRY = Dict{String,Any}()

"""
    register_grid_accessor!(family, factory) -> previous_factory_or_nothing

Register `factory` as the constructor for grid family `family`. `factory`
is any callable `factory(grid_data) -> GridAccessor`, where `grid_data`
is the RFC §6 grid dict (e.g. `EsmFile.grids["g1"].data`).

Family names match the RFC §6 enum (`"cartesian"`, `"lat_lon"`,
`"stretched_lat_lon"`, `"mpas"`, `"duo"`).

Replacing an existing entry returns the previous factory. This is the
ESS → ESD handshake: ESS owns the trait + registry; ESD registers
concrete subtypes.
"""
function register_grid_accessor!(family::AbstractString, factory)
    key = String(family)
    prev = get(_GRID_ACCESSOR_REGISTRY, key, nothing)
    _GRID_ACCESSOR_REGISTRY[key] = factory
    return prev
end

"""
    unregister_grid_accessor!(family) -> Bool

Remove the factory for `family`. Returns `true` if removed, `false` if
none was registered.
"""
function unregister_grid_accessor!(family::AbstractString)
    return pop!(_GRID_ACCESSOR_REGISTRY, String(family), nothing) !== nothing
end

"""
    grid_accessor_factory(family) -> factory

Return the registered factory for `family`, or throw
[`GridAccessorError`](@ref) if none is registered.
"""
function grid_accessor_factory(family::AbstractString)
    f = get(_GRID_ACCESSOR_REGISTRY, String(family), nothing)
    f === nothing && throw(GridAccessorError(
        "no grid accessor registered for family '$(family)'; " *
        "ensure EarthSciDiscretizations (or an equivalent provider) is loaded"))
    return f
end

"""
    registered_grid_families() -> Vector{String}

Sorted list of grid families with a registered accessor.
"""
registered_grid_families() = sort!(collect(keys(_GRID_ACCESSOR_REGISTRY)))

"""
    make_grid_accessor(family, grid_data) -> GridAccessor

Construct a `GridAccessor` for `family` by dispatching to the registered
factory with `grid_data`.
"""
function make_grid_accessor(family::AbstractString, grid_data)
    return grid_accessor_factory(family)(grid_data)
end
