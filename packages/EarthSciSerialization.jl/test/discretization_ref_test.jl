@testset "Discretization {ref} resolution" begin

    _REF_FIXTURES_DIR = joinpath(
        @__DIR__, "..", "..", "..", "tests", "discretizations")

    # Inline scheme object matching centered_2nd_uniform.esm
    inline_scheme = Dict{String,Any}(
        "applies_to"  => Dict("op" => "grad", "args" => Any["\$u"], "dim" => "\$x"),
        "grid_family" => "cartesian",
        "combine"     => "+",
        "accuracy"    => "O(dx^2)",
        "stencil"     => Any[
            Dict("selector" => Dict("kind" => "cartesian", "axis" => "\$x", "offset" => -1),
                 "coeff"    => Dict("op" => "/", "args" => Any[-1, Dict("op" => "*", "args" => Any[2, "dx"])])),
            Dict("selector" => Dict("kind" => "cartesian", "axis" => "\$x", "offset" =>  1),
                 "coeff"    => Dict("op" => "/", "args" => Any[ 1, Dict("op" => "*", "args" => Any[2, "dx"])])),
        ],
    )

    # ESM that uses centered_2nd_uniform scheme via a use:-rule
    base_esm = Dict{String,Any}(
        "esm"      => "0.4.0",
        "metadata" => Dict{String,Any}("name" => "ref_test"),
        "grids"    => Dict{String,Any}(
            "gx" => Dict{String,Any}(
                "family"     => "cartesian",
                "dimensions" => Any[
                    Dict{String,Any}("name" => "i", "size" => 8,
                                     "periodic" => true, "spacing" => "uniform"),
                ],
            ),
        ),
        "rules" => Any[
            Dict{String,Any}(
                "name"    => "centered_grad",
                "pattern" => Dict("op" => "grad", "args" => Any["\$u"], "dim" => "\$x"),
                "use"     => "centered_2nd_uniform",
            ),
        ],
        "models" => Dict{String,Any}(
            "M" => Dict{String,Any}(
                "grid"      => "gx",
                "variables" => Dict{String,Any}(
                    "u" => Dict{String,Any}(
                        "type" => "state", "default" => 0.0, "units" => "1",
                        "shape" => Any["i"], "location" => "cell_center",
                    ),
                ),
                "equations" => Any[
                    Dict{String,Any}(
                        "lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"),
                        "rhs" => Dict("op" => "grad", "args" => Any["u"], "dim" => "i"),
                    ),
                ],
            ),
        ),
    )

    @testset "absolute path ref discretizes identically to inline" begin
        fixture_path = joinpath(_REF_FIXTURES_DIR, "centered_2nd_uniform.esm")
        isfile(fixture_path) || error("fixture missing: $fixture_path")

        # Inline form
        inline_esm = Base.merge(base_esm, Dict{String,Any}(
            "discretizations" => Dict{String,Any}("centered_2nd_uniform" => inline_scheme),
        ))
        out_inline = discretize(inline_esm)

        # Ref form: key MUST match the use:-rule name ("centered_2nd_uniform").
        # The parent key is the scheme name in the registry; the file supplies the stencil.
        ref_esm = Base.merge(base_esm, Dict{String,Any}(
            "discretizations" => Dict{String,Any}(
                "centered_2nd_uniform" => Dict{String,Any}("ref" => fixture_path),
            ),
        ))
        out_ref = discretize(ref_esm; source_path=joinpath(_REF_FIXTURES_DIR, "dummy.esm"))

        rhs_inline = out_inline["models"]["M"]["equations"][1]["rhs"]
        rhs_ref    = out_ref["models"]["M"]["equations"][1]["rhs"]
        @test JSON3.write(rhs_ref) == JSON3.write(rhs_inline)
    end

    @testset "relative path ref resolves relative to source_path" begin
        fixture_path = joinpath(_REF_FIXTURES_DIR, "centered_2nd_uniform.esm")
        isfile(fixture_path) || error("fixture missing: $fixture_path")

        inline_esm = Base.merge(base_esm, Dict{String,Any}(
            "discretizations" => Dict{String,Any}("centered_2nd_uniform" => inline_scheme),
        ))
        out_inline = discretize(inline_esm)

        # Relative ref resolved relative to source_path's directory.
        ref_esm = Base.merge(base_esm, Dict{String,Any}(
            "discretizations" => Dict{String,Any}(
                "centered_2nd_uniform" => Dict{String,Any}("ref" => "centered_2nd_uniform.esm"),
            ),
        ))
        # source_path is a dummy file path in the fixtures dir — its dirname provides base.
        out_ref = discretize(ref_esm; source_path=joinpath(_REF_FIXTURES_DIR, "dummy.esm"))

        rhs_inline = out_inline["models"]["M"]["equations"][1]["rhs"]
        rhs_ref    = out_ref["models"]["M"]["equations"][1]["rhs"]
        @test JSON3.write(rhs_ref) == JSON3.write(rhs_inline)
    end

    @testset "dangling ref errors with E_SCHEME_REF" begin
        ref_esm = Base.merge(base_esm, Dict{String,Any}(
            "discretizations" => Dict{String,Any}(
                "missing_scheme" => Dict{String,Any}("ref" => "nonexistent_file.esm"),
            ),
        ))
        err = try
            discretize(ref_esm; source_path="/tmp/dummy.esm")
            nothing
        catch e
            e
        end
        @test err isa EarthSciSerialization.RuleEngineError
        @test err.code == "E_SCHEME_REF"
        @test occursin("nonexistent_file.esm", err.message)
    end

    @testset "cyclic ref errors with E_SCHEME_REF" begin
        # Build a cycle: cycle.esm → its own {ref: "cycle.esm"} entry.
        tmp_dir = mktempdir()
        cycle_path = joinpath(tmp_dir, "cycle.esm")
        write(cycle_path, JSON3.write(Dict(
            "esm"      => "0.4.0",
            "metadata" => Dict("name" => "cycle", "authors" => Any["test"]),
            "models"   => Dict("Empty" => Dict(
                "variables" => Dict("x" => Dict(
                    "type" => "state", "units" => "1", "default" => 0.0)),
                "equations" => Any[Dict(
                    "lhs" => Dict("op" => "D", "args" => Any["x"], "wrt" => "t"),
                    "rhs" => 0.0)],
            )),
            "discretizations" => Dict("self_ref" => Dict("ref" => "cycle.esm")),
        )))
        ref_esm = Base.merge(base_esm, Dict{String,Any}(
            "discretizations" => Dict{String,Any}(
                "centered_2nd_uniform" => Dict{String,Any}("ref" => "cycle.esm"),
            ),
        ))
        err = try
            discretize(ref_esm; source_path=joinpath(tmp_dir, "model.esm"))
            nothing
        catch e
            e
        end
        @test err isa EarthSciSerialization.RuleEngineError
        @test err.code == "E_SCHEME_REF"
        @test occursin("ircular", err.message) || occursin("cycle", lowercase(err.message))
        rm(tmp_dir; recursive=true)
    end

    @testset "missing source_path raises E_SCHEME_REF" begin
        ref_esm = Base.merge(base_esm, Dict{String,Any}(
            "discretizations" => Dict{String,Any}(
                "some_scheme" => Dict{String,Any}("ref" => "some_file.esm"),
            ),
        ))
        # Call without source_path — base_path is "" → must error clearly.
        err = try
            discretize(ref_esm)
            nothing
        catch e
            e
        end
        @test err isa EarthSciSerialization.RuleEngineError
        @test err.code == "E_SCHEME_REF"
    end

    @testset "URL ref detection branch raises on unreachable URL" begin
        ref_esm = Base.merge(base_esm, Dict{String,Any}(
            "discretizations" => Dict{String,Any}(
                "centered_2nd_uniform" => Dict{String,Any}(
                    "ref" => "https://example.invalid/scheme.esm"),
            ),
        ))
        err = try
            discretize(ref_esm; source_path="/tmp/dummy.esm")
            nothing
        catch e
            e
        end
        # Must surface as a RuleEngineError (E_SCHEME_REF wraps SubsystemRefError).
        @test err isa EarthSciSerialization.RuleEngineError
        @test err.code == "E_SCHEME_REF"
    end

end
