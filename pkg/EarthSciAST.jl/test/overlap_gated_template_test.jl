# The ISRM binning shape under the native compiler: records summed onto the grid
# cells their envelopes overlap, `out[c] = Σ_r overlap_area_planar(rec r, cell c)`
# with an `overlap` join, the area by the lib/geometry.esm template.
#
# Two places evaluate it. As an observed of const rings it is materialized at
# construction by the geometry sweep, driven by the overlap candidates, through
# the sweep's generated kernel; as the right-hand side of `D(u[c])` it is a
# per-call `faq`. Each must equal the interpreter bit for bit, and so must a body
# built to exercise the kernel's memo handling: shared sub-trees reached first in
# an `ifelse` arm, in a later `and`/`or` operand and under a nested reduction.
# The interpreter sweeps the full product, so every body here is exactly +0.0
# on a pair the gate prunes.

module OverlapGatedTemplateTests

using Test
using EarthSciAST
const EA = EarthSciAST

_d(p...) = Dict{String, Any}(p...)
_op(o, a...) = _d("op" => o, "args" => Any[a...])
_ix(a, i...) = _op("index", a, i...)

# Unit-square cells on an nx×nx grid and nrec axis-aligned records up to 1.5
# cells wide at pseudo-random positions (one record exactly on a cell edge).
function _binning_data(nx, nrec)
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
    recs = map(1:nrec) do k
        x, y = rnd() * (nx - 2.0), rnd() * (nx - 2.0)
        k == 1 && (x = 1.0)
        (x, y, x + 0.25 + rnd() * 1.25, y + 0.25 + rnd() * 1.25)
    end
    arrays = Dict{String, Any}("cring" => rings(cells), "pring" => rings(recs))
    for (k, n) in enumerate(("x0", "y0", "x1", "y1"))
        arrays["c" * n] = Float64[b[k] for b in cells]
        arrays["p" * n] = Float64[b[k] for b in recs]
    end
    return ncell, arrays
end

_area(nv) = _d(
    "op" => "apply_expression_template", "args" => Any[], "name" => "overlap_area_planar",
    "bindings" => _d(
        "ring_a" => "pring", "cell_a" => "r", "nv_a" => nv,
        "ring_b" => "cring", "cell_b" => "c", "nv_b" => nv
    )
)

# A factor whose shared sub-trees the kernel memoizes, each first reached where
# it may not run: `a` and `b` in the arms of an `ifelse`, `b` in the second
# operand of an `or`, `s` under a nested reduction over the vertices, then all
# of them in plain sequence.
function _memo_body()
    a = _op("-", _ix("pring", "r", 3, 1), _ix("cring", "c", 1, 1))
    b = _op("*", _ix("pring", "r", 1, 2), _ix("cring", "c", 3, 2))
    s = _op("+", _ix("pring", "r", "v", 1), _ix("cring", "c", "v", 2))
    inner = _d(
        "op" => "faq", "args" => Any[], "output_idx" => Any[], "reduce" => "max",
        "ranges" => _d("v" => _d("from" => "vert")), "expr" => _op("*", s, s)
    )
    return _op(
        "+",
        _op("ifelse", _op(">", a, 0.5), _op("*", a, b), _op("-", b, a)),
        _op("ifelse", _op("or", _op("<", a, 0.0), _op(">", b, 3.0)), b, a),
        inner, a, b
    )
end

function _binning_doc(nx, nrec; expr = _area(4), rhs = false)
    ncell, arrays = _binning_data(nx, nrec)
    env(set) = _d("type" => "parameter", "default" => 0.0, "shape" => Any[set])
    vars = _d(
        "cring" => _d("type" => "parameter", "default" => 0.0, "shape" => Any["cells", "vert", "xy"]),
        "pring" => _d("type" => "parameter", "default" => 0.0, "shape" => Any["recs", "vert", "xy"])
    )
    for n in ("x0", "y0", "x1", "y1")
        vars["c" * n] = env("cells")
        vars["p" * n] = env("recs")
    end
    faq = _d(
        "op" => "faq", "args" => Any[], "output_idx" => Any["c"], "reduce" => "+",
        "ranges" => _d("c" => _d("from" => "cells"), "r" => _d("from" => "recs")),
        "expr" => expr,
        "join" => Any[
            _d(
                "overlap" => _d(
                    "src_env" => Any["px0", "py0", "px1", "py1"],
                    "tgt_env" => Any["cx0", "cy0", "cx1", "cy1"], "eps" => 0.0
                )
            ),
        ]
    )
    if rhs
        vars["u"] = _d("type" => "unknown", "default" => 0.0, "shape" => Any["cells"])
        eq = _d("lhs" => _d("op" => "D", "args" => Any["u"], "wrt" => "t"), "rhs" => faq)
    else
        vars["out"] = _d("type" => "unknown", "shape" => Any["cells"])
        eq = _d("lhs" => "out", "rhs" => faq)
    end
    doc = _d(
        "esm" => "2.0.0", "metadata" => _d("name" => "OverlapGatedTemplate"),
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

function _values(doc, arrays, compiler; rhs = false)
    p = esm_problem(deepcopy(doc), (0.0, 1.0); compiler = compiler, const_arrays = arrays)
    rhs || return collect(observed_field(p, "M.out"))
    du = fill(NaN, length(p.u0))
    p.f!(du, p.u0, p.p, 0.0)
    return du
end

_bits(v) = reinterpret(UInt64, Float64.(v))

@testset "overlap-gated overlap_area_planar (the ISRM binning shape)" begin
    @testset "construction-time sweep: native == interpreter, bit for bit" begin
        doc, arrays = _binning_doc(4, 12)
        d0 = EA._GEOM_OVERLAP_DRIVE[]
        k0 = get(EA._CASCADE_TALLY, :geo_kernel, 0)
        native = _values(doc, arrays, :native)
        @test EA._GEOM_OVERLAP_DRIVE[] > d0                       # the candidates drove it
        @test get(EA._CASCADE_TALLY, :geo_kernel, 0) > k0         # through the generated kernel
        @test _bits(native) == _bits(_values(doc, arrays, :interpreter))
        @test sum(native) > 0
    end

    @testset "per-call right-hand side: native == interpreter, bit for bit" begin
        doc, arrays = _binning_doc(3, 6; rhs = true)
        native = _values(doc, arrays, :native; rhs = true)
        @test _bits(native) == _bits(_values(doc, arrays, :interpreter; rhs = true))
        @test sum(native) > 0
    end

    @testset "kernel memo handling: native == interpreter, bit for bit" begin
        doc, arrays = _binning_doc(4, 12; expr = _op("*", _area(4), _memo_body()))
        k0 = get(EA._CASCADE_TALLY, :geo_kernel, 0)
        native = _values(doc, arrays, :native)
        @test get(EA._CASCADE_TALLY, :geo_kernel, 0) > k0
        @test _bits(native) == _bits(_values(doc, arrays, :interpreter))
    end
end

end # module
