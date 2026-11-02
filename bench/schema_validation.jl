# HOW DOES LOADING SCALE WITH EXPRESSION SIZE AND DEPTH?
#
# `load_string` validates the parsed document against esm-schema.json before
# anything else. A flattened stencil operator is a deep expression (ReSEACT's
# lowered advection term is ~35 levels and 1.7×10⁵ nodes, 6 MB of JSON), and
# schema validation of it once took 95 of the 105 s its document needed to
# load: JSONSchema.jl renders the instance path into a string for every
# failed check, and a valid expression fails several per node (the `number`
# and `string` branches of `Expression`'s `oneOf`, every `if` of
# `ExpressionNode` but one), a cost of the depth per check.
#
# This ladder builds documents whose one equation is a balanced `+`/`*` tree of
# depth `d` (2^d leaves, each an `index` read), so size and depth grow together
# the way a lowered stencil's do, and times `validate_schema` and the whole
# `load_string`. It prints the fitted exponent d log t / d log n: ~1 is linear.
#
#   julia --project=pkg/EarthSciAST.jl bench/schema_validation.jl [d1,d2,...]

using EarthSciAST, JSON3, Printf
const EA = EarthSciAST

say(s) = (println(s); flush(stdout))

function tree(d::Int, k::Ref{Int})
    if d == 0
        k[] += 1
        return Dict{String, Any}("op" => "index", "args" => Any["M.u", Dict{String, Any}("op" => "+", "args" => Any["i", k[] % 3])])
    end
    return Dict{String, Any}("op" => isodd(d) ? "+" : "*", "args" => Any[tree(d - 1, k), tree(d - 1, k)])
end

function document(d::Int)
    rhs = Dict{String, Any}(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict{String, Any}("i" => Dict{String, Any}("from" => "x")),
        "expr" => tree(d, Ref(0)),
    )
    lhs = Dict{String, Any}(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict{String, Any}("i" => Dict{String, Any}("from" => "x")),
        "expr" => Dict{String, Any}(
            "op" => "D", "wrt" => "t",
            "args" => Any[Dict{String, Any}("op" => "index", "args" => Any["M.u", "i"])]
        ),
    )
    return Dict{String, Any}(
        "esm" => "1.3.0", "metadata" => Dict{String, Any}("name" => "deep"),
        "index_sets" => Dict{String, Any}("x" => Dict{String, Any}("kind" => "interval", "size" => 8)),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "u" => Dict{String, Any}("type" => "unknown", "units" => "1", "default" => 1.0, "shape" => Any["x"])
                ),
                "equations" => Any[Dict{String, Any}("lhs" => lhs, "rhs" => rhs)],
            )
        ),
    )
end

nodes(x) = x isa AbstractDict ? 1 + sum(nodes, values(x); init = 0) :
    x isa AbstractVector ? sum(nodes, x; init = 0) : 0

function slope(n, t)
    x = log.(Float64.(n)); y = log.(t)
    xm = sum(x) / length(x); ym = sum(y) / length(y)
    return sum((x .- xm) .* (y .- ym)) / sum((x .- xm) .^ 2)
end

function main(args)
    ds = isempty(args) ? [10, 12, 14, 16] : parse.(Int, split(args[1], ","))
    EA.load_string(JSON3.write(document(4)))       # compile outside the timings
    n = Int[]; tv = Float64[]; tl = Float64[]
    for d in ds
        doc = document(d); text = JSON3.write(doc)
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

main(ARGS)
