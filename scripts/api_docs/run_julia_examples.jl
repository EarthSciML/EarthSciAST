# Run every example program in docs/api/examples/julia/, each in a fresh
# module so no example can lean on another's bindings, and exit non-zero if
# any of them throws. One Julia process runs them all, so the package loads
# and compiles once.
#
#     julia --project=docs/api/examples/julia scripts/api_docs/run_julia_examples.jl

const EXAMPLES_DIR = normpath(joinpath(@__DIR__, "..", "..", "docs", "api", "examples", "julia"))

function run_examples(dir)
    files = sort!(filter(f -> endswith(f, ".jl"), readdir(dir; join = true)))
    isempty(files) && error("no Julia examples found in $dir")
    failed = String[]
    for file in files
        name = basename(file)
        println("==> running $name")
        mod = Module(Symbol(splitext(name)[1]))
        # A bare `Module` has no `include`; the examples are complete programs
        # that only rely on `using`, so `Base.include` into it is enough.
        try
            t = @elapsed Base.include(mod, file)
            println("    ok ($(round(t; digits = 1)) s)")
        catch err
            push!(failed, name)
            println(stderr, "    FAILED: $name")
            showerror(stderr, err, catch_backtrace())
            println(stderr)
        end
    end
    if isempty(failed)
        println("all $(length(files)) Julia examples passed")
    else
        println(stderr, "FAILED Julia examples: ", join(failed, ", "))
        exit(1)
    end
end

run_examples(EXAMPLES_DIR)
