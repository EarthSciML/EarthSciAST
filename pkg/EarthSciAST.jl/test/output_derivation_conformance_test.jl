# Cross-language SIMULATION-OUTPUT DERIVATION conformance
# (`tests/conformance/output_derivation/`, streaming-output-sinks RFC §7–§9, §16.12).
#
# The derivation turns (.esm document + flat state element names + a caller-named
# observed subset) into the dimension-labeled, CF-annotated plan a Zarr writer is
# handed. It lives in two languages — `src/data_output.jl` here and
# `pkg/earthsci-ast-rs/src/data_output.rs` there — and until this corpus there was
# NO cross-language gate on it at any level: EarthSciIO's `conformance/write_spec.json`
# is an ALREADY-DERIVED schema (`dims`/`time_dim`/`coords`/`vars`/`chunk_shape`/
# `shard_shape`), so the write corpus starts DOWNSTREAM of derivation and drives the
# three writers from a hand-authored shape. A derivation corpus's output type is that
# write corpus's input type, so the two chain end to end:
#
#   .esm ──[derivation, this corpus]──▶ OutputSchema ──[writers, EarthSciIO]──▶ Zarr
#
# Both bindings assert against the SAME committed golden, so agreement is enforced
# through it. The Rust twin is `pkg/earthsci-ast-rs/tests/output_derivation_conformance.rs`.
#
# What it pins, and why each clause is here:
#   • a scalar is genuinely 0-spatial-dimensional (shape `[]`, dims exactly
#     `[time_dim]`) and every scalar shares ONE grid — the divergence §16.12 records;
#   • grids are emergent, clustered by SORTED spatial-dim signature, in first-seen
#     order — `mixed` must produce exactly three, not five;
#   • the on-disk dim order is the record axis FIRST, then spatial axes;
#   • the record axis is `domain.independent_variable`, not the literal "time";
#   • the column-major cell-key inversion, compared on the row-major representation;
#   • RFC decision 8: an observed field with a slot is written only when requested.

using Test
using EarthSciAST
import JSON3

const _OD_ROOT = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance",
                          "output_derivation")

_od_json(path) = JSON3.read(read(path, String))
# The derivation reads an ordinary nested `AbstractDict`, so documents come back
# as plain `Dict{String,Any}` rather than JSON3's own object type.
_od_doc(path) = JSON3.read(read(path, String), Dict{String,Any})

# The plan, rendered into the golden's language-neutral JSON shape. Deliberately a
# projection of the PRODUCTION `derive_output_plan` result — nothing here re-derives
# anything, so a bug in the derivation cannot hide behind the adapter.
function _od_render(plan::OutputPlan)
    grids = Any[]
    for g in plan.grids
        push!(grids, Dict{String,Any}(
            "dims" => Any[Any[first(p), last(p)] for p in g.dims],
            "time_dim" => g.time_dim,
            "coords" => Any[Dict{String,Any}(
                "name" => c.name,
                "values" => Float64[v for v in c.values],
                "attrs" => Dict{String,Any}(String(k) => v for (k, v) in c.attrs),
            ) for c in g.coords],
            "vars" => Any[Dict{String,Any}(
                "name" => v.name,
                "dims" => String[d for d in v.dims],
                "dtype" => v.dtype,
                "attrs" => Dict{String,Any}(String(k) => v2 for (k, v2) in v.attrs),
                "shape" => Int[s for s in v.gridding.shape],
                # 0-based, row-major — the corpus's one shared representation.
                "flat_indices" => Int[i - 1 for i in row_major_flat_indices(v.gridding)],
            ) for v in g.vars],
        ))
    end
    return grids
end

# Golden JSON3 objects -> the same plain-Julia shape `_od_render` produces, so the
# comparison is on values and never on JSON3's own types.
function _od_expected(grids)
    return Any[Dict{String,Any}(
        "dims" => Any[Any[String(d[1]), Int(d[2])] for d in g["dims"]],
        "time_dim" => String(g["time_dim"]),
        "coords" => Any[Dict{String,Any}(
            "name" => String(c["name"]),
            "values" => Float64[Float64(v) for v in c["values"]],
            "attrs" => Dict{String,Any}(String(k) => v for (k, v) in c["attrs"]),
        ) for c in g["coords"]],
        "vars" => Any[Dict{String,Any}(
            "name" => String(v["name"]),
            "dims" => String[String(d) for d in v["dims"]],
            "dtype" => String(v["dtype"]),
            "attrs" => Dict{String,Any}(String(k) => v2 for (k, v2) in v["attrs"]),
            "shape" => Int[Int(s) for s in v["shape"]],
            "flat_indices" => Int[Int(i) for i in v["flat_indices"]],
        ) for v in g["vars"]],
    ) for g in grids]
end

@testset "output-derivation conformance (RFC §7–§9, §16.12)" begin
    manifest = _od_json(joinpath(_OD_ROOT, "manifest.json"))
    @test manifest["category"] == "output_derivation_conformance"
    @test "julia" in manifest["bindings_required"]
    @test !isempty(manifest["cases"])

    for case in manifest["cases"]
        id = String(case["id"])
        @testset "$id" begin
            doc = _od_doc(joinpath(_OD_ROOT, String(case["fixture"])))
            golden = _od_json(joinpath(_OD_ROOT, String(case["golden"])))
            slots = String[String(s) for s in case["slot_names"]]
            observed = String[String(s) for s in case["observed"]]

            # `derive_output_plan` takes a var_map (name => flat index); the manifest
            # lists slot names in flat order, so index i (1-based here, 0-based in the
            # golden's `flat_indices`) is position i.
            var_map = Dict{String,Int}(s => i for (i, s) in enumerate(slots))
            @test length(var_map) == length(slots)   # no duplicate slot names

            plan = derive_output_plan(doc, var_map; observed = observed)
            @test _od_render(plan) == _od_expected(golden["grids"])
        end
    end

    # The clause the corpus exists for, asserted directly so a regression names
    # itself rather than showing up as a golden diff.
    @testset "a scalar carries no synthetic axis and scalars share one grid" begin
        doc = _od_doc(joinpath(_OD_ROOT, "fixtures", "scalar_0d.esm"))
        plan = derive_output_plan(doc, Dict("Box.T" => 1, "Box.C" => 2, "Box.E" => 3))
        @test length(plan.grids) == 1               # NOT one grid per scalar
        @test isempty(plan.grids[1].dims)           # no <base>_d0 axes
        for v in plan.grids[1].vars
            @test v.dims == ["time"]
            @test isempty(v.gridding.shape)
        end
    end

    # Density: a hole or a double-covered cell is refused, not written out as if it
    # were right (the Julia derivation used to derive the shape from the max index
    # and never check coverage).
    @testset "an incomplete or double-covered grid is refused" begin
        @test_throws OutputError derive_output_gridding(
            Dict("u[1,1]" => 1, "u[2,1]" => 2, "u[1,2]" => 3))       # 3 cells of 4
        # Cell count matches the grid, but two keys name the same cell (leading
        # zeros make the STRINGS distinct while the INDICES collide), so the count
        # check alone would pass it through.
        @test_throws OutputError derive_output_gridding(
            Dict("u[1,1]" => 1, "u[2,2]" => 2, "u[01,1]" => 3, "u[2,02]" => 4))
        @test_throws OutputError derive_output_gridding(Dict("u[0]" => 1))
    end
end
