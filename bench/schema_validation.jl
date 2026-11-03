# HOW DOES LOADING SCALE WITH EXPRESSION SIZE AND DEPTH?
#
# `load_string` validates the parsed document against esm-schema.json before
# anything else. A flattened stencil operator is a deep expression, and a
# validator that carries the instance path down the tree pays for the depth on
# every failed check; a valid expression fails several per node (the `number`
# and `string` branches of `Expression`'s `oneOf`, every `if` of
# `ExpressionNode` but one), so such a validator is superlinear in the size of
# a deep tree.
#
# This ladder builds documents whose one equation is a balanced `+`/`*` tree of
# depth `d` (2^d leaves, each an `index` read), so size and depth grow together
# the way a lowered stencil's do, and times `validate_schema` and the whole
# `load_string`. It runs each depth twice: with the equation in a top-level
# model (reached through `properties` and `items`) and in a subsystem of it
# (reached through `additionalProperties`). It prints the fitted exponent
# d log t / d log n for each: ~1 is linear.
#
#   julia --project=pkg/EarthSciAST.jl bench/schema_validation.jl [d1,d2,...]

using EarthSciAST, JSON3, Printf
const EA = EarthSciAST

say(s) = (println(s); flush(stdout))

function tree(d::Int, k::Ref{Int}, u::String)
    if d == 0
        k[] += 1
        return Dict{String, Any}("op" => "index", "args" => Any[u, Dict{String, Any}("op" => "+", "args" => Any["i", k[] % 3])])
    end
    return Dict{String, Any}("op" => isodd(d) ? "+" : "*", "args" => Any[tree(d - 1, k, u), tree(d - 1, k, u)])
end

function equation(d::Int, u::String)
    faq(expr) = Dict{String, Any}(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict{String, Any}("i" => Dict{String, Any}("from" => "x")), "expr" => expr,
    )
    lhs = faq(
        Dict{String, Any}(
            "op" => "D", "wrt" => "t",
            "args" => Any[Dict{String, Any}("op" => "index", "args" => Any[u, "i"])]
        )
    )
    return Dict{String, Any}("lhs" => lhs, "rhs" => faq(tree(d, Ref(0), u)))
end

function model(eqs)
    return Dict{String, Any}(
        "variables" => Dict{String, Any}(
            "u" => Dict{String, Any}("type" => "unknown", "units" => "1", "default" => 1.0, "shape" => Any["x"])
        ),
        "equations" => eqs,
    )
end

# `nested`: the deep equation sits in subsystem `M.S` rather than in `M`.
function document(d::Int; nested::Bool = false)
    m = if nested
        merge(
            model(Any[equation(1, "M.u")]),
            Dict{String, Any}("subsystems" => Dict{String, Any}("S" => model(Any[equation(d, "M.S.u")])))
        )
    else
        model(Any[equation(d, "M.u")])
    end
    return Dict{String, Any}(
        "esm" => "1.3.0", "metadata" => Dict{String, Any}("name" => "deep"),
        "index_sets" => Dict{String, Any}("x" => Dict{String, Any}("kind" => "interval", "size" => 8)),
        "models" => Dict{String, Any}("M" => m),
    )
end

nodes(x) = x isa AbstractDict ? 1 + sum(nodes, values(x); init = 0) :
    x isa AbstractVector ? sum(nodes, x; init = 0) : 0

function slope(n, t)
    x = log.(Float64.(n)); y = log.(t)
    xm = sum(x) / length(x); ym = sum(y) / length(y)
    return sum((x .- xm) .* (y .- ym)) / sum((x .- xm) .^ 2)
end

function ladder(ds; nested::Bool)
    say(nested ? "equation in subsystem M.S" : "equation in model M")
    n = Int[]; tv = Float64[]; tl = Float64[]
    for d in ds
        doc = document(d; nested); text = JSON3.write(doc)
        raw = EA._to_native_json(JSON3.read(text))
        GC.gc()
        t1 = @elapsed errs = EA.validate_schema(raw)
        isempty(errs) || error("depth $d: the generated document is not schema-valid: $(errs[1])")
        GC.gc()
        t2 = @elapsed EA.load_string(text)
        push!(n, nodes(doc)); push!(tv, t1); push!(tl, t2)
        say(@sprintf("depth %3d  %9d JSON objects  %7.2f MB  validate_schema %8.3f s  load_string %8.3f s", d, n[end], sizeof(text) / 1.0e6, t1, t2))
    end
    length(ds) > 1 && say(@sprintf("fitted exponent: validate_schema %.2f  load_string %.2f", slope(n, tv), slope(n, tl)))
    return
end

function main(args)
    ds = isempty(args) ? [10, 12, 14, 16] : parse.(Int, split(args[1], ","))
    for nested in (false, true)
        EA.load_string(JSON3.write(document(4; nested)))   # compile outside the timings
        ladder(ds; nested)
    end
    return
end

main(ARGS)
