"""
Version-migration utilities for the ESM format (esm-libraries-spec §8.3).

A migration here is a pure version-MARKER bump: it changes the `esm` field and
touches nothing else. That is only ever sound along an ADDITIVE line — a run of
schema releases each of which introduced its changes as additive,
backward-compatible fields, so an older file already loads under the newer
schema without any mechanical transform.

The current additive line is `1.0.0 … <current schema version>`
(`ESM_FORMAT_VERSION`).

**There is no migration across the 1.0.0 boundary.** esm 1.0.0 is a clean break
with no deprecation path: the five declared variable types collapse to two, an
observed variable's `expression` becomes an equation, `data_loaders` becomes a
non-component `data_sources` registry, and parameter mutation moves off events
onto the parameter. None of that is a marker bump — every one of them RESHAPES
the document, and several need information (which unknowns are ODE states) that
only the equations carry. A 0.x source therefore yields no supported targets
rather than a bump that would produce a file claiming 1.0.0 while still carrying
0.x shapes.

That refusal is the same line the repo-level `scripts/migrate-0x-to-1.0.0.py`
draws: it rewrites what is mechanical (`type: state`/`observed` → `unknown`, an
observed's `expression` → a bare-variable-LHS equation, `examples` → `analyses`)
and REFUSES `data_loaders`, `functional_affect`/`discrete_parameters`, and
never-valid `type` values, because each needs information the document does not
carry. Converting a 0.x document is a rewrite a human performs — deliberately
not offered as an automated one, here or there.

The single supported target for an additive-line source is the CURRENT schema
version; arbitrary intermediate targets are deliberately NOT offered — there is
no per-minor transform to encode, only "bring this file up to current". Sources
outside that line (newer than current, a different major, or malformed) yield no
supported targets.

This mirrors the TypeScript reference implementation
(`pkg/earthsci-ast-ts/src/migration.ts`) and the canonical fixture spec in
`tests/version_compatibility/compatibility_matrix.json`.
"""

"""
    MigrationError <: Exception

Thrown when [`migrate`](@ref) is asked for a version pair it does not support —
including every pair that crosses the 1.0.0 clean break.
"""
struct MigrationError <: Exception
    message::String
end

Base.showerror(io::IO, e::MigrationError) = print(io, "MigrationError: ", e.message)

# Parsed semantic-version components, or `nothing` for a malformed string.
# Strict `major.minor.patch`: a prerelease suffix or a two-component string is
# malformed, matching the schema's `^\d+\.\d+\.\d+$` pattern for `esm`.
function _migration_parse_version(version::AbstractString)::Union{NTuple{3,Int},Nothing}
    m = match(r"^(\d+)\.(\d+)\.(\d+)$", version)
    m === nothing && return nothing
    return (parse(Int, m[1]), parse(Int, m[2]), parse(Int, m[3]))
end

# Numeric, component-wise comparison: `1.10.0` is newer than `1.2.0`, and
# `1.0.100` is a patch of `1.0`, not a minor bump.
function _migration_compare_versions(a::NTuple{3,Int}, b::NTuple{3,Int})::Int
    a[1] != b[1] && return a[1] - b[1]
    a[2] != b[2] && return a[2] - b[2]
    return a[3] - b[3]
end

# The additive line runs from 1.0.0 up to (and including) the current schema
# version, read from the library's own `ESM_FORMAT_VERSION` so this never
# hand-drifts from the version the rest of the package targets.
#
# The floor is 1.0.0, not 0.1.0: the 0.x line ended at a clean break, so no 0.x
# version can be carried forward by a marker bump. `_on_additive_line` already
# requires the majors to agree, which makes a 0.x source ineligible on its own;
# the floor is stated at 1.0.0 as well so the intent survives the next major.
const _MIGRATION_ADDITIVE_FLOOR = (1, 0, 0)

# `ESM_FORMAT_VERSION` is a literal in types.jl, so this parse cannot fail; the
# assert is a tripwire for a future edit that makes it non-semver.
const _MIGRATION_CURRENT_VERSION = let v = _migration_parse_version(ESM_FORMAT_VERSION)
    v === nothing && error("ESM_FORMAT_VERSION is not a semver string: $(ESM_FORMAT_VERSION)")
    v
end

# True when `version` sits on the additive line `1.0.0 … <current>` and can be
# carried to the current schema version by a marker-only, no-op migration.
function _on_additive_line(version::NTuple{3,Int})::Bool
    return version[1] == _MIGRATION_CURRENT_VERSION[1] &&
           _migration_compare_versions(version, _MIGRATION_ADDITIVE_FLOOR) >= 0 &&
           _migration_compare_versions(version, _MIGRATION_CURRENT_VERSION) <= 0
end

"""
    supported_migration_targets(source_version::AbstractString) -> Vector{String}

The schema versions `source_version` can be migrated to.

- A version on the additive line `1.0.0 … <current schema version>` →
  `[ESM_FORMAT_VERSION]` (a no-op marker bump to the current schema).
- Everything else — including EVERY 0.x version, which 1.0.0's clean break puts
  out of reach of a marker bump, plus newer-than-current, other majors, and
  malformed strings — → `String[]`.

Named without the `get` prefix its TypeScript twin (`getSupportedMigrationTargets`)
carries; the behaviour is identical.

# Examples
```julia
supported_migration_targets("1.0.0")   # ["1.0.0"]
supported_migration_targets("0.9.0")   # String[]  — the clean break
supported_migration_targets("2.0.0")   # String[]
supported_migration_targets("1.0")     # String[]  — malformed
```
"""
function supported_migration_targets(source_version::AbstractString)::Vector{String}
    parsed = _migration_parse_version(source_version)
    if parsed !== nothing && _on_additive_line(parsed)
        return String[ESM_FORMAT_VERSION]
    end
    return String[]
end

"""
    can_migrate(from_version::AbstractString, to_version::AbstractString) -> Bool

Whether [`migrate`](@ref) would succeed for this version pair — i.e. whether
`to_version` is among [`supported_migration_targets`](@ref)`(from_version)`.

Deliberately consults the same single source of truth `migrate` does, so a
caller is never told a pair is migratable and then handed a `MigrationError`.
"""
function can_migrate(from_version::AbstractString, to_version::AbstractString)::Bool
    return String(to_version) in supported_migration_targets(from_version)
end

"""
    migrate(file::EsmFile, target_version::AbstractString) -> EsmFile

Migrate `file` from the version it declares to `target_version`.

Every supported step is a pure version-marker bump with no structural
transform: an additive-line source (`1.0.0 … <current>`) advanced to the current
schema version (see this file's header). Any other version pair — a 0.x source
included — throws [`MigrationError`](@ref). Content-level changes are not
performed; they are modeling decisions, not mechanical migrations.

`EsmFile` is immutable, so the input is necessarily left alone: a NEW `EsmFile`
carrying the updated `esm` marker and every other field unchanged is returned.

# Throws
- `MigrationError` if the file declares no version, or if the pair is not one
  [`can_migrate`](@ref) accepts.
"""
function migrate(file::EsmFile, target_version::AbstractString)::EsmFile
    source_version = file.esm
    if isempty(source_version)
        throw(MigrationError("Source file has no 'esm' version field"))
    end

    if !can_migrate(source_version, target_version)
        throw(MigrationError(
            "Migration from $(source_version) to $(target_version) is not supported"))
    end

    # Marker-only bump: every other field is carried across by reference.
    # `EsmFile`'s keyword constructor defaults every optional block, so a field
    # added to the struct and not listed here would be silently dropped — the
    # round-trip assertion in test/migration_test.jl walks `fieldnames(EsmFile)`
    # to catch exactly that.
    return EsmFile(String(target_version), file.metadata;
        models=file.models,
        reaction_systems=file.reaction_systems,
        data_sources=file.data_sources,
        coupling=file.coupling,
        domain=file.domain,
        enums=file.enums,
        function_tables=file.function_tables,
        index_sets=file.index_sets,
        expression_templates=file.expression_templates,
        metaparameters=file.metaparameters,
        component_templates=file.component_templates,
        coordinates=file.coordinates)
end
