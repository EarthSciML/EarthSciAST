# Extract the Julia binding's documentation for every spelling that
# `api-surface.json` lists under `julia`, and write the normalized docstring file
# described in docs/api/README.md §2.
#
#     julia --project=docs/api/examples/julia scripts/api_docs/extract_julia.jl OUT.json
#
# Docstrings and signatures come from Julia's own docsystem (`Base.Docs.meta`)
# and method table (`methods`), never from the source text. SciMLBase is loaded
# so the simulation extension's methods and docstrings are part of the surface.

using EarthSciAST
using SciMLBase
using JSON3

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const PKG_ROOT = normpath(pkgdir(EarthSciAST))

# ---------------------------------------------------------------------------
# Docstring lookup
# ---------------------------------------------------------------------------

"""Every `DocStr` attached to `binding`, across all modules that document it
(the package itself and any extension that adds a method docstring), in the
order the docsystem recorded them."""
function docstrs_for(binding::Docs.Binding)
    out = Docs.DocStr[]
    for mod in Docs.modules
        meta = Docs.meta(mod; autoinit = false)
        meta === nothing && continue
        multidoc = get(meta, binding, nothing)
        multidoc === nothing && continue
        for sig in multidoc.order
            push!(out, multidoc.docs[sig])
        end
    end
    return out
end

function raw_text(d::Docs.DocStr)
    if all(x -> x isa AbstractString, d.text)
        return join(d.text)
    end
    # An interpolated docstring: render the parsed Markdown back to text.
    return string(Docs.parsedoc(d))
end

# ---------------------------------------------------------------------------
# Documenter / Julia docstring syntax -> CommonMark (README §2)
# ---------------------------------------------------------------------------

strip_module(name) = replace(name, r"^(EarthSciAST\.)+" => "")

function convert_refs(line::AbstractString)
    # [`x`](@ref)  /  [`EarthSciAST.x`](@ref)
    line = replace(line, r"\[`([^`\]]+)`\]\(@ref\)" =>
        s -> begin
            m = match(r"\[`([^`\]]+)`\]\(@ref\)", s)
            name = strip_module(m.captures[1])
            target = replace(name, r"\(.*\)$" => "")
            "[`$name`](api:$target)"
        end)
    # [text](@ref target)
    line = replace(line, r"\[([^\]]+)\]\(@ref\s+`?([^)`]+)`?\)" =>
        s -> begin
            m = match(r"\[([^\]]+)\]\(@ref\s+`?([^)`]+)`?\)", s)
            "[$(m.captures[1])](api:$(strip_module(strip(m.captures[2]))))"
        end)
    # [text](@ref) with a non-code label: the label is the target
    line = replace(line, r"\[([^\]`]+)\]\(@ref\)" =>
        s -> begin
            m = match(r"\[([^\]`]+)\]\(@ref\)", s)
            "[$(m.captures[1])](api:$(strip_module(m.captures[1])))"
        end)
    return line
end

const ADMONITION = r"^(\s*)!!!\s+(\w+)(?:\s+\"(.*)\")?\s*$"

function to_commonmark(text::AbstractString)
    lines = split(chomp(text), '\n')
    out = String[]
    i = 1
    # Julia's convention: a docstring opens with its signature(s) as a
    # four-space-indented block. Fence it so it renders as Julia.
    sig = String[]
    while i <= length(lines) && startswith(lines[i], "    ")
        push!(sig, lines[i][5:end])
        i += 1
    end
    if !isempty(sig)
        push!(out, "```julia"); append!(out, sig); push!(out, "```")
    end
    infence = false
    fence = ""
    admon_indent = nothing
    while i <= length(lines)
        line = String(lines[i])
        i += 1
        stripped = lstrip(line)
        if !infence && (startswith(stripped, "```") || startswith(stripped, "~~~"))
            infence = true
            fence = stripped[1:3]
            lang = strip(stripped[4:end])
            if startswith(lang, "jldoctest") || startswith(lang, "@example") ||
               startswith(lang, "@repl") || lang == "julia-repl"
                line = replace(line, stripped => fence * "julia")
            elseif lang == "@setup" || startswith(lang, "@setup ")
                line = replace(line, stripped => fence * "julia")
            end
        elseif infence && startswith(stripped, fence)
            infence = false
        elseif !infence
            m = match(ADMONITION, line)
            if m !== nothing
                kind = uppercasefirst(m.captures[2])
                title = m.captures[3] === nothing || isempty(m.captures[3]) ? kind : m.captures[3]
                push!(out, "> **$title**")
                push!(out, ">")
                admon_indent = length(m.captures[1]) + 4
                continue
            end
            m = match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
            if m !== nothing
                line = "**$(m.captures[1])**"
            end
            line = convert_refs(line)
        end
        if admon_indent !== nothing
            pad = " "^admon_indent
            if startswith(line, pad)
                line = "> " * line[admon_indent+1:end]
            elseif isempty(strip(line)) && i <= length(lines) && startswith(lines[i], pad)
                line = ">"
            else
                admon_indent = nothing
            end
        end
        push!(out, line)
    end
    return strip(join(out, '\n'))
end

# ---------------------------------------------------------------------------
# Signatures
# ---------------------------------------------------------------------------

function method_signature(name::AbstractString, m::Method)
    tv, decls, _, _ = Base.arg_decl_parts(m)
    args = String[]
    for (argname, argtype) in decls[2:end]
        s = isempty(argname) ? "" : argname
        isempty(argtype) || (s *= "::" * argtype)
        isempty(s) && (s = "_")
        push!(args, s)
    end
    kws = String.(string.(Base.kwarg_decl(m)))
    sig = "$name(" * join(args, ", ")
    isempty(kws) || (sig *= (isempty(args) ? "; " : "; ") * join(kws, ", "))
    sig *= ")"
    if !isempty(tv)
        sig *= " where {" * join(string.(tv), ", ") * "}"
    end
    return sig
end

function sorted_methods(f)
    ms = collect(methods(f))
    sort!(ms; by = m -> (string(m.file), m.line))
    return ms
end

function signatures_for(name::AbstractString, obj)
    if obj isa Function
        return unique!([method_signature(name, m) for m in sorted_methods(obj)])
    elseif obj isa Type
        t = Base.unwrap_unionall(obj)
        header = if isabstracttype(obj)
            "abstract type $name"
        elseif t isa DataType && ismutabletype(t)
            "mutable struct $name"
        else
            "struct $name"
        end
        if t isa DataType && t.super !== Any
            header *= " <: " * string(Base.unwrap_unionall(obj).super.name.wrapper)
        end
        sigs = [header]
        if !isabstracttype(obj)
            for m in sorted_methods(obj)
                parentmodule(m) === EarthSciAST || continue
                push!(sigs, method_signature(name, m))
            end
        end
        return unique!(sigs)
    else
        # A large NamedTuple registry's full type is a wall of field names
        # that the docstring already describes; name only its kind.
        T = string(typeof(obj))
        length(T) > 120 && (T = string(nameof(typeof(obj))))
        return ["const $name::$T"]
    end
end

# ---------------------------------------------------------------------------
# Source location
# ---------------------------------------------------------------------------

function relpath_repo(path)
    p = string(path)
    isabspath(p) || return nothing
    p = normpath(p)
    startswith(p, REPO_ROOT) || startswith(p, PKG_ROOT) || return nothing
    return relpath(p, REPO_ROOT)
end

function source_for(docs, obj)
    for d in docs
        path = get(d.data, :path, nothing)
        line = get(d.data, :linenumber, nothing)
        if path !== nothing
            rp = relpath_repo(path)
            rp === nothing || return (path = rp, line = line)
        end
    end
    if obj isa Function || obj isa Type
        for m in sorted_methods(obj)
            rp = relpath_repo(m.file)
            rp === nothing || return (path = rp, line = m.line)
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function julia_spellings(manifest)
    out = Tuple{String,String}[]   # (spelling, kind)
    for s in manifest[:symbols]
        haskey(s[:bindings], :julia) || continue
        j = s[:bindings][:julia]
        for sp in (j isa AbstractString ? [j] : j)
            push!(out, (String(sp), String(s[:kind])))
        end
    end
    return out
end

function entry(spelling, kind)
    sym = Symbol(spelling)
    missing_entry = (spelling = spelling, kind = kind, signatures = String[],
                     doc = nothing, source = nothing, native_url = nothing,
                     missing = true)
    isdefined(EarthSciAST, sym) || return missing_entry
    obj = getfield(EarthSciAST, sym)
    binding = Docs.aliasof(Docs.Binding(EarthSciAST, sym))
    docs = docstrs_for(binding)
    doc = isempty(docs) ? nothing :
          join([to_commonmark(raw_text(d)) for d in docs], "\n\n---\n\n")
    return (spelling = spelling, kind = kind,
            signatures = signatures_for(spelling, obj), doc = doc,
            source = source_for(docs, obj), native_url = nothing)
end

function main(outpath)
    manifest = JSON3.read(read(joinpath(REPO_ROOT, "api-surface.json"), String))
    symbols = Any[entry(sp, kind) for (sp, kind) in julia_spellings(manifest)]
    sort!(symbols; by = e -> e.spelling)
    result = (binding = "julia",
              package_version = string(pkgversion(EarthSciAST)),
              extractor = "Base.Docs (Julia $(VERSION))",
              symbols = symbols)
    mkpath(dirname(outpath))
    open(outpath, "w") do io
        JSON3.pretty(io, result)
        println(io)
    end
    nmissing = count(e -> haskey(e, :missing), symbols)
    nnodoc = count(e -> e.doc === nothing, symbols)
    println("wrote $(length(symbols)) Julia spellings to $outpath ",
            "($nnodoc without a docstring, $nmissing not found)")
end

main(isempty(ARGS) ? joinpath(REPO_ROOT, "build", "api-docs", "julia.json") : ARGS[1])
