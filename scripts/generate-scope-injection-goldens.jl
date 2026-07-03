#!/usr/bin/env julia
# Regenerate the esm-spec §9.7.10 scope-directed template-injection conformance
# goldens (RFC docs/content/rfcs/scoped-template-injection.md) from the Julia
# reference implementation.
#
#   julia --project=packages/EarthSciSerialization.jl scripts/generate-scope-injection-goldens.jl
#
# Writes (deterministic: sorted keys, 2-space indent):
#   tests/conformance/expression_templates/inject_subsystem_ref/expanded.esm
#   tests/conformance/expression_templates/inject_coupling_entry/expanded.esm
#   tests/conformance/expression_templates/inject_test_block/roundtrip.esm
#
# All three forms are driven through the FULL typed load, then re-emitted with
# `serialize_esm_file`: form A (subsystem-ref) resolves in the typed subsystem
# pass, form B (coupling-entry) injection is applied inside `load` before the
# fixpoint, and form C (test block) round-trips with the component's rewrite
# targets intact and each test's import field preserved.

using EarthSciSerialization
using EarthSciSerialization: serialize_esm_file
using JSON3

const ROOT = normpath(joinpath(@__DIR__, ".."))
const CONF = joinpath(ROOT, "tests", "conformance", "expression_templates")

_norm(x) =
    (x isa AbstractDict || x isa JSON3.Object) ?
        Dict{String,Any}(string(k) => _norm(v) for (k, v) in pairs(x)) :
    (x isa AbstractVector || x isa JSON3.Array) ? Any[_norm(v) for v in x] : x

# Canonical writer: object keys sorted, arrays in order, scalars via JSON3.
function _write_sorted(io::IO, x, indent::Int)
    pad = "  "^indent
    pad1 = "  "^(indent + 1)
    if x isa AbstractDict
        isempty(x) && return print(io, "{}")
        print(io, "{\n")
        ks = sort(collect(keys(x)))
        for (i, k) in enumerate(ks)
            print(io, pad1, JSON3.write(string(k)), ": ")
            _write_sorted(io, x[k], indent + 1)
            i < length(ks) && print(io, ",")
            print(io, "\n")
        end
        print(io, pad, "}")
    elseif x isa AbstractVector
        isempty(x) && return print(io, "[]")
        print(io, "[\n")
        for (i, v) in enumerate(x)
            print(io, pad1)
            _write_sorted(io, v, indent + 1)
            i < length(x) && print(io, ",")
            print(io, "\n")
        end
        print(io, pad, "]")
    else
        print(io, JSON3.write(x))
    end
end

function _write_golden(path::String, doc)
    open(path, "w") do io
        _write_sorted(io, _norm(doc), 0)
        print(io, "\n")
    end
    println("wrote ", relpath(path, ROOT))
end

for (dir, fixture, golden) in [
    ("inject_subsystem_ref", "fixture.esm", "expanded.esm"),
    ("inject_coupling_entry", "fixture.esm", "expanded.esm"),
    ("inject_test_block", "fixture.esm", "roundtrip.esm"),
]
    file = EarthSciSerialization.load(joinpath(CONF, dir, fixture))
    _write_golden(joinpath(CONF, dir, golden), serialize_esm_file(file))
end
