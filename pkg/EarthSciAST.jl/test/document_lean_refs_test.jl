# The docstrings under src/document/ open with the name of the Lean definition
# each function ports (`Math.isLetter`), the only link from the Julia port to
# its specification in formal/Esm/Document. Every such name must resolve to a
# declaration under formal/: a `def`, `abbrev`, `theorem`, `structure`,
# `inductive`, `class` or `instance`, one of an inductive's constructors or a
# structure's fields, named by any suffix of its namespaced name. A Lean core
# function (the `LEAN_CORE` namespaces) resolves without a declaration.

using Test
include("testutils.jl")  # TESTUTILS_REPO_ROOT

const LEAN_CORE = ("String", "List", "Char", "Nat", "Int", "Option", "Array")

const LEAN_DECL = r"^\s*(?:@\[[^\]]*\]\s*)?(?:(?:private|protected|noncomputable|partial|unsafe|nonrec)\s+)*(def|abbrev|theorem|lemma|structure|inductive|class|instance|opaque)\s+([A-Za-z_][A-Za-z0-9_.?!'₀-₉]*)"

function lean_names(dir::AbstractString)
    names = Set{String}()
    for (root, _, files) in walkdir(dir), f in files
        endswith(f, ".lean") || continue
        ns = String[]
        holder = nothing  # the inductive or structure whose body is being read
        for line in eachline(joinpath(root, f))
            m = match(r"^\s*namespace\s+(\S+)", line)
            if m !== nothing
                push!(ns, m[1])
                continue
            end
            m = match(r"^\s*end\s+(\S+)\s*$", line)
            if m !== nothing && !isempty(ns) && ns[end] == m[1]
                pop!(ns)
                continue
            end
            m = match(LEAN_DECL, line)
            if m !== nothing
                fq = join([ns; m[2]], ".")
                push!(names, fq)
                holder = m[1] in ("inductive", "structure", "class") ? fq : nothing
                continue
            end
            holder === nothing && continue
            m = match(r"^\s*\|\s*([A-Za-z_][A-Za-z0-9_?!']*)", line)
            m === nothing && (m = match(r"^\s+([a-z_][A-Za-z0-9_?!']*)\s*:", line))
            m === nothing || push!(names, string(holder, ".", m[1]))
        end
    end
    suffixes = Set{String}()
    for n in names
        parts = split(n, '.')
        for i in eachindex(parts)
            push!(suffixes, join(parts[i:end], "."))
        end
    end
    return suffixes
end

@testset "src/document docstrings name Lean definitions that exist" begin
    known = lean_names(joinpath(TESTUTILS_REPO_ROOT, "formal"))
    @test length(known) > 1000
    src = joinpath(@__DIR__, "..", "src", "document")
    unresolved = String[]
    nrefs = 0
    for (root, _, files) in walkdir(src), f in files
        endswith(f, ".jl") || continue
        for (i, line) in enumerate(eachline(joinpath(root, f)))
            m = match(r"^\"\"\"`([A-Za-z][A-Za-z0-9_.?!']*)`", line)
            (m === nothing || !occursin('.', m[1])) && continue
            nrefs += 1
            ref = m[1]
            (ref in known || first(split(ref, '.')) in LEAN_CORE) && continue
            push!(unresolved, "$(relpath(joinpath(root, f), src)):$i `$ref`")
        end
    end
    @test nrefs > 500
    @test isempty(unresolved)
    isempty(unresolved) || @info "docstrings naming no Lean definition" unresolved
end
