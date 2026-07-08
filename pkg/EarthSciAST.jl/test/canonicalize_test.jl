using Test
using EarthSciAST
const ESM_Expr = EarthSciAST.Expr

@testset "canonicalize per RFC §5.4" begin

    function _wrap(a)
        if a isa ESM_Expr
            return a
        elseif a isa AbstractFloat
            return NumExpr(Float64(a))
        elseif a isa Integer
            return IntExpr(Int64(a))
        elseif a isa AbstractString
            return VarExpr(String(a))
        end
        error("cannot wrap $(typeof(a))")
    end
    op(name, args::Vector) = OpExpr(name, ESM_Expr[_wrap(a) for a in args])

    @testset "§5.4.6 float format table" begin
        cases = [
            (1.0, "1.0"),
            (-3.0, "-3.0"),
            (0.0, "0.0"),
            (-0.0, "-0.0"),
            (2.5, "2.5"),
            (1e25, "1e25"),
            (5e-324, "5e-324"),
            (1e-7, "1e-7"),
        ]
        for (v, want) in cases
            @test format_canonical_float(v) == want
        end
        # 0.1 + 0.2 = 0.30000000000000004
        a, b = 0.1, 0.2
        @test format_canonical_float(a + b) == "0.30000000000000004"
    end

    @testset "integer emission" begin
        for (v, want) in [(1, "1"), (-42, "-42"), (0, "0")]
            @test canonical_json(IntExpr(v)) == want
        end
    end

    @testset "non-finite errors" begin
        for f in [NaN, Inf, -Inf]
            @test_throws CanonicalizeError canonicalize(NumExpr(f))
        end
    end

    @testset "§5.4.8 worked example" begin
        e = op("+", Any[
            op("*", Any["a", 0]),
            "b",
            op("+", Any["a", 1]),
        ])
        @test canonical_json(e) == "{\"args\":[1,\"a\",\"b\"],\"op\":\"+\"}"
    end

    @testset "flatten basic" begin
        e = op("+", Any[op("+", Any["a", "b"]), "c"])
        @test canonical_json(e) == "{\"args\":[\"a\",\"b\",\"c\"],\"op\":\"+\"}"
    end

    @testset "type-preserving identity elim" begin
        # *(1, x) -> "x"
        @test canonical_json(op("*", Any[1, "x"])) == "\"x\""
        # *(1.0, x) keeps the 1.0
        @test canonical_json(op("*", Any[1.0, "x"])) == "{\"args\":[1.0,\"x\"],\"op\":\"*\"}"
    end

    @testset "zero annihilation type-preserving" begin
        @test canonical_json(op("*", Any[0, "x"])) == "0"
        @test canonical_json(op("*", Any[0.0, "x"])) == "0.0"
        @test canonical_json(op("*", Any[-0.0, "x"])) == "-0.0"
    end

    @testset "int/float disambiguation" begin
        a = op("+", Any[1.0, 2.5])
        b = op("+", Any[1, 2.5])
        ja = canonical_json(a)
        jb = canonical_json(b)
        @test ja != jb
        @test occursin("1.0", ja)
    end

    @testset "neg canonical" begin
        @test canonical_json(op("neg", Any[op("neg", Any["x"])])) == "\"x\""
        @test canonical_json(op("neg", Any[5])) == "-5"
        @test canonical_json(op("-", Any[0, "x"])) == "{\"args\":[\"x\"],\"op\":\"neg\"}"
    end

    @testset "div 0/0" begin
        @test_throws CanonicalizeError canonicalize(op("/", Any[0, 0]))
    end

    @testset "canonicalize preserves ALL OpExpr fields (reconstruct-backed)" begin
        E = EarthSciAST
        agg = OpExpr("aggregate", ESM_Expr[];
            semiring="sum_product", output_idx=Any[],
            ranges=Dict{String,Any}("i" => E.IndexSetRef("cells")),
            expr_body=OpExpr("*", ESM_Expr[VarExpr("A"), VarExpr("F")]),
            join=Any[[("a", "b")]],
            filter=OpExpr(">", ESM_Expr[VarExpr("A"), NumExpr(0.0)]),
            id="prod", manifold="planar", distinct=true, key=VarExpr("k"),
            table="tbl", table_axes=Dict{String,ESM_Expr}("code" => VarExpr("fm")),
            output=2)
        c = canonicalize(agg)
        # Previously ~11 of these were silently dropped by a hand-listed rebuild.
        @test c.semiring == "sum_product"
        @test c.table == "tbl" && haskey(c.table_axes, "code") && c.output == 2
        @test c.join == agg.join && c.filter !== nothing
        @test c.id == "prod" && c.manifold == "planar"
        @test c.distinct === true && c.key == VarExpr("k")
        @test c.expr_body !== nothing && c.ranges !== nothing
    end

    @testset "canonical_json refuses out-of-encoding nodes (no ambiguous bytes)" begin
        E = EarthSciAST
        mkagg(body) = OpExpr("aggregate", ESM_Expr[];
            output_idx=Any[],
            ranges=Dict{String,Any}("i" => E.IndexSetRef("cells")),
            expr_body=body)
        a1 = mkagg(VarExpr("x"))
        a2 = mkagg(VarExpr("y"))
        # Regression: with only op/args emitted, a1 and a2 (differing only in
        # expr_body) produced byte-identical canonical JSON — same defect class
        # as the fixed `fn` bc-node bug. Now both throw the typed coded error.
        for a in (a1, a2)
            err = try
                canonical_json(a)
                nothing
            catch e
                e
            end
            @test err isa CanonicalizeError
            @test err.code == "E_CANONICAL_UNSUPPORTED_FIELD"
        end
        # ... and the same when such a node is nested inside emissible args.
        err = try
            canonical_json(OpExpr("sin", ESM_Expr[a1]))
            nothing
        catch e
            e
        end
        @test err isa CanonicalizeError
        @test err.code == "E_CANONICAL_UNSUPPORTED_FIELD"

        # Emissible field set is untouched: wrt/dim/fn/name/value still emit.
        d = OpExpr("D", ESM_Expr[VarExpr("u")]; wrt="t")
        @test canonical_json(d) == "{\"args\":[\"u\"],\"op\":\"D\",\"wrt\":\"t\"}"
        bc = OpExpr("bc", ESM_Expr[VarExpr("u")]; fn="dirichlet", dim="x")
        @test occursin("\"fn\":\"dirichlet\"", canonical_json(bc))
    end

    @testset "E_CANONICAL_BAD_CONST for unsupported const value types" begin
        n = OpExpr("const", EarthSciAST.Expr[]; value=Dict("a" => 1))
        err = try
            canonical_json(n)
            nothing
        catch e
            e
        end
        @test err isa CanonicalizeError
        @test err.code == "E_CANONICAL_BAD_CONST"
        # supported payloads still emit canonically
        okv = OpExpr("const", EarthSciAST.Expr[]; value=Any[1, 2.5])
        @test canonical_json(okv) == "{\"args\":[],\"op\":\"const\",\"value\":[1,2.5]}"
    end

    @testset "const value integral-float narrowing (CONFORMANCE_SPEC §5.5.3.1)" begin
        # A const `value` payload is DATA: number type is by VALUE, not by
        # Julia storage. `[1, 2.5]` is a Vector{Float64} — the integral 1.0
        # must still emit as the integer token `1` (mirroring JSON3's numeric
        # narrowing and the Rust/Python emitters for integer-token sources).
        fv = OpExpr("const", EarthSciAST.Expr[]; value=[1, 2.5])
        @test canonical_json(fv) == "{\"args\":[],\"op\":\"const\",\"value\":[1,2.5]}"
        # -0.0 narrows to 0 (JSON3.read("-0.0") == Int64 0); out-of-Int64-range
        # integral floats keep the RFC float layout; AST NumExpr literals keep
        # the trailing-.0 disambiguation (§5.4.6) — narrowing is const-data-only.
        edge = OpExpr("const", EarthSciAST.Expr[]; value=Any[-0.0, 1.0e21])
        @test canonical_json(edge) == "{\"args\":[],\"op\":\"const\",\"value\":[0,1e21]}"
        @test canonical_json(NumExpr(1.0)) == "1.0"
    end

    @testset "cross-binding conformance fixtures" begin
        # tests/conformance/canonical/*.json — same fixtures every binding runs.
        using JSON3
        repo_root = abspath(joinpath(@__DIR__, "..", "..", ".."))
        dir = joinpath(repo_root, "tests", "conformance", "canonical")
        manifest = JSON3.read(read(joinpath(dir, "manifest.json"), String))
        fixtures = manifest.fixtures
        @test !isempty(fixtures)

        function wire_to_expr(node)
            if node isa AbstractDict || (node isa JSON3.Object)
                if haskey(node, :op) && haskey(node, :args)
                    args = ESM_Expr[wire_to_expr(a) for a in node[:args]]
                    return OpExpr(String(node[:op]), args)
                end
            end
            if node isa Integer
                return IntExpr(Int64(node))
            elseif node isa AbstractFloat
                return NumExpr(Float64(node))
            elseif node isa AbstractString
                return VarExpr(String(node))
            end
            error("unknown wire form: $(typeof(node))")
        end

        for f in fixtures
            id = String(f[:id])
            path = joinpath(dir, String(f[:path]))
            fixture = JSON3.read(read(path, String))
            expr = wire_to_expr(fixture[:input])
            got = canonical_json(expr)
            want = String(fixture[:expected])
            @test got == want
        end
    end
end
