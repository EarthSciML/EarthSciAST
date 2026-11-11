# Removed op spellings: the `removed_op` rejection at the wire boundary, of
# `arrayop` (removed at esm 0.8.0) and of the ops esm 2.0.0 removed, among them
# `aggregate`, the pre-1.1.0 spelling of `faq`; and the esm 1.1.0 `faq` gate.
# See CONFORMANCE_SPEC §7 and docs/content/rfcs/faq-node-rename.md.

using Test
using EarthSciAST
using JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _ALIAS_CONF = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "removed_spellings")

_removed_op_error(f) =
try
    f()
    nothing
catch e
    e
end

@testset "removed op spellings" begin
    @testset "aggregate is a removed op, at the root and through a ref" begin
        for path in (
                joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "removed_ops", "removed_op_aggregate.esm"),
                joinpath(_ALIAS_CONF, "ref_parent_aliased.esm"),
            )
            err = _removed_op_error(() -> EarthSciAST.load_path(path))
            # Through a ref the child's refusal arrives wrapped in the ref error.
            msg = err === nothing ? "" : sprint(showerror, err)
            @test err isa EarthSciAST.ParseError || err isa EarthSciAST.SubsystemRefError
            @test occursin("removed_op", msg) && occursin("aggregate", msg)
        end
    end

    @testset "every op esm 2.0.0 removed is refused by name, with its path" begin
        node(op) = Dict{String, Any}("op" => op, "args" => Any["x"])
        for op in (
                "fn", "table_lookup", "skolem", "rank", "intersect_polygon",
                "polygon_intersection_area", "argmin", "argmax", "aggregate",
            )
            doc = Dict{String, Any}(
                "esm" => EarthSciAST.SCHEMA_VERSION,
                "metadata" => Dict{String, Any}("name" => "m"),
                "models" => Dict{String, Any}(
                    "M" => Dict{String, Any}(
                        "variables" => Dict{String, Any}(
                            "x" => Dict{String, Any}("type" => "unknown", "default" => 0.0)
                        ),
                        "equations" => Any[
                            Dict{String, Any}(
                                "lhs" => Dict{String, Any}("op" => "D", "args" => Any["x"], "wrt" => "t"),
                                "rhs" => node(op),
                            ),
                        ],
                    ),
                ),
            )
            for load in (
                    () -> EarthSciAST.load_string(JSON3.write(doc)),
                    () -> EarthSciAST.load_document(doc),
                )
                err = _removed_op_error(load)
                @test err isa EarthSciAST.ParseError
                @test err.code == "removed_op"
                @test err.path == "/models/M/equations/0/rhs"
                @test occursin(op, err.message) && occursin("earthsci_ast.migrate", err.message)
            end
            # A node built directly, past the wire boundary, is refused too.
            err = _removed_op_error(() -> EarthSciAST.expression_from_json(node(op)))
            @test err isa EarthSciAST.ParseError && err.code == "removed_op"
        end
    end

    @testset "the shared removed_op fixtures" begin
        dir = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "removed_ops")
        if isdir(dir)
            for f in filter(endswith(".esm"), readdir(dir))
                err = _removed_op_error(() -> EarthSciAST.load_path(joinpath(dir, f)))
                @test err isa EarthSciAST.ParseError
                @test err.code == "removed_op"
            end
        end
    end

    @testset "arrayop in a referenced child is rejected" begin
        err = try
            EarthSciAST.load_path(joinpath(_ALIAS_CONF, "ref_parent_arrayop.esm"))
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("removed_op", sprint(showerror, err))  # the shared diagnostic name
    end

    @testset "the esm 1.1.0 version gate" begin
        mktempdir() do dir
            function at_version(src, version)
                doc = JSON3.read(read(joinpath(_ALIAS_CONF, src), String), Dict{String, Any})
                doc["esm"] = version
                path = joinpath(dir, "v_" * version * "_" * src)
                write(path, JSON3.write(doc))
                return path
            end
            # `faq` arrives at 1.1.0 — the gate the `solver` block also uses.
            err = try
                EarthSciAST.load_path(at_version("canonical.esm", "1.0.0")); nothing
            catch e
                e
            end
            @test err !== nothing
            @test occursin("faq_version_too_old", sprint(showerror, err))  # the shared diagnostic name
        end
    end

    @testset "each file is held to its own esm across a mount (§4.7)" begin
        inv = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid")
        code(path) = try
            EarthSciAST.load_path(path); nothing
        catch e
            e isa EarthSciAST.ExpressionTemplateError ? e.code : rethrow(e)
        end
        @test code(joinpath(inv, "version_gate_newer_mounts_older_const_units.esm")) ==
            "const_units_version_too_old"
        @test code(joinpath(inv, "version_gate_newer_mounts_older_solver.esm")) ==
            "solver_version_too_old"
        @test EarthSciAST.load_path(
            joinpath(
                TESTUTILS_REPO_ROOT, "tests", "valid",
                "version_gate_older_mounts_newer.esm"
            )
        ) isa EarthSciAST.EsmFile
    end

    @testset "arrayop is rejected by name, not left to the open tier" begin
        # `arrayop` matches the `op` pattern, so without a by-name rejection it
        # would load as an OPEN rewrite-target op (esm-spec §4.2) and fail only
        # much later as `unlowered_operator`.
        path = joinpath(
            TESTUTILS_REPO_ROOT, "tests", "invalid", "faq",
            "arrayop_op_removed.esm"
        )
        err = try
            EarthSciAST.load_path(path)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("removed_op", sprint(showerror, err))  # the shared diagnostic name
    end
end
