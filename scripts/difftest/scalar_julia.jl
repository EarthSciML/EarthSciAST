# JSON Lines adapter for Julia's official inline test runner.
using EarthSciAST
using JSON3
using OrdinaryDiffEqTsit5: Tsit5

function result(case)
    document = load_string(JSON3.write(case.document))
    assertions = run_inline_tests(document; model_name = "Probe", compiler = :interpreter, alg = Tsit5())
    by_id = Dict((r.test_id, r.assertion_idx) => r for r in assertions)
    values = String[]
    for request in case.requests
        row = by_id[(String(request.test_id), Int(request.assertion_idx))]
        row.actual === nothing && return (; error = row.message)
        push!(values, string(reinterpret(UInt64, Float64(row.actual))))
    end
    return (; values)
end

function main()
    for line in eachline(stdin)
        response = try
            result(JSON3.read(line))
        catch err
            err isa InterruptException && rethrow()
            (; error = sprint(showerror, err))
        end
        println(JSON3.write(response))
        flush(stdout)
    end
    return
end

main()
