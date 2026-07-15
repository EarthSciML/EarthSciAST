# Reproducer for the nested-expression-template memory blow-up in the Julia
# binding (EarthSciAST.jl).
#
# A chain of match-less templates T0..T<depth> where each T_i body references
# T_{i-1} twice is inlined at registration by `_compose_template_bodies!`
# (src/template_imports.jl): every reference is expanded by pure substitution
# with deep copies, so the composed body of T_d holds 2^d copies of the leaf.
# The §9.6.3 call-site fixpoint then splices another full copy, and coercion
# to the typed IR copies it again — a few-KB document within every documented
# limit (chain depth <= MAX_TEMPLATE_EXPANSION_DEPTH = 32) expands to millions
# of AST nodes and gigabytes of live memory.
#
# Usage (one depth per process, so Sys.maxrss() is a clean per-depth peak):
#
#   julia --project=pkg/EarthSciAST.jl scripts/repro-nested-template-oom.jl <depth>
#
# Measured BEFORE structural sharing (Julia 1.12.6, x86_64 Linux; logical
# expanded nodes = 2^(depth+3) - 1):
#
#   depth=14  file=3.3KB  nodes=131,071    load= 23s  maxrss=0.87GiB
#   depth=16  file=3.7KB  nodes=524,287    load= 30s  maxrss=1.47GiB
#   depth=18  file=4.0KB  nodes=2,097,151  load= 63s  maxrss=4.39GiB
#   depth=19  file=4.2KB  nodes=4,194,303  load=124s  maxrss=7.95GiB
#   depth=20  file=4.4KB  -> hard OutOfMemoryError() under a 10GiB cap
#
# AFTER (expanded ASTs stored as structurally-shared DAGs; identical
# semantics, tree-equivalent logical size unchanged):
#
#   depth=19  nodes=4,194,303      unique_dag_nodes=26  load=12s  maxrss=0.68GiB
#   depth=30  nodes=8,589,934,591  unique_dag_nodes=37  load=12s  maxrss=0.68GiB
#
# (~12s / 0.68GiB is the package-load baseline of this environment.)

using JSON3
using EarthSciAST

function apply_node(name)
    Dict("op" => "apply_expression_template", "args" => [],
         "name" => name, "bindings" => Dict{String,Any}())
end

"""Write a fixture with a fan-out-2 template chain of the given depth."""
function gen(depth::Int, path::String)
    templates = Dict{String,Any}()
    templates["T0"] = Dict(
        "params" => [],
        "body" => Dict("op" => "*", "args" => [
            1.8e-12,
            Dict("op" => "exp", "args" => [
                Dict("op" => "/", "args" => [
                    Dict("op" => "-", "args" => [1500.0]), "T"])])]))
    for i in 1:depth
        templates["T$i"] = Dict(
            "params" => [],
            "body" => Dict("op" => "+", "args" => [
                apply_node("T$(i-1)"), apply_node("T$(i-1)")]))
    end
    doc = Dict(
        "esm" => "0.4.0",
        "metadata" => Dict(
            "name" => "nested_templates_depth_$depth",
            "description" => "Nested expression-template chain, fan-out 2, depth $depth",
            "authors" => ["repro"]),
        "reaction_systems" => Dict(
            "chem" => Dict(
                "species" => Dict(
                    "A" => Dict("default" => 1.0),
                    "B" => Dict("default" => 0.0)),
                "parameters" => Dict(
                    "T" => Dict("default" => 298.15, "units" => "K")),
                "expression_templates" => templates,
                "reactions" => [Dict(
                    "id" => "R1",
                    "substrates" => [Dict("species" => "A", "stoichiometry" => 1)],
                    "products" => [Dict("species" => "B", "stoichiometry" => 1)],
                    "rate" => apply_node("T$depth"))])))
    open(io -> JSON3.write(io, doc), path, "w")
    return path
end

# Logical (tree-semantics) node count, memoized on node identity so it stays
# linear when the expanded AST is stored as a shared DAG; and the unique
# (physical) node count of that DAG.
function count_nodes(e::EarthSciAST.ASTExpr,
                     memo::IdDict{Any,Int128}=IdDict{Any,Int128}())::Int128
    e isa EarthSciAST.OpExpr || return Int128(1)
    r = get(memo, e, nothing)
    r === nothing || return r
    n = Int128(1) + sum(a -> count_nodes(a, memo), e.args; init=Int128(0))
    memo[e] = n
    return n
end

function count_unique(e::EarthSciAST.ASTExpr, seen::IdDict{Any,Nothing}=IdDict{Any,Nothing}())
    haskey(seen, e) && return length(seen)
    seen[e] = nothing
    e isa EarthSciAST.OpExpr && foreach(a -> count_unique(a, seen), e.args)
    return length(seen)
end

function main()
    depth = isempty(ARGS) ? 16 : parse(Int, ARGS[1])
    path = joinpath(mktempdir(), "nested_d$(depth).esm")
    gen(depth, path)
    t = @elapsed file = EarthSciAST.load(path)
    rate = file.reaction_systems["chem"].reactions[1].rate
    println("depth=$depth  file_size=$(filesize(path))B  " *
            "expanded_rate_nodes=$(count_nodes(rate))  " *
            "unique_dag_nodes=$(count_unique(rate))  " *
            "load_time=$(round(t, digits=1))s  " *
            "maxrss=$(round(Sys.maxrss() / 2^30, digits=2))GiB")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
