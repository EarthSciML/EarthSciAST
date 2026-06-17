using Test
using EarthSciSerialization
using JSON3

@testset "rule engine conformance fixtures (RFC §13.1 Step 1)" begin
    fixtures_dir = joinpath(@__DIR__, "..", "..", "..", "tests",
                            "conformance", "discretization", "infra",
                            "rule_engine")
    manifest_path = joinpath(fixtures_dir, "manifest.json")
    manifest = JSON3.read(read(manifest_path, String))

    function build_context(obj)
        haskey(obj, :context) || return RuleContext()
        cx = obj[:context]
        grids = Dict{String,Dict{String,Any}}()
        if haskey(cx, :grids)
            for (k, v) in pairs(cx[:grids])
                entry = Dict{String,Any}()
                for (k2, v2) in pairs(v)
                    key = String(k2)
                    if key == "dim_bounds"
                        bounds = Dict{String,Any}()
                        for (dk, dv) in pairs(v2)
                            bounds[String(dk)] = [Int(x) for x in dv]
                        end
                        entry[key] = bounds
                    elseif key == "dim_sizes"
                        sizes = Dict{String,Int}()
                        for (dk, dv) in pairs(v2)
                            sizes[String(dk)] = Int(dv)
                        end
                        entry[key] = sizes
                    else
                        entry[key] = [String(s) for s in v2]
                    end
                end
                grids[String(k)] = entry
            end
        end
        vars = Dict{String,Dict{String,Any}}()
        if haskey(cx, :variables)
            for (k, v) in pairs(cx[:variables])
                entry = Dict{String,Any}()
                for (k2, v2) in pairs(v)
                    entry[String(k2)] = v2 isa AbstractString ? String(v2) : v2
                end
                vars[String(k)] = entry
            end
        end
        qp = Dict{String,Int}()
        if haskey(cx, :query_point)
            for (k, v) in pairs(cx[:query_point])
                qp[String(k)] = Int(v)
            end
        end
        grid_name = haskey(cx, :grid_name) ? String(cx[:grid_name]) : nothing
        mask_fields = Dict{String,Vector{Dict{String,Int}}}()
        if haskey(cx, :mask_fields)
            for (k, v) in pairs(cx[:mask_fields])
                pts = Dict{String,Int}[]
                for entry in v
                    pt = Dict{String,Int}()
                    for (ek, ev) in pairs(entry)
                        pt[String(ek)] = Int(ev)
                    end
                    push!(pts, pt)
                end
                mask_fields[String(k)] = pts
            end
        end
        return RuleContext(grids, vars, qp, grid_name, mask_fields)
    end

    for fx in manifest[:fixtures]
        id = String(fx[:id])
        path = joinpath(fixtures_dir, String(fx[:path]))
        @testset "$id" begin
            obj = JSON3.read(read(path, String))
            rules = parse_rules(obj[:rules])
            input = EarthSciSerialization._parse_expr(obj[:input])
            max_passes = haskey(obj, :max_passes) ? Int(obj[:max_passes]) : 32
            ctx = build_context(obj)

            expect = obj[:expect]
            kind = String(expect[:kind])
            if kind == "output"
                out = rewrite(input, rules, ctx; max_passes=max_passes)
                @test canonical_json(out) == String(expect[:canonical_json])
            elseif kind == "error"
                want_code = String(expect[:code])
                err = try
                    rewrite(input, rules, ctx; max_passes=max_passes)
                    nothing
                catch e
                    e
                end
                @test err isa RuleEngineError
                @test err !== nothing && err.code == want_code
            else
                error("unknown expect.kind: $kind")
            end
        end
    end
end
