# The Julia batch driver of the document-format gate
# (scripts/run-document-format-gate.py). Run with the package's project:
#
#     julia --project=pkg/EarthSciAST.jl julia_driver.jl print MANIFEST OUT
#     julia --project=pkg/EarthSciAST.jl julia_driver.jl parse MANIFEST OUT

using EarthSciAST
using JSON3

# Read straight into Dict{String,Any} and Vector{Any}, the shapes the document
# functions take. JSON3's lazy objects key on Symbols, and a Symbol cannot hold
# the NUL byte some security fixtures put in a key.
readjson(path) = JSON3.read(read(path, String), Dict{String, Any})

errtext(e) = first(split(sprint(showerror, e), '\n'))

const EXT = ("markdown" => (:markdown, "md"), "typst" => (:typst, "typ"))

function run_print(items, out)
    for item in items
        stem = joinpath(out, item["id"])
        canon = try
            c = canonicalize_document(readjson(item["path"]))
            write("$stem.canon.json", JSON3.write(c))
            c
        catch e
            write("$stem.canon.error", errtext(e))
            continue
        end
        for (_, (fmt, ext)) in EXT
            try
                write("$stem.$ext", print_document(canon, fmt))
            catch e
                write("$stem.$ext.error", errtext(e))
            end
        end
    end
    return
end

function run_parse(items, out)
    formats = Dict(EXT)
    for item in items
        stem = joinpath(out, item["id"])
        try
            doc = parse_document(read(item["path"], String), first(formats[item["format"]]))
            write("$stem.json", JSON3.write(doc))
        catch e
            write("$stem.error", errtext(e))
        end
    end
    return
end

function main(args)
    mode, manifest, out = args
    items = JSON3.read(read(manifest, String), Vector{Dict{String, String}})
    return mode == "print" ? run_print(items, out) :
        mode == "parse" ? run_parse(items, out) : error("unknown mode $mode")
end

main(ARGS)
