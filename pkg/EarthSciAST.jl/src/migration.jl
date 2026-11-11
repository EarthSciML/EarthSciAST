"""
Version-migration utilities for the ESM format (esm-libraries-spec §8.3).

A migration here is a pure version-MARKER bump: it changes the `esm` field and
touches nothing else. That is sound in two cases:

- along an ADDITIVE line — a run of schema releases each of which introduced its
  changes as additive, backward-compatible fields, so an older file already loads
  under the newer schema. The current additive line is
  `2.0.0 … <current schema version>` (`SCHEMA_VERSION`);
- across the 2.0.0 break, for a 1.x document that uses none of what 2.0.0
  removed. esm 2.0.0 removed the `fn` op (the closed function registry), the
  `function_tables` block and its `table_lookup` op, the `skolem` and `rank`
  ops, the `argmin`/`argmax` op forms and the `intersect_polygon` /
  `polygon_intersection_area` geometry leaves, each replaced by an
  `esm:std/*.esm` expression template, and the `aggregate` spelling of `faq`. A 1.x document using none of them means
  the same thing under 2.0.0, so relabeling it is a marker bump. One that uses
  any of them is refused with the `removed_op` code: rewriting it onto the
  templates is the job of the offline codemod (`python -m earthsci_ast.migrate`),
  the one reference implementation of that rewrite.

**There is no migration across the 1.0.0 boundary.** esm 1.0.0 is a clean break
with no deprecation path: the five declared variable types collapse to two, an
observed variable's `expression` becomes an equation, `data_loaders` becomes a
non-component `data_sources` registry, and parameter mutation moves off events
onto the parameter. None of that is a marker bump — every one of them RESHAPES
the document, and several need information (which unknowns are ODE states) that
only the equations carry. A 0.x source therefore yields no supported targets
rather than a bump that would produce a file claiming a 1.0.0-or-later version
while still carrying 0.x shapes.

That refusal is the same line the repo-level `scripts/migrate-0x-to-1.0.0.py`
draws: it rewrites what is mechanical (`type: state`/`observed` → `unknown`, an
observed's `expression` → a bare-variable-LHS equation, `examples` → `analyses`)
and REFUSES `data_loaders`, `functional_affect`/`discrete_parameters`, and
never-valid `type` values, because each needs information the document does not
carry. Converting a 0.x document is a rewrite a human performs — deliberately
not offered as an automated one, here or there.

The single supported target for a source is the CURRENT schema version;
arbitrary intermediate targets are deliberately NOT offered — there is no
per-minor transform to encode, only "bring this file up to current". Sources
outside the 1.x line and the additive line (0.x, newer than current, another
major, or malformed) yield no supported targets.

This mirrors the TypeScript reference implementation
(`pkg/earthsci-ast-ts/src/migration.ts`) and the canonical fixture spec in
`tests/version_compatibility/compatibility_matrix.json`.
"""

"""
    MigrationError <: EarthSciASTError

Thrown when [`migrate`](@ref) is asked for a version pair it does not support —
including every pair that crosses the 1.0.0 clean break — or for a 1.x document
that uses a construct esm 2.0.0 removed. `code` is the diagnostic code: empty
for an unsupported version pair, `removed_op` for a removed construct, whose
`path` it names.
"""
struct MigrationError <: EarthSciASTError
    message::String
    code::String
    path::String
    MigrationError(message::AbstractString; code::AbstractString = "", path::AbstractString = "") =
        new(String(message), String(code), String(path))
end

Base.showerror(io::IO, e::MigrationError) = print(io, "MigrationError: ", e.message)

# Parsed semantic-version components, or `nothing` for a malformed string.
# Strict `major.minor.patch`: a prerelease suffix or a two-component string is
# malformed, matching the schema's `^\d+\.\d+\.\d+$` pattern for `esm`.
function _migration_parse_version(version::AbstractString)::Union{NTuple{3, Int}, Nothing}
    m = match(r"^(\d+)\.(\d+)\.(\d+)$", version)
    m === nothing && return nothing
    return (parse(Int, m[1]), parse(Int, m[2]), parse(Int, m[3]))
end

# Numeric, component-wise comparison: `1.10.0` is newer than `1.2.0`, and
# `1.0.100` is a patch of `1.0`, not a minor bump.
function _migration_compare_versions(a::NTuple{3, Int}, b::NTuple{3, Int})::Int
    a[1] != b[1] && return a[1] - b[1]
    a[2] != b[2] && return a[2] - b[2]
    return a[3] - b[3]
end

# The additive line runs from 2.0.0 up to (and including) the current schema
# version, read from the library's own `SCHEMA_VERSION` so this never
# hand-drifts from the version the rest of the package targets. The 1.x line
# ended at the 2.0.0 break; its sources are handled by `_crosses_2_0_0_break`.
const _MIGRATION_ADDITIVE_FLOOR = (2, 0, 0)

# `SCHEMA_VERSION` is a literal in types.jl, so this parse cannot fail; the
# assert is a tripwire for a future edit that makes it non-semver.
const _MIGRATION_CURRENT_VERSION = let v = _migration_parse_version(SCHEMA_VERSION)
    v === nothing && error("SCHEMA_VERSION is not a semver string: $(SCHEMA_VERSION)")
    v
end

# True when `version` sits on the additive line `2.0.0 … <current>` and can be
# carried to the current schema version by a marker-only, no-op migration.
function _on_additive_line(version::NTuple{3, Int})::Bool
    return version[1] == _MIGRATION_CURRENT_VERSION[1] &&
        _migration_compare_versions(version, _MIGRATION_ADDITIVE_FLOOR) >= 0 &&
        _migration_compare_versions(version, _MIGRATION_CURRENT_VERSION) <= 0
end

# The last release of the 1.x line.
const _MIGRATION_LAST_1X = (1, 3, 0)

# True when `version` is a 1.x release (`1.0.0 … 1.3.0`), which reaches the
# current schema version by a relabel across the 2.0.0 break when the document
# uses none of the constructs 2.0.0 removed (checked per document by `migrate`).
_crosses_2_0_0_break(version::NTuple{3, Int})::Bool =
    version[1] == 1 && _migration_compare_versions(version, _MIGRATION_LAST_1X) <= 0 &&
    _MIGRATION_CURRENT_VERSION[1] == 2

"""
    supported_migration_targets(source_version::AbstractString) -> Vector{String}

The schema versions `source_version` can be migrated to.

- A version on the additive line `2.0.0 … <current schema version>` →
  `[SCHEMA_VERSION]` (a no-op marker bump to the current schema).
- A 1.x version (`1.0.0 … 1.3.0`) → `[SCHEMA_VERSION]` as well: the relabel across the 2.0.0
  break, which [`migrate`](@ref) performs only for a document that uses none of
  the constructs 2.0.0 removed. Whether a given document qualifies is
  [`can_migrate`](@ref)`(file, target)`.
- Everything else — including EVERY 0.x version, which 1.0.0's clean break puts
  out of reach of a marker bump, plus newer-than-current, other majors, and
  malformed strings — → `String[]`.

Named without the `get` prefix its TypeScript twin (`getSupportedMigrationTargets`)
carries; the behaviour is identical.

# Examples
```julia
supported_migration_targets("1.3.0")   # ["2.0.0"]  — if no removed construct
supported_migration_targets("0.9.0")   # String[]  — the clean break
supported_migration_targets("3.0.0")   # String[]
supported_migration_targets("1.0")     # String[]  — malformed
```
"""
function supported_migration_targets(source_version::AbstractString)::Vector{String}
    parsed = _migration_parse_version(source_version)
    if parsed !== nothing && (_on_additive_line(parsed) || _crosses_2_0_0_break(parsed))
        return String[SCHEMA_VERSION]
    end
    return String[]
end

"""
    can_migrate(from_version::AbstractString, to_version::AbstractString) -> Bool

Whether this version pair is supported — i.e. whether `to_version` is among
[`supported_migration_targets`](@ref)`(from_version)`. For a 1.x source that is
a necessary condition only: the document must also use none of the constructs
esm 2.0.0 removed, which the document forms below check.

    can_migrate(file::EsmFile, to_version) -> Bool
    can_migrate(doc::AbstractDict, to_version) -> Bool

Whether [`migrate`](@ref) would succeed for this document: the version pair is
supported and, for a 1.x source, the document uses no removed construct. A
caller told `true` is never then handed a `MigrationError`.
"""
function can_migrate(from_version::AbstractString, to_version::AbstractString)::Bool
    return String(to_version) in supported_migration_targets(from_version)
end

can_migrate(file::EsmFile, to_version::AbstractString)::Bool =
    can_migrate(file.esm, to_version) && _removed_construct(file) === nothing

function can_migrate(doc::AbstractDict, to_version::AbstractString)::Bool
    v = _get_field(doc, :esm, nothing)
    v isa AbstractString || return false
    return can_migrate(v, to_version) && _removed_2_0_0_finding(doc) === nothing
end

# `(name, path)` of the first removed op in a typed document, or `nothing`. A
# loaded `EsmFile` never holds one (the loader refuses them by name), so this
# only finds nodes built in memory. Walks every field reflectively, so no
# expression-bearing block can be missed; the path is the field path.
function _removed_construct(file::EsmFile)
    seen = IdDict{Any, Nothing}()
    function visit(x, path)
        if x isa OpExpr
            x.op in _REMOVED_OPS_2_0_0 && return (x.op, path)
        elseif x isa Union{AbstractString, Number, Symbol, Nothing, Function, Type}
            return nothing
        end
        if ismutable(x) || x isa AbstractArray || x isa AbstractDict
            haskey(seen, x) && return nothing
            seen[x] = nothing
        end
        if x isa AbstractDict
            for (k, v) in pairs(x)
                r = visit(v, "$(path)/$(k)")
                r === nothing || return r
            end
        elseif x isa AbstractArray || x isa Tuple
            for (i, v) in enumerate(x)
                r = visit(v, "$(path)/$(i - 1)")
                r === nothing || return r
            end
        elseif isstructtype(typeof(x))
            for f in fieldnames(typeof(x))
                isdefined(x, f) || continue
                r = visit(getfield(x, f), "$(path)/$(f)")
                r === nothing || return r
            end
        end
        return nothing
    end
    return visit(file, "")
end

function _removed_construct_error(name::AbstractString, path::AbstractString, from::AbstractString)
    what = name == "function_tables" ? "the `function_tables` block" : "`\"op\": \"$(name)\"`"
    return MigrationError(
        "[E_REMOVED_OP] removed_op at $(path): cannot relabel esm $(from) as " *
            "$(SCHEMA_VERSION): $(what) was $(_REMOVED_2_0_0_HINT).";
        code = ERROR_CODES.REMOVED_OP, path = path
    )
end

"""
    migrate(file::EsmFile, target_version::AbstractString) -> EsmFile

Migrate `file` from the version it declares to `target_version`.

Every supported step is a pure version-marker bump with no structural
transform: an additive-line source (`2.0.0 … <current>`), or a 1.x source that
uses none of the constructs esm 2.0.0 removed, advanced to the current schema
version (see this file's header). Any other version pair — a 0.x source
included — throws [`MigrationError`](@ref), as does a 1.x document using a
removed construct (code `removed_op`; the codemod rewrites those). Content-level
changes are not performed; they are modeling decisions, not mechanical
migrations.

`EsmFile` is immutable, so the input is necessarily left alone: a NEW `EsmFile`
carrying the updated `esm` marker and every other field unchanged is returned.

# Throws
- `MigrationError` if the file declares no version, if the pair is not one
  [`can_migrate`](@ref) accepts, or (code `removed_op`) if a 1.x file uses a
  construct 2.0.0 removed.

    migrate(doc::AbstractDict, target_version) -> Dict{String, Any}

The same relabel on a raw JSON document (as `JSON3.read` returns it), for a
1.x document the loader refuses because it uses a removed construct: refused
with the same `removed_op` error, naming the construct's path. Returns a copy
with the `esm` marker changed and every other key unchanged.
"""
function migrate(file::EsmFile, target_version::AbstractString)::EsmFile
    source_version = file.esm
    if isempty(source_version)
        throw(MigrationError("Source file has no 'esm' version field"))
    end

    if !can_migrate(source_version, target_version)
        throw(
            MigrationError(
                "Migration from $(source_version) to $(target_version) is not supported"
            )
        )
    end
    found = _removed_construct(file)
    found === nothing || throw(_removed_construct_error(found..., source_version))

    # Marker-only bump: every other field is carried across by reference.
    # `EsmFile`'s keyword constructor defaults every optional block, so a field
    # added to the struct and not listed here would be silently dropped — the
    # round-trip assertion in test/migration_test.jl walks `fieldnames(EsmFile)`
    # to catch exactly that.
    return EsmFile(
        String(target_version), file.metadata;
        models = file.models,
        reaction_systems = file.reaction_systems,
        data_sources = file.data_sources,
        coupling = file.coupling,
        domain = file.domain,
        enums = file.enums,
        index_sets = file.index_sets,
        expression_templates = file.expression_templates,
        metaparameters = file.metaparameters,
        component_templates = file.component_templates,
        coordinates = file.coordinates,
        # esm-spec §2.2. A migration on the additive line is a no-op MARKER
        # bump; dropping a field here would make it a lossy rewrite.
        solver = file.solver,
        document_base = file.document_base
    )
end

function migrate(doc::AbstractDict, target_version::AbstractString)::Dict{String, Any}
    source_version = _get_field(doc, :esm, nothing)
    if !(source_version isa AbstractString) || isempty(source_version)
        throw(MigrationError("Source document has no 'esm' version field"))
    end
    if !can_migrate(source_version, target_version)
        throw(
            MigrationError(
                "Migration from $(source_version) to $(target_version) is not supported"
            )
        )
    end
    found = _removed_2_0_0_finding(doc)
    found === nothing || throw(_removed_construct_error(found..., source_version))
    out = Dict{String, Any}(string(k) => v for (k, v) in pairs(doc))
    out["esm"] = String(target_version)
    return out
end
