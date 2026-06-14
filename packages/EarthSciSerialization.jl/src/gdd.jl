# GDD (GridDiscretization Descriptor) loading and grid_refs resolution.
# Implements esm-spec.md §4.7.1 and the grid_refs sweep described in §6.6.2 / §6.7.2.

"""
    resolve_grid_refs(esm, grid_refs, base_path; kwargs...) -> Vector{Dict{String,Any}}

For each `{ref}` string in `grid_refs`, load the referenced GDD file, apply its
`grids` and `discretizations` overrides to `esm`, and run `discretize()`.

Returns a `Vector` of `N` discretized ESM `Dict{String,Any}` objects — one per
`grid_refs` entry — ready for `build_evaluator` or further processing.

`base_path` is the directory used to resolve relative GDD paths (typically the
directory of the ESM file that contains the test).

Keyword arguments are forwarded to `discretize()`.
"""
function resolve_grid_refs(esm::AbstractDict, grid_refs::AbstractVector{<:AbstractString},
                           base_path::AbstractString;
                           max_passes::Int = 32,
                           strict_unrewritten::Bool = true,
                           dae_support::Bool = _default_dae_support(),
                           lift_1d_arrayop::Bool = false)::Vector{Dict{String,Any}}
    isempty(grid_refs) && return Dict{String,Any}[]
    esm_native = _deep_native(esm)
    results = Dict{String,Any}[]
    for ref in grid_refs
        visited = Set{String}()   # fresh cycle-detection set per GDD
        gdd = _load_gdd_file(String(ref), String(base_path), visited)
        esm_mod = _apply_gdd_to_esm(esm_native, gdd)
        disc = discretize(esm_mod; max_passes = max_passes,
                          strict_unrewritten = strict_unrewritten,
                          dae_support = dae_support,
                          lift_1d_arrayop = lift_1d_arrayop)
        push!(results, disc)
    end
    return results
end

"""
    _load_gdd_file(ref, base_path, visited) -> Dict{String,Any}

Load a GDD file from `ref` (local path or https:// URL) relative to `base_path`.
Returns the raw `Dict{String,Any}` payload. Validates that `kind ==
"grid_discretization_descriptor"`. Uses `visited` to detect circular references
(shared with the subsystem-ref resolver's visited set when called from there).
"""
function _load_gdd_file(ref::String, base_path::String,
                        visited::Set{String})::Dict{String,Any}
    canonical = _canonical_ref(ref, base_path)
    if canonical in visited
        throw(SubsystemRefError("Circular GDD reference detected: $canonical"))
    end
    push!(visited, canonical)

    if startswith(ref, "http://") || startswith(ref, "https://")
        throw(SubsystemRefError(
            "HTTP/HTTPS GDD refs are not supported; " *
            "use a local file path instead (ref='$ref')"))
    end
    resolved = abspath(joinpath(base_path, ref))
    isfile(resolved) ||
        throw(SubsystemRefError(
            "GDD file not found: $resolved (from ref '$ref')"))
    raw_str = read(resolved, String)

    gdd = _deep_native(JSON3.read(raw_str))
    gdd isa Dict{String,Any} ||
        throw(SubsystemRefError("GDD file '$ref' did not parse as a JSON object"))

    kind = get(gdd, "kind", nothing)
    kind == "grid_discretization_descriptor" ||
        throw(SubsystemRefError(
            "File '$ref' is not a GridDiscretization Descriptor " *
            "(expected kind=\"grid_discretization_descriptor\", got " *
            (kind === nothing ? "no kind field" : "\"$kind\"") * ")"))

    # Resolve any {ref} entries in GDD's own discretizations block.
    gdd_discs = get(gdd, "discretizations", nothing)
    if gdd_discs isa Dict{String,Any} && !isempty(gdd_discs)
        gdd_base = dirname(abspath(joinpath(base_path, ref)))
        if !isempty(gdd_base)
            _resolve_discretization_refs!(gdd_discs, gdd_base, visited)
        end
    end

    return gdd
end

"""
    _apply_gdd_to_esm(esm, gdd) -> Dict{String,Any}

Deep-copy `esm` and overlay the GDD's `grids` and `discretizations` blocks.

- `gdd["grids"]`: each entry replaces the matching key in `esm["grids"]`.
- `gdd["discretizations"]`: each entry is merged into `esm["discretizations"]`,
  overriding any existing entry with the same name.
"""
function _apply_gdd_to_esm(esm::Dict{String,Any},
                            gdd::Dict{String,Any})::Dict{String,Any}
    result = deepcopy(esm)

    gdd_grids = get(gdd, "grids", nothing)
    if gdd_grids isa AbstractDict && !isempty(gdd_grids)
        if !haskey(result, "grids")
            result["grids"] = Dict{String,Any}()
        end
        grids_out = result["grids"]
        grids_out isa Dict{String,Any} ||
            (grids_out = result["grids"] = Dict{String,Any}(String(k) => v
                                                            for (k, v) in grids_out))
        for (gname, gspec) in gdd_grids
            grids_out[String(gname)] = gspec isa Dict{String,Any} ? gspec :
                Dict{String,Any}(String(k) => v for (k, v) in gspec)
        end
    end

    gdd_discs = get(gdd, "discretizations", nothing)
    if gdd_discs isa AbstractDict && !isempty(gdd_discs)
        if !haskey(result, "discretizations")
            result["discretizations"] = Dict{String,Any}()
        end
        discs_out = result["discretizations"]
        discs_out isa Dict{String,Any} ||
            (discs_out = result["discretizations"] = Dict{String,Any}(
                String(k) => v for (k, v) in discs_out))
        for (dname, dspec) in gdd_discs
            discs_out[String(dname)] = dspec isa Dict{String,Any} ? dspec :
                Dict{String,Any}(String(k) => v for (k, v) in dspec)
        end
    end

    return result
end
