# Variable bounds `lb` / `ub` (esm-spec §6.3.2): round-trip as authored, the
# esm 2.1.0 version gate, the four validity rules, and the rewrite flattening
# applies to a bound reference (esm-libraries-spec §4.7.5).

using Test
using EarthSciAST
using JSON3

include("testutils.jl")

const _VB_VALID = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid")
const _VB_INVALID = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid")

# A one-model document whose variables are `vars`, with one ODE per state named
# in `odes` and the observed definitions `obs` (`name => rhs`).
function _vb_doc(vars; odes = String[], obs = Pair{String, Any}[], subsystems = nothing, esm = "2.1.0")
    eqs = Any[]
    for s in odes
        push!(eqs, Dict("lhs" => Dict("op" => "D", "args" => [s], "wrt" => "t"), "rhs" => 0.0))
    end
    for (n, rhs) in obs
        push!(eqs, Dict("lhs" => n, "rhs" => rhs))
    end
    model = Dict{String, Any}("variables" => vars, "equations" => eqs)
    subsystems === nothing || (model["subsystems"] = subsystems)
    return Dict{String, Any}(
        "esm" => esm, "metadata" => Dict("name" => "vb"),
        "models" => Dict("M" => model)
    )
end
_vb_load(doc) = EarthSciAST.load_string(JSON3.write(doc))
_vb_errors(doc) = [
    (e.error_type, e.path, e.details)
        for e in EarthSciAST.validate(_vb_load(doc)).structural_errors
]
_vb_unknown(; kw...) = Dict{String, Any}("type" => "unknown", "units" => "1", (String(k) => v for (k, v) in kw)...)
_vb_param(; kw...) = Dict{String, Any}("type" => "parameter", "units" => "1", "default" => 1.0, (String(k) => v for (k, v) in kw)...)

@testset "variable bounds (esm-spec §6.3.2)" begin
    @testset "round-trip keeps bounds as authored: $f" for f in (
            "variable_bounds.esm", "variable_bounds_shaped.esm", "variable_bounds_coupled.esm",
        )
        path = joinpath(_VB_VALID, f)
        raw = JSON3.read(read(path, String))
        emitted = EarthSciAST.serialize_esm_file(EarthSciAST.load_path(path))
        function check(rawm, outm, at)
            for (vn, rv) in pairs(rawm["variables"])
                ov = outm["variables"][String(vn)]
                for field in (:lb, :ub)
                    if haskey(rv, field)
                        # A number stays the number written (an integer stays an
                        # integer) and a reference stays its string.
                        @test (at, vn, field, ov[String(field)], typeof(ov[String(field)])) ==
                            (at, vn, field, rv[field], rv[field] isa Integer ? Int64 : typeof(rv[field]) <: AbstractString ? String : Float64)
                    else
                        @test (at, vn, field, haskey(ov, String(field))) == (at, vn, field, false)
                    end
                end
            end
            if haskey(rawm, :subsystems)
                for (sn, rs) in pairs(rawm[:subsystems])
                    check(rs, outm["subsystems"][String(sn)], "$at.$sn")
                end
            end
        end
        for (mn, rm) in pairs(raw[:models])
            check(rm, emitted["models"][String(mn)], String(mn))
        end
        @test EarthSciAST.validate(EarthSciAST.load_path(path)).is_valid
    end

    @testset "the version-compatibility fixture loads clean" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "version_compatibility", "version_2_1_0_variable_bounds.esm")
        @test EarthSciAST.validate(EarthSciAST.load_path(path)).is_valid
    end

    pins = JSON3.read(read(joinpath(_VB_INVALID, "expected_errors.json"), String))
    @testset "shared invalid fixture: $f" for f in (
            "variable_bound_unresolved.esm", "variable_bound_shape_mismatch.esm",
            "variable_bound_shape_mismatch_axes.esm", "variable_bound_circular_self.esm",
            "variable_bound_circular_observed.esm", "variable_bounds_inverted.esm",
        )
        result = EarthSciAST.validate(EarthSciAST.load_path(joinpath(_VB_INVALID, f)))
        @test isempty(result.schema_errors)
        want = [
            (String(e.code), String(e.path), Dict{String, Any}(String(k) => v for (k, v) in pairs(e.details)), String(e.message))
                for e in pins[f].structural_errors
        ]
        @test [(e.error_type, e.path, e.details, e.message) for e in result.structural_errors] == want
    end

    @testset "version gate" begin
        err = try
            EarthSciAST.load_path(joinpath(_VB_INVALID, "variable_bounds_version_too_old.esm"))
            nothing
        catch e
            e
        end
        @test err isa EarthSciAST.ExpressionTemplateError
        @test err.code == pins["variable_bounds_version_too_old.esm"].resolver_error_code
        @test occursin("/models/M/variables/x/lb", sprint(showerror, err))

        # The first field in document order, here inside a subsystem's `ub`.
        doc = _vb_doc(
            Dict("x" => _vb_unknown(default = 0.0)); odes = ["x"], esm = "2.0.0",
            subsystems = Dict(
                "S" => Dict(
                    "variables" => Dict("y" => _vb_unknown(default = 0.0, ub = 3)),
                    "equations" => [Dict("lhs" => Dict("op" => "D", "args" => ["y"], "wrt" => "t"), "rhs" => 0.0)]
                )
            )
        )
        err = try
            _vb_load(doc); nothing
        catch e
            e
        end
        @test err isa EarthSciAST.ExpressionTemplateError
        @test occursin("/models/M/subsystems/S/variables/y/ub", sprint(showerror, err))
        # 2.0.0 without bounds, and 2.1.0 with them, both load.
        doc["models"]["M"]["subsystems"]["S"]["variables"]["y"] = _vb_unknown(default = 0.0)
        @test _vb_load(doc) isa EarthSciAST.EsmFile
        @test EarthSciAST.reject_variable_bounds_pre_v21(
            _vb_doc(Dict("x" => _vb_unknown(default = 0.0, lb = 0)); odes = ["x"])
        ) === nothing
    end

    @testset "a 2.0.0 root mounting a 2.1.0 leaf with bounds: load, emit, reload" begin
        mktempdir() do dir
            leaf = Dict{String, Any}(
                "esm" => "2.1.0", "metadata" => Dict("name" => "leaf"),
                "models" => Dict(
                    "L" => Dict(
                        "variables" => Dict(
                            "y" => _vb_unknown(default = 0.5, lb = 0, ub = "cap"),
                            "cap" => _vb_param(),
                        ),
                        "equations" => [Dict("lhs" => Dict("op" => "D", "args" => ["y"], "wrt" => "t"), "rhs" => 0.0)]
                    )
                )
            )
            write(joinpath(dir, "leaf.esm"), JSON3.write(leaf))
            root = _vb_doc(
                Dict("x" => _vb_unknown(default = 0.0)); odes = ["x"], esm = "2.0.0",
                subsystems = Dict("Sub" => Dict("ref" => "leaf.esm"))
            )
            write(joinpath(dir, "root.esm"), JSON3.write(root))
            loaded = EarthSciAST.load_path(joinpath(dir, "root.esm"))
            sub = loaded.models["M"].subsystems["Sub"]
            @test (sub.variables["y"].lb, sub.variables["y"].ub) == (0, "cap")
            emitted = EarthSciAST.to_json(loaded)
            @test JSON3.read(emitted)["esm"] == "2.1.0"
            write(joinpath(dir, "emitted.esm"), emitted)
            reloaded = EarthSciAST.load_path(joinpath(dir, "emitted.esm"))
            @test reloaded.models["M"].subsystems["Sub"].variables["y"].ub == "cap"
            # Without bounds in the tree, the declared version is kept.
            plain = _vb_load(_vb_doc(Dict("x" => _vb_unknown(default = 0.0)); odes = ["x"], esm = "2.0.0"))
            @test JSON3.read(EarthSciAST.to_json(plain))["esm"] == "2.0.0"
        end
    end

    @testset "rules on a subsystem, a dotted reference, and legal shapes" begin
        sub = Dict(
            "variables" => Dict(
                "y" => _vb_unknown(default = 0.0, ub = "nope"),
                "cap" => _vb_param(),
                "q" => _vb_unknown(default = 0.0, lb = "y"),
            ),
            "equations" => [
                Dict("lhs" => Dict("op" => "D", "args" => ["y"], "wrt" => "t"), "rhs" => 0.0),
                Dict("lhs" => Dict("op" => "D", "args" => ["q"], "wrt" => "t"), "rhs" => 0.0),
            ]
        )
        doc = _vb_doc(
            Dict(
                "x" => _vb_unknown(default = 0.0, lb = "S.cap", ub = "S.missing"),
                "w" => _vb_unknown(default = 0.0, lb = 1, ub = 1),     # lb == ub is legal
                "v" => _vb_unknown(default = 0.0, lb = 1.5, ub = 1),
                "u" => _vb_unknown(default = 0.0, ub = "M.x"),         # top-level path
            ); odes = ["x", "w", "v", "u"], subsystems = Dict("S" => sub)
        )
        # Models, variables and subsystems in sorted order; `u`'s top-level path
        # `M.x` and `x`'s scoped `S.cap` resolve, `S.q`'s bare `y` resolves in S.
        @test _vb_errors(doc) == [
            ("variable_bounds_inverted", "/models/M/variables/v",
                Dict{String, Any}("variable" => "v", "lb" => 1.5, "ub" => 1)),
            ("undefined_variable", "/models/M/variables/x/ub",
                Dict{String, Any}("variable" => "S.missing", "bound" => "ub")),
            ("undefined_variable", "/models/M/subsystems/S/variables/y/ub",
                Dict{String, Any}("variable" => "nope", "bound" => "ub")),
        ]
    end

    @testset "rule 3: an observed bound" begin
        # `a` depends on a DIFFERENT state, so it is a legal bound on `x`.
        ok = _vb_doc(
            Dict(
                "x" => _vb_unknown(default = 0.0, ub = "a"),
                "z" => _vb_unknown(default = 0.0),
                "a" => _vb_unknown(),
            ); odes = ["x", "z"], obs = ["a" => Dict("op" => "*", "args" => [2, "z"])]
        )
        @test _vb_errors(ok) == []
        # Through a subsystem: `S.a` reads `M.x` by a top-level path.
        circ = _vb_doc(
            Dict("x" => _vb_unknown(default = 0.0, ub = "S.a"));
            odes = ["x"],
            subsystems = Dict(
                "S" => Dict(
                    "variables" => Dict("a" => _vb_unknown()),
                    "equations" => [Dict("lhs" => "a", "rhs" => Dict("op" => "+", "args" => ["M.x", 1]))]
                )
            )
        )
        @test _vb_errors(circ) == [
            ("variable_bound_circular", "/models/M/variables/x/ub",
                Dict{String, Any}("variable" => "x", "bound" => "ub", "reference" => "S.a")),
        ]
        # A state ends the walk: `a` reads `z`, whose ODE reads `x` — not circular.
        state_stop = _vb_doc(
            Dict(
                "x" => _vb_unknown(default = 0.0, ub = "a"),
                "z" => _vb_unknown(default = 0.0),
                "a" => _vb_unknown(),
            ); odes = ["x"], obs = ["a" => "z"]
        )
        state_stop["models"]["M"]["equations"] = push!(
            state_stop["models"]["M"]["equations"],
            Dict("lhs" => Dict("op" => "D", "args" => ["z"], "wrt" => "t"), "rhs" => "x")
        )
        @test _vb_errors(state_stop) == []
    end

    @testset "flatten carries and renames bounds" begin
        flat = EarthSciAST.flatten(EarthSciAST.load_path(joinpath(_VB_VALID, "variable_bounds_coupled.esm")))
        all = merge(flat.state_variables, flat.parameters, flat.observed_variables)
        b(n) = (all[n].lb, all[n].ub)
        @test b("Chem.x") == ("Chem.x_min", "Met.cap_src")
        @test b("Chem.z") == (0, "Chem.Sub.y")
        @test b("Chem.Sub.y") == (0, "Chem.Sub.y_cap")
        @test b("Met.cap_src") == (0, nothing)
        @test !haskey(all, "Chem.x_cap")  # the variable_map target leaves with its bounds
        # A flattened bound is written back as a reference string.
        doc = EarthSciAST.flattened_to_esm(flat)
        vars = doc["models"]["Flattened"]["variables"]
        @test vars["Chem.x"]["ub"] == "Met.cap_src"
        @test !haskey(vars["Chem.x_min"], "lb")
    end

    @testset "a scaled variable_map leaves the replacement expression" begin
        doc = Dict{String, Any}(
            "esm" => "2.1.0", "metadata" => Dict("name" => "scaled"),
            "models" => Dict(
                "A" => Dict(
                    "variables" => Dict(
                        "x" => _vb_unknown(default = 0.0, ub = "cap"),
                        "cap" => _vb_param(),
                    ),
                    "equations" => [Dict("lhs" => Dict("op" => "D", "args" => ["x"], "wrt" => "t"), "rhs" => Dict("op" => "-", "args" => ["cap", "x"]))]
                ),
                "B" => Dict("variables" => Dict("src" => _vb_param()), "equations" => []),
            ),
            "coupling" => [
                Dict("type" => "variable_map", "from" => "B.src", "to" => "A.cap",
                    "transform" => "conversion_factor", "factor" => 2.0),
            ]
        )
        flat = EarthSciAST.flatten(_vb_load(doc))
        ub = flat.state_variables["A.x"].ub
        @test ub isa EarthSciAST.ASTExpr
        @test EarthSciAST.to_ascii(ub) == EarthSciAST.to_ascii(flat.equations[1].rhs.args[1])
    end
end
