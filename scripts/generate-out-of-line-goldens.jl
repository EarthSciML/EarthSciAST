#!/usr/bin/env julia
# Regenerate the Option-B (reference-preserving) conformance goldens for the
# out-of-line-expression-templates RFC (esm-spec §9.6.4 rule 5, §9.6.7).
#
#   julia --project=pkg/EarthSciAST.jl scripts/generate-out-of-line-goldens.jl
#
# Each fixture's `emitted.esm` is the canonical reference-preserving emit
# (`emit_document` → `emit_esm_string`): surviving call sites verbatim,
# referenced match-less templates materialized, imports consumed, esm stamped
# 0.9.0. Byte-identical across all five bindings (the emit ordering /
# canonicalization contract, §9.6.4 rule 5).

using EarthSciAST
using EarthSciAST: emit_document, emit_esm_string
using JSON3

const ROOT = normpath(joinpath(@__DIR__, ".."))
const CONF = joinpath(ROOT, "tests", "conformance", "expression_templates")

function _write_emit(dir::String, fixture::String, golden::String)
    fp = joinpath(CONF, dir, fixture)
    raw = JSON3.read(read(fp, String))
    doc = emit_document(raw, dirname(fp))
    s = emit_esm_string(doc)
    open(joinpath(CONF, dir, golden), "w") do io
        write(io, s)
    end
    println("wrote ", relpath(joinpath(CONF, dir, golden), ROOT))
end

for (dir, fixture, golden) in [
    ("emit_materialized_registry", "fixture.esm", "emitted.esm"),
    ("emit_rename_dotted_keys", "fixture.esm", "emitted.esm"),
    ("eager_target_bearing", "fixture.esm", "emitted.esm"),
    ("opacity_negative", "fixture.esm", "emitted.esm"),
    ("opacity_priority_shadowing", "fixture.esm", "emitted.esm"),
]
    _write_emit(dir, fixture, golden)
end
