#!/usr/bin/env julia
# Julia geometry-conformance adapter (CONFORMANCE_SPEC.md §5.8.6). The thin bridge
# the cross-binding geometry harness (scripts/run-geometry-conformance.py) invokes
# to exercise the REAL Julia conservative-regridding assembly
# (EarthSciSerialization.build_regridder / candidate_overlap_pairs, bead
# ess-my4.4.6) over the shared golden fixtures in
# tests/conformance/geometry/manifest.json. The runner discovers it via
# $EARTHSCI_GEOMETRY_ADAPTER_JULIA or as earthsci-geometry-adapter-julia on PATH,
# and calls:
#
#     <adapter> --manifest <manifest.json> --output <result.json>
#
# For each fixture it builds the regridder over inputs.canonical and emits the
# broad-phase candidate overlap-pair set (Julia's NATIVE 1-based emission base —
# the runner normalizes via base_pin: julia=1), the post-floor per-pair overlap
# areas A_ij, the partition-of-unity residual, and (when the fixture supplies
# F_src + src_areas) the global-conservation residual. For every adversarial
# inputs.variants payload it emits the candidate set, which the runner remaps and
# asserts collapses to the golden. Keep this thin — the contract lives in
# src/conservative_regrid.jl, not here.

using EarthSciSerialization
const ESS = EarthSciSerialization
import JSON3

# Best-effort: loading GeometryOps + GeoInterface triggers the
# EarthSciSerializationGeometryOpsExt extension that powers the spherical /
# geodesic clip. They are weakdeps, so this may be unavailable under the plain
# package environment — in that case the narrow phase for non-planar fixtures
# degrades gracefully (candidate set still emitted) exactly like the Python
# adapter without `spherely`. The planar manifold needs no backend.
try
    @eval import GeometryOps, GeoInterface
catch
end

# Did the narrow-phase clip fail only because its geometry backend is absent
# (vs a genuine clip bug, which must propagate)?
backend_unavailable(e) = e isa ESS.GeometryError && occursin("backend", sprint(showerror, e))

function parse_args(argv)
    manifest = nothing
    output = nothing
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--manifest"
            manifest = argv[i+1]; i += 2
        elseif a == "--output"
            output = argv[i+1]; i += 2
        else
            error("geometry_adapter: unknown argument $(repr(a))")
        end
    end
    (manifest === nothing || output === nothing) &&
        error("geometry_adapter: --manifest and --output are required")
    return manifest, output
end

to_native(x::JSON3.Object) = Dict{String,Any}(string(k) => to_native(v) for (k, v) in x)
to_native(x::JSON3.Array) = Any[to_native(v) for v in x]
to_native(x) = x

# Convert a manifest polygon ([[x,y], ...]) to the N×2 Float64 matrix the
# geometry kernel expects.
to_poly(poly) = Float64[poly[i][j] for i in 1:length(poly), j in 1:2]

# The §5.8.2 sliver floor atol ≈ factor·R² for this fixture (R = characteristic
# length, default 1) — the same value the runner uses, so slivers floor identically.
function fixture_atol(fx, tolerances)
    factor = get(tolerances, "area_atol_factor", 1e-15)
    r = get(fx, "characteristic_length", 1.0)
    return Float64(factor) * Float64(r) * Float64(r)
end

# Candidate overlap-pair set for a payload (canonical or a permuted variant),
# emitted in Julia's native 1-based base.
function candidate_pairs(payload, dx, dy)
    src = [to_poly(p) for p in payload["src"]]
    tgt = [to_poly(p) for p in payload["tgt"]]
    pairs = ESS.candidate_overlap_pairs(src, tgt, dx, dy)
    return [[p[1], p[2]] for p in pairs]
end

function compute_canonical(fx, tolerances)
    payload = fx["inputs"]["canonical"]
    src = [to_poly(p) for p in payload["src"]]
    tgt = [to_poly(p) for p in payload["tgt"]]
    dx = Float64(fx["dx"]); dy = Float64(fx["dy"])
    manifold = fx["manifold"]
    atol = fixture_atol(fx, tolerances)

    # Broad phase first — pure integer binning, no geometry backend. This is the
    # byte-identical candidate set the gate's PRIMARY assertion rides on, so it is
    # always emitted even when the narrow-phase clip backend is missing.
    record = Dict{String,Any}(
        "candidate_pairs" => candidate_pairs(payload, dx, dy),
    )

    r = try
        ESS.build_regridder(src, tgt; manifold = manifold, dx = dx, dy = dy, atol = atol)
    catch e
        if backend_unavailable(e)
            record["narrow_phase_unavailable"] = sprint(showerror, e)
            return record
        end
        rethrow()
    end

    # Any[...] keeps the (i, j) indices as integers in the JSON (a plain [i, j,
    # area] vector would promote them to Float64); the runner keys area lookups on
    # the integer pair.
    record["areas"] = [Any[i, j, r.A_ij[i, j]] for (i, j) in r.candidate_pairs]
    pou_res = ESS.partition_of_unity_residual(r)
    record["partition_of_unity_max_residual"] = isempty(pou_res) ? 0.0 : maximum(abs.(pou_res))

    if haskey(fx, "F_src") && haskey(fx, "src_areas")
        f_src = Float64.(fx["F_src"])
        src_areas = Float64.(fx["src_areas"])
        record["conservation_residual"] = ESS.conservation_residual(r, f_src, src_areas)
    end
    return record
end

function compute_fixture(fx, tolerances)
    record = compute_canonical(fx, tolerances)
    dx = Float64(fx["dx"]); dy = Float64(fx["dy"])
    variants = get(fx["inputs"], "variants", Dict{String,Any}())
    if !isempty(variants)
        record["variants"] = Dict{String,Any}(
            vname => Dict{String,Any}("candidate_pairs" => candidate_pairs(vpayload, dx, dy))
            for (vname, vpayload) in variants
        )
    end
    return record
end

function main(argv)
    manifest_path, output_path = parse_args(argv)
    manifest = to_native(JSON3.read(read(manifest_path, String)))
    tolerances = get(manifest, "tolerances", Dict{String,Any}())

    fixtures = Dict{String,Any}()
    for fx in manifest["fixtures"]
        fixtures[fx["id"]] = compute_fixture(fx, tolerances)
    end

    result = Dict{String,Any}("binding" => "julia", "fixtures" => fixtures)
    mkpath(dirname(abspath(output_path)))
    open(output_path, "w") do io
        JSON3.write(io, result)
        write(io, "\n")
    end
    return 0
end

exit(main(ARGS))
