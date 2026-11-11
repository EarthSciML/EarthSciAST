# The ISRM binning shape, Julia native: records summed onto the unit-square
# cells of an nx×nx grid whose envelopes they overlap,
#
#     out[c] = Σ_r overlap_area_planar(record r, cell c)   join: overlap(envelopes)
#
# with the area by the lib/geometry.esm template. The documents and their const
# arrays are built in memory (axis-aligned records up to 1.5 cells wide at
# seeded pseudo-random positions; the same data as the Rust harness of the
# phase-5 comparison).
#
# Two forms. `obs`: `out` is an observed of const rings, materialized at
# construction (the form the retired built-in op had); setup is
# `esm_problem` + `observed_field`. `rhs`: `D(u[c]) = faq(…)`, evaluated per
# call; setup is `esm_problem` + the first call, then the median call.
# Each size runs in this one process: the first build includes Julia
# compilation and is reported separately; the setup is the median of the
# later builds. With INTERP_CHECK=1 the output is compared bit for bit with the
# interpreter's on sizes up to 20×20.
#
# Usage (an environment with EarthSciAST):
#
#     julia --project=<env> bench/closed_templates/bench_binning.jl [obs|rhs] [nx:nrec ...]
#
# Default sizes 5:10 20:200 50:2000 100:10000. Environment: REPS (default 5),
# INTERP_CHECK (default 0).

using EarthSciAST, Statistics, Printf

const E = EarthSciAST
const FORM = isempty(ARGS) ? "obs" : ARGS[1]
const SIZES = length(ARGS) > 1 ? [Tuple(parse.(Int, split(a, ':'))) for a in ARGS[2:end]] :
    [(5, 10), (20, 200), (50, 2000), (100, 10000)]
const REPS = parse(Int, get(ENV, "REPS", "5"))
const INTERP_CHECK = get(ENV, "INTERP_CHECK", "0") == "1"

_d(p...) = Dict{String, Any}(p...)

function binning(nx, nrec, form)
    ncell = nx * nx
    corners(x0, y0, x1, y1) = ((x0, y0), (x1, y0), (x1, y1), (x0, y1))
    function rings(boxes)
        r = zeros(length(boxes), 4, 2)
        for (k, b) in enumerate(boxes), (v, (x, y)) in enumerate(corners(b...))
            r[k, v, 1] = x
            r[k, v, 2] = y
        end
        return r
    end
    cells = [(Float64(i), Float64(j), i + 1.0, j + 1.0) for j in 0:(nx - 1) for i in 0:(nx - 1)]
    s = UInt64(12345)
    rnd() = (s = s * 0x5851f42d4c957f2d + 0x14057b7ef767814f; Float64(s >> 11) / Float64(UInt64(1) << 53))
    recs = map(1:nrec) do _
        x, y = rnd() * (nx - 2.0), rnd() * (nx - 2.0)
        (x, y, x + 0.25 + rnd() * 1.25, y + 0.25 + rnd() * 1.25)
    end
    arrays = Dict{String, Any}("cring" => rings(cells), "pring" => rings(recs))
    env(set) = _d("type" => "parameter", "default" => 0.0, "shape" => Any[set])
    vars = _d(
        "cring" => _d("type" => "parameter", "default" => 0.0, "shape" => Any["cells", "vert", "xy"]),
        "pring" => _d("type" => "parameter", "default" => 0.0, "shape" => Any["recs", "vert", "xy"])
    )
    for (k, n) in enumerate(("x0", "y0", "x1", "y1"))
        arrays["c" * n] = Float64[b[k] for b in cells]
        arrays["p" * n] = Float64[b[k] for b in recs]
        vars["c" * n] = env("cells")
        vars["p" * n] = env("recs")
    end
    faq = _d(
        "op" => "faq", "args" => Any[], "output_idx" => Any["c"], "reduce" => "+",
        "ranges" => _d("c" => _d("from" => "cells"), "r" => _d("from" => "recs")),
        "expr" => _d(
            "op" => "apply_expression_template", "args" => Any[], "name" => "overlap_area_planar",
            "bindings" => _d(
                "ring_a" => "pring", "cell_a" => "r", "nv_a" => 4,
                "ring_b" => "cring", "cell_b" => "c", "nv_b" => 4
            )
        ),
        "join" => Any[
            _d(
                "overlap" => _d(
                    "src_env" => Any["px0", "py0", "px1", "py1"],
                    "tgt_env" => Any["cx0", "cy0", "cx1", "cy1"], "eps" => 0.0
                )
            ),
        ]
    )
    if form == "rhs"
        vars["u"] = _d("type" => "unknown", "default" => 0.0, "shape" => Any["cells"])
        eq = _d("lhs" => _d("op" => "D", "args" => Any["u"], "wrt" => "t"), "rhs" => faq)
    else
        vars["out"] = _d("type" => "unknown", "shape" => Any["cells"])
        eq = _d("lhs" => "out", "rhs" => faq)
    end
    doc = _d(
        "esm" => "2.0.0", "metadata" => _d("name" => "Binning"),
        "index_sets" => _d(
            "cells" => _d("kind" => "interval", "size" => ncell),
            "recs" => _d("kind" => "interval", "size" => nrec),
            "vert" => _d("kind" => "interval", "size" => 4),
            "xy" => _d("kind" => "interval", "size" => 2)
        ),
        "models" => _d(
            "M" => _d(
                "variables" => vars, "equations" => Any[eq],
                "expression_template_imports" => Any[
                    _d("ref" => "esm:std/geometry.esm", "only" => Any["overlap_area_planar"]),
                ]
            )
        )
    )
    return doc, arrays
end

# One build: (setup seconds, output, problem).
function build(doc, arrays, compiler)
    GC.gc()
    t0 = time_ns()
    p = E.esm_problem(deepcopy(doc), (0.0, 1.0); compiler = compiler, const_arrays = arrays)
    if FORM == "rhs"
        out = fill(NaN, length(p.u0))
        p.f!(out, p.u0, p.p, 0.0)
    else
        out = collect(E.observed_field(p, "M.out"))
    end
    return (time_ns() - t0) / 1.0e9, out, p
end

function call_s(p)
    du = similar(p.u0)
    n = 0
    t0 = time_ns()
    while n < 3 || (n < 1000 && time_ns() - t0 < 2.0e9)
        p.f!(du, p.u0, p.p, 0.0)
        n += 1
    end
    return (time_ns() - t0) / 1.0e9 / n
end

@printf("form=%s threads=%d load=%s\n", FORM, Threads.nthreads(), strip(read("/proc/loadavg", String)))
for (nx, nrec) in SIZES
    doc, arrays = binning(nx, nrec, FORM)
    first_s, out, p = build(doc, arrays, :native)
    setups = [build(doc, arrays, :native)[1] for _ in 1:REPS]
    line = @sprintf(
        "nx=%d nrec=%d first_s=%.3f setup_med_s=%.4f setup_min_s=%.4f",
        nx, nrec, first_s, median(setups), minimum(setups)
    )
    if FORM == "rhs"
        line *= @sprintf(" call_med_ms=%.3f", 1.0e3 * median([call_s(p) for _ in 1:3]))
    end
    line *= @sprintf(" sum_out=%.12f", sum(out))
    if INTERP_CHECK && nx <= 20
        oi = build(doc, arrays, :interpreter)[2]
        line *= reinterpret(UInt64, out) == reinterpret(UInt64, oi) ? " interpreter=bit-identical" :
            " interpreter=DIFFERS"
    end
    println(line)
    flush(stdout)
end
