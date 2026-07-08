"""
MTK → ESM export scaffolder (Phase 1 migration tooling, gt-dod2).

This file defines the public stubs for `mtk2esm`, the forward-direction
serializer that walks a ModelingToolkit system and emits a schema-valid ESM
`Dict`. The real implementations live in the MTK and Catalyst extensions
because they require those packages to be loaded — this file only declares
the stubs, the `GapReport` type used to collect unsupported-construct
warnings, and the MTK-independent formatting helpers shared by both
extensions.

See `scripts/roundtrip.jl` for the validator CLI that exercises this path
as the EarthSciModels migration acceptance gate.
"""

"""
    GapReport

Structured record of schema-gap constructs encountered while exporting an
MTK system to ESM. The migration tool uses these to attach `TODO_GAP`
notes and to emit `@warn`s listing the gap IDs so callers know which
downstream beads must land before their model can be migrated cleanly.

Each entry carries:
- `bead_id`: the upstream bead tracking the gap (or `"unknown"`)
- `description`: human-readable one-liner (shown in warnings and JSON)
- `location`: location hint (variable or equation index) for the user
"""
struct GapReport
    bead_id::String
    description::String
    location::String
end

"""
    mtk2esm(sys; metadata=(;))

Export a ModelingToolkit system to an ESM-format `Dict{String,Any}` suitable
for JSON serialization. The concrete dispatch lives in
`EarthSciASTMTKExt` / `EarthSciASTCatalystExt`.

# Arguments
- `sys`: an MTK `System` / `ODESystem` / `ReactionSystem` / `SDESystem` /
  `NonlinearSystem` / `PDESystem`, or a Catalyst `ReactionSystem`.

# Keyword arguments
- `metadata`: NamedTuple-like of migration metadata. Recognized fields:
  `tags` (`Vector{String}`), `source_ref` (`String`), `description`
  (`String`), `authors` (`Vector{String}`), `version` (`String`),
  `name` (overrides `nameof(sys)`).

# Returns
A `Dict{String,Any}` shaped like a full ESM file: `esm`, `metadata`, and
either `models.<name>` or `reaction_systems.<name>`. Any schema-gap
constructs produce `TODO_GAP` entries inside the emitted component's
`metadata.notes` field plus an `@warn` listing the gaps.

Raises a clear `ArgumentError` if the MTK/Catalyst extension hasn't been
loaded — the stub in `src/mtk_export.jl` has no way to walk an MTK system
on its own.
"""
function mtk2esm end
# Fallback fired when no extension method matched (same stub pattern as
# `_simulate_solve` in simulate.jl / `provider_refresh_times` in
# data_refresh.jl): the extension methods are typed on MTK/Catalyst system
# types, so any call reaching this untyped method means the extension that
# defines them is not loaded.
mtk2esm(sys; kwargs...) = throw(ArgumentError(
    "mtk2esm requires a package extension: load ModelingToolkit (plus " *
    "Symbolics and DomainSets) to activate EarthSciASTMTKExt, or " *
    "Catalyst to activate EarthSciASTCatalystExt, then retry"))

"""
    mtk2esm_gaps(sys)

Internal helper: returns a `Vector{GapReport}` for any schema-gap constructs
found in `sys` without running the full export. Useful for pre-flight
checks. Extensions override this with concrete implementations.

Raises a clear `ArgumentError` if the MTK extension hasn't been loaded.
"""
function mtk2esm_gaps end
mtk2esm_gaps(sys) = throw(ArgumentError(
    "mtk2esm_gaps requires a package extension: load ModelingToolkit (plus " *
    "Symbolics and DomainSets) to activate EarthSciASTMTKExt, " *
    "then retry"))

# ========================================
# MTK-independent export helpers
# ========================================
# Shared by EarthSciASTMTKExt and EarthSciASTCatalystExt
# (both previously carried private copies — `_meta_string`/`_rmeta_string`,
# duplicated `_strip_time`, inline TODO_GAP strings and @warn blocks).
# None of these touch MTK/Catalyst types, so they live here next to
# `GapReport`.

"Strip a trailing `(t)` time-dependence suffix from a printed symbolic name."
_strip_time(s::AbstractString) = endswith(s, "(t)") ? s[1:end-3] : s

"""
    _meta_string(metadata, key, default) -> String

Read an optional string-valued field from a NamedTuple-like `metadata`
container, returning `default` when the field is absent or `nothing`.
"""
function _meta_string(metadata, key::Symbol, default::String)
    hasproperty(metadata, key) || return default
    v = getproperty(metadata, key)
    return v === nothing ? default : String(v)
end

"""
    _meta_vec_string(metadata, key) -> Union{Vector{String},Nothing}

Read an optional vector-of-strings field from a NamedTuple-like `metadata`
container, returning `nothing` when the field is absent or `nothing`.
"""
function _meta_vec_string(metadata, key::Symbol)
    hasproperty(metadata, key) || return nothing
    v = getproperty(metadata, key)
    v === nothing && return nothing
    return [String(x) for x in v]
end

"Format a `GapReport` as the TODO_GAP note line embedded in `reference.notes`."
_gap_to_note(g::GapReport) =
    "TODO_GAP: $(g.bead_id) - $(g.description) @ $(g.location)"

"""
    _reference_notes(metadata, gaps) -> Vector{String}

Assemble the `reference.notes` lines for an exported component: migration
`source_ref`, non-default `version`, free-form `description`, and one
TODO_GAP line per `GapReport`. Callers join with `\\n` and omit the
`reference` entry entirely when the result is empty.
"""
function _reference_notes(metadata, gaps::Vector{GapReport})
    lines = String[]
    source_ref = _meta_string(metadata, :source_ref, "")
    isempty(source_ref) || push!(lines, "source_ref: $source_ref")
    version_str = _meta_string(metadata, :version, "0.1.0")
    version_str == "0.1.0" || push!(lines, "version: $version_str")
    mod_desc = _meta_string(metadata, :description, "")
    isempty(mod_desc) || push!(lines, mod_desc)
    for g in gaps
        push!(lines, _gap_to_note(g))
    end
    return lines
end

"""
    _esm_file_metadata(metadata, sys_name) -> Dict{String,Any}

Build the top-level `metadata` object of an exported ESM file from the
caller-supplied migration metadata (name/description/authors/tags).
"""
function _esm_file_metadata(metadata, sys_name::String)
    file_meta = Dict{String,Any}("name" => sys_name)
    file_desc = _meta_string(metadata, :description, "")
    isempty(file_desc) || (file_meta["description"] = file_desc)
    authors = _meta_vec_string(metadata, :authors)
    authors === nothing || (file_meta["authors"] = authors)
    ftags = _meta_vec_string(metadata, :tags)
    ftags === nothing || (file_meta["tags"] = ftags)
    return file_meta
end

"""
    _warn_gaps(gaps, label)

Emit the standard `mtk2esm` schema-gap `@warn` (one bullet per gap) for the
exported component described by `label` (e.g. `"ODESystem Foo"`). No-op
when `gaps` is empty.
"""
function _warn_gaps(gaps::Vector{GapReport}, label::String)
    isempty(gaps) && return nothing
    gap_lines = join(["  - [$(g.bead_id)] $(g.description) @ $(g.location)"
                      for g in gaps], "\n")
    @warn "mtk2esm: $(length(gaps)) schema-gap construct(s) in $(label):\n$(gap_lines)"
    return nothing
end
