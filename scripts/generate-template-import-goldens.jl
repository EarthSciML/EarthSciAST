#!/usr/bin/env julia
# Regenerate the esm-spec §9.7 conformance goldens (template-library imports +
# load-time metaparameters) from the Julia reference implementation.
#
#   julia --project=packages/EarthSciSerialization.jl scripts/generate-template-import-goldens.jl
#
# Writes (deterministic: sorted keys, 2-space indent):
#   tests/conformance/expression_templates/import_smoke/expanded.esm
#   tests/conformance/expression_templates/import_diamond/expanded.esm
#   tests/conformance/expression_templates/import_order_determinism/expanded_import_order.esm
#   tests/conformance/expression_templates/import_order_determinism/expanded_priority_override.esm
#   tests/conformance/expression_templates/metaparameter_resolutions/expanded_n4.esm
#   tests/conformance/expression_templates/metaparameter_resolutions/expanded_n8.esm
#   tests/invalid/template_imports/body_chain_too_deep.esm   (33-template chain, generated)
#
# The import fixtures are expanded through the raw §9.7 pipeline
# (resolve_template_machinery → lower_expression_templates) so the golden is
# the post-lowering document; the metaparameter_resolutions wrappers go
# through the full typed load (subsystem-ref `bindings` resolve in the typed
# phase) and are re-emitted with `serialize_esm_file`.

using EarthSciSerialization
using EarthSciSerialization: resolve_template_machinery, lower_expression_templates,
    serialize_esm_file, JSONLikeDict
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

# Raw §9.7 pipeline: fixture → resolved → lowered document view.
function _expand_raw(fixture_path::String)
    raw = JSON3.read(read(fixture_path, String))
    resolved = resolve_template_machinery(raw, dirname(fixture_path))
    out = lower_expression_templates(resolved === nothing ? raw : resolved)
    return out isa JSONLikeDict ? getfield(out, :data) : out
end

for (dir, fixture, golden) in [
    ("import_smoke", "fixture.esm", "expanded.esm"),
    ("import_diamond", "fixture.esm", "expanded.esm"),
    ("import_order_determinism", "fixture_import_order.esm", "expanded_import_order.esm"),
    ("import_order_determinism", "fixture_priority_override.esm", "expanded_priority_override.esm"),
]
    _write_golden(joinpath(CONF, dir, golden),
                  _expand_raw(joinpath(CONF, dir, fixture)))
end

# Subsystem-ref bindings (esm-spec §9.7.6 site 3): full typed load, then emit.
for (wrapper, golden) in [("wrapper_n4.esm", "expanded_n4.esm"),
                          ("wrapper_n8.esm", "expanded_n8.esm")]
    file = EarthSciSerialization.load(joinpath(CONF, "metaparameter_resolutions", wrapper))
    _write_golden(joinpath(CONF, "metaparameter_resolutions", golden),
                  serialize_esm_file(file))
end

# tests/invalid/template_imports/body_chain_too_deep.esm — a 33-template
# body-reference chain (one over MAX_TEMPLATE_EXPANSION_DEPTH = 32).
let n = EarthSciSerialization.MAX_TEMPLATE_EXPANSION_DEPTH + 1
    tpl = Dict{String,Any}()
    for i in 1:n
        name = "c_" * lpad(i, 2, '0')
        tpl[name] = i == n ? Dict{String,Any}("params" => Any[], "body" => 1) :
            Dict{String,Any}("params" => Any[],
                "body" => Dict{String,Any}(
                    "op" => "apply_expression_template", "args" => Any[],
                    "name" => "c_" * lpad(i + 1, 2, '0'),
                    "bindings" => Dict{String,Any}()))
    end
    doc = Dict{String,Any}(
        "esm" => "0.8.0",
        "metadata" => Dict{String,Any}(
            "name" => "body_chain_too_deep",
            "description" => "GENERATED (scripts/generate-template-import-goldens.jl): a $(n)-template body-reference chain c_01 -> ... -> c_$(lpad(n, 2, '0')); the longest chain exceeds MAX_TEMPLATE_EXPANSION_DEPTH = $(n - 1) templates (template_body_expansion_too_deep, esm-spec 9.7.3)."),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "expression_templates" => tpl,
            "variables" => Dict{String,Any}(
                "x" => Dict{String,Any}("type" => "state", "units" => "1", "default" => 0.0)),
            "equations" => Any[Dict{String,Any}(
                "lhs" => Dict{String,Any}("op" => "D", "args" => Any["x"], "wrt" => "t"),
                "rhs" => Dict{String,Any}("op" => "-", "args" => Any["x"]))])))
    _write_golden(joinpath(ROOT, "tests", "invalid", "template_imports",
                           "body_chain_too_deep.esm"), doc)
end
