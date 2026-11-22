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
    return println("wrote ", relpath(joinpath(CONF, dir, golden), ROOT))
end

for (dir, fixture, golden) in [
        ("emit_materialized_registry", "fixture.esm", "emitted.esm"),
        ("emit_rename_dotted_keys", "fixture.esm", "emitted.esm"),
        ("rewrite_in_template_body", "fixture.esm", "emitted.esm"),
        ("opacity_negative", "fixture.esm", "emitted.esm"),
        ("opacity_priority_shadowing", "fixture.esm", "emitted.esm"),
        # Rules write references (esm-spec §9.6.3 constraint 7, §9.6.4 rule 3;
        # CONFORMANCE_SPEC §5.60).
        ("rule_writes_reference", "fixture.esm", "emitted.esm"),
        ("template_instance_variants", "fixture.esm", "emitted.esm"),
        ("opacity_rule_replacement", "fixture.esm", "emitted.esm"),
        ("rewrite_depth_through_bodies", "chain_depth_64.esm", "emitted_chain_depth_64.esm"),
        ("unlowered_in_template_body", "fixture.esm", "emitted.esm"),
        ("rewrite_shared_by_unreached_entry", "fixture.esm", "emitted.esm"),
    ]
    _write_emit(dir, fixture, golden)
end

# The `expanded.esm` goldens that only this revision's semantics can produce
# (CONFORMANCE_SPEC §5.60): `opacity_rule_replacement/` pins the cases where it
# differs from the in-place engine, the depth-64 chain is one the in-place
# engine rejected (it allowed 63 productive passes), and
# `rewrite_shared_by_unreached_entry/` was added after that engine was gone. Every other `expanded*.esm`
# golden was written by the in-place engine and is never regenerated.
function _write_expanded(dir::String, fixture::String, golden::String)
    fp = joinpath(CONF, dir, fixture)
    raw = JSON3.read(read(fp, String))
    resolved = EarthSciAST.resolve_template_machinery(raw, dirname(fp))
    loaded = EarthSciAST.lower_expression_templates(resolved === nothing ? raw : resolved)
    s = emit_esm_string(EarthSciAST.Expand(loaded))
    open(joinpath(CONF, dir, golden), "w") do io
        write(io, s)
    end
    return println("wrote ", relpath(joinpath(CONF, dir, golden), ROOT))
end

for (dir, fixture, golden) in [
        ("opacity_rule_replacement", "fixture.esm", "expanded.esm"),
        ("rewrite_depth_through_bodies", "chain_depth_64.esm", "expanded_chain_depth_64.esm"),
        ("rewrite_shared_by_unreached_entry", "fixture.esm", "expanded.esm"),
    ]
    _write_expanded(dir, fixture, golden)
end
