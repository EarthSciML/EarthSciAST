# Tests for the version-migration utilities (src/migration.jl,
# esm-libraries-spec §8.3).
#
# A migration is a pure version-MARKER bump, sound along an ADDITIVE line — a
# run of releases whose changes were additive, so an older file already loads
# under the newer schema; the current line is `2.0.0 … SCHEMA_VERSION` — and
# across the 2.0.0 break for a 1.x document that uses none of what 2.0.0 removed
# (`fn`, `function_tables`/`table_lookup`, `skolem`, `rank`, `argmin`/`argmax`,
# the two geometry leaves). One that does is refused with `removed_op`; the
# Python codemod rewrites it.
#
# Nothing crosses the 1.0.0 boundary. esm 1.0.0 is a clean break: the five
# declared variable types collapse to two, an observed variable's `expression`
# becomes an equation, `data_loaders` becomes a non-component `data_sources`
# registry, and parameter mutation moves off events onto the parameter. Each of
# those RESHAPES the document, and several need information only the equations
# carry, so a 0.x source has no supported target at all. Offering one would
# produce a file claiming 1.0.0 while still carrying 0.x shapes — worse than
# refusing, because the claim would be believed.
#
# These assertions are the Julia mirror of pkg/earthsci-ast-ts/src/migration.test.ts
# and are pinned against the canonical fixture spec in
# tests/version_compatibility/compatibility_matrix.json.

using Test
using EarthSciAST
using JSON3

include("testutils.jl")  # shared prelude: TESTUTILS_REPO_ROOT, _require_fixture

const _MIG_SCHEMA_VERSION = EarthSciAST.SCHEMA_VERSION

# A minimal in-memory document at a chosen declared version. Built directly
# rather than loaded, because most of these versions are ones `load` REFUSES —
# the migration surface has to be reachable for a document the loader would
# reject, which is exactly the 0.x case.
_mig_file(version) = EarthSciAST.EsmFile(String(version), EarthSciAST.Metadata("test"))

@testset "migration" begin

    @testset "supported_migration_targets" begin
        @testset "no target for any 0.x source, the clean break being uncrossable" begin
            for source in ["0.0.1", "0.0.5", "0.1.0", "0.3.0", "0.8.0", "0.9.0"]
                @test supported_migration_targets(source) == String[]
            end
        end

        @testset "a bump to the current schema for 1.x and additive-line sources" begin
            for source in ["1.0.0", "1.3.0", _MIG_SCHEMA_VERSION]
                @test supported_migration_targets(source) == String[_MIG_SCHEMA_VERSION]
            end
        end

        @test supported_migration_targets("1.4.0") == String[]    # past the last 1.x release
        @test supported_migration_targets("2.99.0") == String[]   # past the additive ceiling
        @test supported_migration_targets("3.0.0") == String[]    # higher major
        @test supported_migration_targets("12.34.56") == String[] # much higher major

        @testset "malformed version strings" begin
            for source in [
                    "not-a-version", "1.0", "", "1.0.0-alpha.1", "v1.0.0",
                    "1.0.0 ", "01.0.0.0",
                ]
                @test supported_migration_targets(source) == String[]
            end
        end

        # Numeric, not lexicographic, comparison: `2.10.0` is NEWER than the
        # current version and so off the line, while a large patch of the
        # CURRENT minor is off it too. A string comparison would get
        # "2.10.0" < "2.9.0" and could place either on the line.
        #
        # The second case is derived from `_MIG_SCHEMA_VERSION` rather than
        # written out, so it keeps testing what it names as the library moves.
        @test supported_migration_targets("2.10.0") == String[]
        let m = match(r"^(\d+)\.(\d+)\.(\d+)$", _MIG_SCHEMA_VERSION)
            big_patch = "$(m[1]).$(m[2]).$(parse(Int, m[3]) + 100)"
            @test supported_migration_targets(big_patch) == String[]
        end
    end

    @testset "can_migrate" begin
        @testset "rejects every 0.x source, whatever the target" begin
            @test can_migrate("0.0.5", "0.1.0") == false
            @test can_migrate("0.9.0", "1.0.0") == false
            @test can_migrate("0.9.0", _MIG_SCHEMA_VERSION) == false
        end

        @test can_migrate("1.0.0", _MIG_SCHEMA_VERSION) == true
        @test can_migrate("1.3.0", _MIG_SCHEMA_VERSION) == true
        # Identity no-op: the current version migrated to itself.
        @test can_migrate(_MIG_SCHEMA_VERSION, _MIG_SCHEMA_VERSION) == true

        @testset "rejects an intermediate (non-current) target" begin
            # Only the current schema is a valid target; per-minor jumps are not
            # offered, because there is no per-minor transform to encode.
            #
            # The current version is skipped rather than listed, so the case
            # never asserts the opposite of the line above it as the library
            # advances.
            for target in ("1.0.1", "1.1.0", "1.3.0", "2.0.0", "2.1.0")
                target == _MIG_SCHEMA_VERSION && continue
                @test can_migrate("1.0.0", target) == false
            end
        end

        @test can_migrate("not-a-version", _MIG_SCHEMA_VERSION) == false
        @test can_migrate("1.0.0", "not-a-version") == false

        # can_migrate and supported_migration_targets share one source of truth,
        # so a caller is never told a pair works and then handed a MigrationError.
        for source in ["0.0.5", "0.9.0", "1.0.0", "1.99.0", "2.0.0", "2.99.0", "nonsense"]
            targets = supported_migration_targets(source)
            for target in [_MIG_SCHEMA_VERSION, "0.1.0", "1.0.1", "1.3.0", "2.0.0"]
                @test can_migrate(source, target) == (target in targets)
            end
        end
    end

    @testset "migrate" begin
        @testset "refuses a 0.x source rather than bumping its marker" begin
            source = _mig_file("0.9.0")
            @test_throws MigrationError migrate(source, _MIG_SCHEMA_VERSION)
            # The input is left alone (EsmFile is immutable, so necessarily).
            @test source.esm == "0.9.0"
        end

        @testset "relabels a 1.x file using no removed construct" begin
            source = _mig_file("1.0.0")
            migrated = migrate(source, _MIG_SCHEMA_VERSION)

            @test migrated.esm == _MIG_SCHEMA_VERSION
            @test migrated !== source
            @test source.esm == "1.0.0"
        end

        @testset "a current-version file migrated to the current schema (no-op)" begin
            source = _mig_file(_MIG_SCHEMA_VERSION)
            migrated = migrate(source, _MIG_SCHEMA_VERSION)

            @test migrated.esm == _MIG_SCHEMA_VERSION
            # A no-op marker bump still returns a fresh object.
            @test migrated !== source
        end

        @testset "throws MigrationError for an unsupported version pair" begin
            @test_throws MigrationError migrate(_mig_file("1.0.0"), "2.99.0")
            @test_throws MigrationError migrate(_mig_file("1.0.0"), "1.0.1")
            @test_throws MigrationError migrate(_mig_file("0.1.0"), _MIG_SCHEMA_VERSION)
            @test_throws MigrationError migrate(_mig_file("1.0.0"), "not-a-version")
        end

        @testset "throws when the source declares no version" begin
            # `EsmFile.esm` is a non-optional `String`, so TypeScript's "missing
            # `esm` field" case surfaces here as the empty string.
            @test_throws MigrationError migrate(_mig_file(""), _MIG_SCHEMA_VERSION)
        end

        @testset "the error message names both versions" begin
            err = try
                migrate(_mig_file("0.9.0"), _MIG_SCHEMA_VERSION)
                nothing
            catch e
                e
            end
            @test err isa MigrationError
            msg = sprint(showerror, err)
            @test occursin("0.9.0", msg)
            @test occursin(_MIG_SCHEMA_VERSION, msg)
            @test occursin("not supported", msg)
        end
    end

    @testset "a 1.x document using a removed construct is refused" begin
        # Each construct esm 2.0.0 removed, in a minimal raw 1.3.0 document. The
        # loader refuses these by name, so the raw-document form is the one a
        # caller reaches; the codemod is what rewrites them.
        model(rhs) = Dict{String, Any}(
            "variables" => Dict{String, Any}(
                "x" => Dict{String, Any}("type" => "unknown", "default" => 0.0)
            ),
            "equations" => Any[
                Dict{String, Any}(
                    "lhs" => Dict{String, Any}("op" => "D", "args" => Any["x"], "wrt" => "t"),
                    "rhs" => rhs,
                ),
            ],
        )
        doc(rhs; extra...) = Dict{String, Any}(
            "esm" => "1.3.0", "metadata" => Dict{String, Any}("name" => "m"),
            "models" => Dict{String, Any}("M" => model(rhs)),
            (string(k) => v for (k, v) in extra)...,
        )
        cases = [
            ("fn", Dict{String, Any}("op" => "fn", "name" => "datetime.year", "args" => Any["t"])),
            ("table_lookup", Dict{String, Any}("op" => "table_lookup", "table" => "T", "axes" => Dict{String, Any}("x" => "x"), "args" => Any[])),
            ("skolem", Dict{String, Any}("op" => "skolem", "args" => Any[1, 2])),
            ("rank", Dict{String, Any}("op" => "rank", "args" => Any["x"])),
            ("argmin", Dict{String, Any}("op" => "argmin", "arg" => "g", "expr" => "x", "args" => Any[])),
            ("argmax", Dict{String, Any}("op" => "argmax", "arg" => "g", "expr" => "x", "args" => Any[])),
            ("intersect_polygon", Dict{String, Any}("op" => "intersect_polygon", "manifold" => "planar", "args" => Any["a", "b"])),
            ("polygon_intersection_area", Dict{String, Any}("op" => "polygon_intersection_area", "manifold" => "planar", "args" => Any["a", "b"])),
            ("aggregate", Dict{String, Any}("op" => "aggregate", "output_idx" => Any[], "expr" => "x", "args" => Any[])),
        ]
        for (name, node) in cases
            d = doc(Dict{String, Any}("op" => "+", "args" => Any[1.0, node]))
            @test can_migrate(d, _MIG_SCHEMA_VERSION) == false
            err = try
                migrate(d, _MIG_SCHEMA_VERSION)
                nothing
            catch e
                e
            end
            @test err isa MigrationError
            @test err.code == "removed_op"
            @test err.path == "/models/M/equations/0/rhs/args/1"
            @test occursin(name, err.message) && occursin("codemod", err.message)
            # The loader refuses the same document with the same code.
            perr = try
                EarthSciAST.load_string(JSON3.write(d))
                nothing
            catch e
                e
            end
            @test perr isa EarthSciAST.ParseError
            @test perr.code == "removed_op"
            @test perr.path == "/models/M/equations/0/rhs/args/1"
        end

        tables = Dict{String, Any}(
            "T" => Dict{String, Any}(
                "axes" => Any[Dict{String, Any}("name" => "x", "values" => Any[0.0, 1.0])],
                "data" => Any[0.0, 1.0],
            ),
        )
        d = doc(1.0; function_tables = tables)
        @test can_migrate(d, _MIG_SCHEMA_VERSION) == false
        err = try
            migrate(d, _MIG_SCHEMA_VERSION)
            nothing
        catch e
            e
        end
        @test err isa MigrationError && err.code == "removed_op" &&
            err.path == "/function_tables"

        # A clean 1.x document relabels; nothing else changes.
        clean = doc(Dict{String, Any}("op" => "*", "args" => Any[-1.0, "x"]))
        @test can_migrate(clean, _MIG_SCHEMA_VERSION) == true
        out = migrate(clean, _MIG_SCHEMA_VERSION)
        @test out["esm"] == _MIG_SCHEMA_VERSION
        @test out["models"] === clean["models"]
        @test clean["esm"] == "1.3.0"

        # A typed file can only hold a removed op if it was built in memory.
        built = EarthSciAST.EsmFile(
            "1.3.0", EarthSciAST.Metadata("m");
            models = Dict(
                "M" => EarthSciAST.Model(
                    Dict{String, EarthSciAST.ModelVariable}(),
                    [
                        EarthSciAST.Equation(
                            EarthSciAST.VarExpr("x"),
                            EarthSciAST.OpExpr("skolem", EarthSciAST.ASTExpr[EarthSciAST.IntExpr(1)])
                        ),
                    ]
                ),
            )
        )
        @test can_migrate(built, _MIG_SCHEMA_VERSION) == false
        @test can_migrate(_mig_file("1.3.0"), _MIG_SCHEMA_VERSION) == true
        err = try
            migrate(built, _MIG_SCHEMA_VERSION)
            nothing
        catch e
            e
        end
        @test err isa MigrationError && err.code == "removed_op"
    end

    @testset "marker-only: every other field survives" begin
        # A real loaded document, so the carried-across fields are the populated
        # ones an actual file has rather than a hand-built skeleton's `nothing`s.
        fixture = joinpath(
            TESTUTILS_REPO_ROOT, "tests", "version_compatibility",
            "version_1_0_0_baseline.esm"
        )
        if _require_fixture(fixture)
            source = EarthSciAST.load_path(fixture)
            @test source.esm == "1.0.0"

            migrated = migrate(source, _MIG_SCHEMA_VERSION)
            @test migrated.esm == _MIG_SCHEMA_VERSION

            # Every field other than `esm` is carried across identically. Walking
            # `fieldnames` (rather than listing them) is what catches a field
            # added to `EsmFile` and not threaded through `migrate` — the keyword
            # constructor defaults every optional block, so an omission would
            # otherwise be a silent drop.
            for f in fieldnames(EarthSciAST.EsmFile)
                f === :esm && continue
                @test getfield(migrated, f) === getfield(source, f) ||
                    getfield(migrated, f) == getfield(source, f)
            end
        end
    end

    @testset "canonical fixture spec: 0.x sources are refused" begin
        # tests/version_compatibility/compatibility_matrix.json is the canonical
        # specification. Its `migration_notes` record that 1.0.0 is a clean break
        # with NO automatic path, and its migration_tests pair demonstrates a
        # rewrite a human performs: the SOURCE is unloadable by a 1.x library and
        # the TARGET loads. So `migrate` must refuse the source's version, and
        # the target's version must be one it accepts (as an identity no-op).
        matrix_path = joinpath(
            TESTUTILS_REPO_ROOT, "tests", "version_compatibility",
            "compatibility_matrix.json"
        )
        if _require_fixture(matrix_path)
            matrix = JSON3.read(read(matrix_path, String))
            root = matrix["version_compatibility_test_matrix"]

            # The library version the matrix pins must be the one this binding
            # implements, or the expectations below are about another library.
            @test String(root["library_version"]) == _MIG_SCHEMA_VERSION

            cm = match(r"^(\d+)\.(\d+)\.(\d+)$", _MIG_SCHEMA_VERSION)
            current = (parse(Int, cm[1]), parse(Int, cm[2]), parse(Int, cm[3]))

            # Every fixture the matrix declares as `reject`ed for its major, and
            # every 0.x fixture besides, is out of reach of a marker bump.
            for case in root["test_cases"]
                fv = get(case, "file_version", nothing)
                fv isa AbstractString || continue
                parsed = match(r"^(\d+)\.(\d+)\.(\d+)$", fv)
                parsed === nothing && continue
                v = (parse(Int, parsed[1]), parse(Int, parsed[2]), parse(Int, parsed[3]))
                # Reachable iff on the additive line [2.0.0, current] or a 1.x
                # release up to 1.3.0 (the relabel across the 2.0.0 break).
                on_line = (v[1] == current[1] && v >= (2, 0, 0) && v <= current) ||
                    ((1, 0, 0) <= v <= (1, 3, 0))
                @test !isempty(supported_migration_targets(fv)) == on_line
            end

            # The demonstration pair, read straight out of the matrix.
            for mt in root["migration_tests"]
                src_name = String(mt["source"])
                tgt_name = String(mt["target"])
                src_path = joinpath(
                    TESTUTILS_REPO_ROOT, "tests",
                    "version_compatibility", src_name
                )
                tgt_path = joinpath(
                    TESTUTILS_REPO_ROOT, "tests",
                    "version_compatibility", tgt_name
                )
                (isfile(src_path) && isfile(tgt_path)) || continue

                src_version = String(JSON3.read(read(src_path, String))["esm"])
                tgt_version = String(JSON3.read(read(tgt_path, String))["esm"])

                # The source is pre-break: no automated path off it, to the
                # target's version or to any other.
                @test supported_migration_targets(src_version) == String[]
                @test can_migrate(src_version, tgt_version) == false
                @test_throws MigrationError migrate(_mig_file(src_version), tgt_version)

                # The target is a document this library reads. It keeps the
                # version it is NAMED for (1.0.0) rather than being restamped as
                # the library advances — what matters is that it is ON the
                # additive line, i.e. that migrating it to the current schema is
                # offered (a marker bump, the identity no-op when the two
                # versions coincide).
                @test !isempty(supported_migration_targets(tgt_version))
                @test can_migrate(tgt_version, _MIG_SCHEMA_VERSION) == true
                target_file = EarthSciAST.load_path(tgt_path)
                @test migrate(target_file, _MIG_SCHEMA_VERSION).esm == _MIG_SCHEMA_VERSION
            end
        end
    end
end
