# The phase-3 standard-library templates under strict `compiler = :native`
# (closed-AST phase 3): lib/calendar.esm, lib/geometry.esm and
# lib/relational.esm, expanded, must build natively and give the
# interpreter's bits.
#
#   * calendar: the nine datetime fields per cell of an index set, against
#     the interpreter and against the `fn datetime.*` form;
#   * geometry: a lat-lon conservative regrid whose overlap areas are the
#     `overlap_area_planar` / `overlap_area_spherical` templates. The
#     join-gated `A_ij` is a build-once setup array (`_is_setup_join_reduction`)
#     materialized by the compiled setup sweep, which loops over the
#     templates' dense `[1, n]` ranges; the leaf's areas are only compared
#     within the geometry tolerance (GeometryOps is not the template);
#   * relational: the nearest-generator assignment by the `argmin` template,
#     against the interpreter and the `argmin` op.
#
# Also pinned: a JSON number read back from a template library or document is
# the integer JSON3 would give it, also inside an object that follows a float
# in an array (`[0.5, {"ranges": {"k": [1, "n"]}}]`); and the near misses of
# the setup seed.

using Test
include("testutils.jl")
# The spherical leaf the geometry templates are compared with runs through
# EarthSciASTGeometryOpsExt.
import GeometryOps
import GeoInterface
import SortTileRecursiveTree
import Extents

const _CT = EarthSciAST
const _CT_LIB = joinpath(TESTUTILS_REPO_ROOT, "lib")

_ct_op(o, a...; kw...) = Dict{String, Any}("op" => o, "args" => Any[a...], (String(k) => v for (k, v) in kw)...)
_ct_ix(a, s...) = _ct_op("index", a, s...)
_ct_const(v) = Dict{String, Any}("op" => "const", "args" => Any[], "value" => v)
_ct_apply(name; b...) = Dict{String, Any}(
    "op" => "apply_expression_template", "args" => Any[], "name" => name,
    "bindings" => Dict{String, Any}(String(k) => v for (k, v) in b)
)
_ct_faq(e, out, ranges; kw...) = Dict{String, Any}(
    "op" => "faq", "args" => Any[], "output_idx" => Any[out...], "ranges" => ranges,
    "expr" => e, (String(k) => v for (k, v) in kw)...
)
_ct_dlhs(v, out, ranges) = _ct_faq(_ct_op("D", _ct_ix(v, out...); wrt = "t"), out, ranges)
_ct_import(file, names) = Dict{String, Any}("ref" => joinpath(_CT_LIB, file), "only" => Any[names...])

function _ct_write(doc)
    path = joinpath(mktempdir(), "doc.esm")
    write(path, JSON3.write(doc))
    return path
end

# `du` by state name at a few times, at a state that differs from cell to
# cell (so a regrid's derivative depends on every weight, not only on their
# row sums) and is the same per name in every spelling.
function _ct_du(path, compiler; times = (0.0, 0.7, 3.1, 1800.0))
    prob = _CT.esm_problem(path, (0.0, 1.0); compiler = compiler)
    u = copy(prob.u0)
    for (r, k) in enumerate(sort!(collect(keys(prob.var_map))))
        u[prob.var_map[k]] += r / 64
    end
    out = Dict{String, Vector{Float64}}()
    for t in times
        du = similar(prob.u0); fill!(du, NaN)
        prob.f!(du, u, prob.p, t)
        for (k, v) in prob.var_map
            push!(get!(() -> Float64[], out, k), du[v])
        end
    end
    return out
end
_ct_same(a, b) = keys(a) == keys(b) && all(all(a[k] .=== b[k]) for k in keys(a))

const _CT_FIELDS = ("year", "month", "day", "hour", "minute", "second", "day_of_year", "julian_day", "is_leap_year")

# Every field of t[h] = T0 + 3601 (h - 1) + 37 t, a state per field and hour
# relaxing toward it. `tpl`: the calendar templates; otherwise `fn datetime.*`.
function _ct_calendar_doc(nh; tpl::Bool, t0 = 1.6e9)
    H = Dict("h" => Dict("from" => "hours"))
    vars = Dict{String, Any}("tu" => Dict("type" => "unknown", "shape" => Any["hours"]))
    eqs = Any[Dict("lhs" => "tu", "rhs" => _ct_faq(_ct_op("+", t0, _ct_op("*", 3601, _ct_op("-", "h", 1)), _ct_op("*", 37, "t")), ["h"], H))]
    for f in _CT_FIELDS
        call = tpl ? _ct_apply(f; t = _ct_ix("tu", "h")) : _ct_op("fn", _ct_ix("tu", "h"); name = "datetime.$f")
        vars["s_$f"] = Dict("type" => "unknown", "shape" => Any["hours"], "default" => 0.0)
        push!(eqs, Dict("lhs" => _ct_dlhs("s_$f", ["h"], H), "rhs" => _ct_faq(_ct_op("-", call, _ct_ix("s_$f", "h")), ["h"], H)))
    end
    model = Dict{String, Any}("variables" => vars, "equations" => eqs)
    tpl && (model["expression_template_imports"] = Any[_ct_import("calendar.esm", _CT_FIELDS)])
    return Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict("name" => "calendar_$(tpl)"),
        "index_sets" => Dict("hours" => Dict("kind" => "interval", "size" => nh)),
        "models" => Dict("Cal" => model)
    )
end

# Lat-lon cells of the edges `lons` x `lats`, counter-clockwise from the
# south-west corner.
_ct_cells(lons, lats) = Any[
    Any[Any[lons[a], lats[b]], Any[lons[a + 1], lats[b]], Any[lons[a + 1], lats[b + 1]], Any[lons[a], lats[b + 1]]]
        for b in 1:(length(lats) - 1) for a in 1:(length(lons) - 1)
]
_ct_thirds(n) = vcat([Float64[m, m + 2 / 3, m + 4 / 3] for m in 0:2:(n - 1)]..., Float64(n))

# The conservative regrid of the scaling family (bin-skolem broad phase,
# overlap area per candidate pair, row-sum normalisation): an n x n grid of
# 1-degree cells onto the 2/3-degree grid over it. `area`: :leaf, :tpl, or a
# Dict standing in for the A_ij body (a near miss).
function _ct_regrid_doc(n, manifold; area = :tpl)
    src = _ct_cells([-100.0 + k for k in 0:n], [30.0 + k for k in 0:n])
    tgt = _ct_cells(-100.0 .+ _ct_thirds(n), 30.0 .+ _ct_thirds(n))
    S, T = Dict("from" => "src_cells"), Dict("from" => "tgt_cells")
    join = Any[Dict("on" => Any[Any["src_bin", "tgt_bin"]])]
    alive = _ct_op(">", _ct_ix("A_ij", "i", "j"), "atol")
    u(shape, d = nothing) = (var = Dict{String, Any}("type" => "unknown", "shape" => Any[shape...]); d === nothing || (var["default"] = d); var)
    bbox(var, cells, poly, s, c) = Dict("lhs" => var, "rhs" => _ct_faq(_ct_ix(poly, s, "v", c), [s], Dict(s => Dict("from" => cells), "v" => Dict("from" => "cell_verts")); reduce = "min"))
    binkey(var, lon, lat, s, cells) = Dict(
        "lhs" => _ct_ix(var, s), "rhs" => _ct_faq(
            Dict("op" => "skolem", "label" => "bin", "args" => Any[_ct_op("floor", _ct_op("/", _ct_ix(lon, s), "dx")), _ct_op("floor", _ct_op("/", _ct_ix(lat, s), "dy"))]),
            [s], Dict(s => Dict("from" => cells)); semiring = "sum_product"
        )
    )
    names = Any[]
    if area === :leaf
        body = _ct_op("polygon_intersection_area", _ct_ix("src_poly", "i"), _ct_ix("tgt_poly", "j"); manifold = manifold)
    elseif area === :tpl
        tname = manifold == "planar" ? "overlap_area_planar" : "overlap_area_spherical"
        a, b = manifold == "planar" ? ("src_poly", "tgt_poly") : ("src_xyz", "tgt_xyz")
        body = _ct_apply(tname; ring_a = a, cell_a = "i", nv_a = 4, ring_b = b, cell_b = "j", nv_b = 4)
        push!(names, tname)
    else
        body = area
    end
    v = Dict{String, Any}(
        "src_poly" => u(["src_cells", "cell_verts", "coord"]), "tgt_poly" => u(["tgt_cells", "cell_verts", "coord"]),
        "src_lon" => u(["src_cells"]), "src_lat" => u(["src_cells"]), "tgt_lon" => u(["tgt_cells"]), "tgt_lat" => u(["tgt_cells"]),
        "src_bin" => u(["src_cells"]), "tgt_bin" => u(["tgt_cells"]),
        "A_ij" => u(["src_cells", "tgt_cells"]), "A_j" => u(["tgt_cells"]), "W_ij" => u(["src_cells", "tgt_cells"]),
        "F_rg" => u(["tgt_cells"]), "F_src" => u(["src_cells"], 10.0), "F_tgt" => u(["tgt_cells"], 0.0),
        "dx" => Dict("type" => "parameter", "default" => 2.0), "dy" => Dict("type" => "parameter", "default" => 2.0),
        "atol" => Dict("type" => "parameter", "default" => 1.0e-12), "kd" => Dict("type" => "parameter", "default" => 0.1),
    )
    eqs = Any[
        Dict("lhs" => "src_poly", "rhs" => _ct_const(src)), Dict("lhs" => "tgt_poly", "rhs" => _ct_const(tgt)),
        bbox("src_lon", "src_cells", "src_poly", "i", 1), bbox("src_lat", "src_cells", "src_poly", "i", 2),
        bbox("tgt_lon", "tgt_cells", "tgt_poly", "j", 1), bbox("tgt_lat", "tgt_cells", "tgt_poly", "j", 2),
        binkey("src_bin", "src_lon", "src_lat", "i", "src_cells"), binkey("tgt_bin", "tgt_lon", "tgt_lat", "j", "tgt_cells"),
        Dict("lhs" => "A_ij", "rhs" => _ct_faq(body, ["i", "j"], Dict("i" => S, "j" => T); semiring = "sum_product", join = join)),
        Dict("lhs" => "A_j", "rhs" => _ct_faq(_ct_ix("A_ij", "i", "j"), ["j"], Dict("i" => S, "j" => T); semiring = "sum_product", join = join, filter = alive)),
        Dict("lhs" => "W_ij", "rhs" => _ct_faq(_ct_op("/", _ct_ix("A_ij", "i", "j"), _ct_ix("A_j", "j")), ["i", "j"], Dict("i" => S, "j" => T); semiring = "sum_product", join = join, filter = alive)),
        Dict("lhs" => _ct_dlhs("F_src", ["i"], Dict("i" => S)), "rhs" => _ct_faq(_ct_op("*", _ct_op("-", "kd"), _ct_ix("F_src", "i")), ["i"], Dict("i" => S))),
        Dict("lhs" => "F_rg", "rhs" => _ct_faq(_ct_op("*", _ct_ix("W_ij", "i", "j"), _ct_ix("F_src", "i")), ["j"], Dict("i" => S, "j" => T); semiring = "sum_product", join = join, filter = alive)),
        Dict("lhs" => _ct_dlhs("F_tgt", ["j"], Dict("j" => T)), "rhs" => _ct_faq(_ct_op("-", _ct_ix("F_rg", "j"), _ct_ix("F_tgt", "j")), ["j"], Dict("j" => T))),
    ]
    if area === :tpl && manifold != "planar"
        for (xyz, poly, cells) in (("src_xyz", "src_poly", "src_cells"), ("tgt_xyz", "tgt_poly", "tgt_cells"))
            v[xyz] = u([cells, "cell_verts", "xyz"])
            push!(eqs, Dict("lhs" => xyz, "rhs" => _ct_faq(_ct_apply("lonlat_to_unit"; ring = poly, cell = "c", vert = "v", comp = "d"), ["c", "v", "d"], Dict("c" => Dict("from" => cells), "v" => Dict("from" => "cell_verts"), "d" => Any[1, 3]))))
        end
        push!(names, "lonlat_to_unit")
    end
    model = Dict{String, Any}("variables" => v, "equations" => eqs)
    isempty(names) || (model["expression_template_imports"] = Any[_ct_import("geometry.esm", names)])
    return Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict("name" => "regrid"),
        "index_sets" => Dict(
            "coord" => Dict("kind" => "interval", "size" => 2), "xyz" => Dict("kind" => "interval", "size" => 3),
            "cell_verts" => Dict("kind" => "interval", "size" => 4),
            "src_cells" => Dict("kind" => "interval", "size" => length(src)), "tgt_cells" => Dict("kind" => "interval", "size" => length(tgt))
        ),
        "models" => Dict("Regrid" => model)
    )
end

# Nearest generator of each point (squared distance on a 1/64 lattice, so
# ties are real), feeding a gather.
function _ct_nearest_doc(np, ng; tpl::Bool)
    px = Float64[mod(37 * k, 61) / 64 for k in 1:np]
    py = Float64[mod(23 * k, 59) / 64 for k in 1:np]
    gx = Float64[mod(11 * k, 17) / 16 for k in 1:ng]
    gy = Float64[mod(7 * k, 13) / 16 for k in 1:ng]
    P = Dict("i" => Dict("from" => "points"))
    dist(k) = _ct_op(
        "+", _ct_op("*", _ct_op("-", _ct_ix("px", "i"), _ct_ix("gx", k)), _ct_op("-", _ct_ix("px", "i"), _ct_ix("gx", k))),
        _ct_op("*", _ct_op("-", _ct_ix("py", "i"), _ct_ix("gy", k)), _ct_op("-", _ct_ix("py", "i"), _ct_ix("gy", k)))
    )
    assign = tpl ? _ct_apply("argmin"; f = dist("k_argmin_1"), n = ng) :
        _ct_op("argmin", "px", "py", "gx", "gy"; arg = "g", ranges = Dict("g" => Dict("from" => "generators")), expr = dist("g"))
    vars = Dict{String, Any}(
        k => Dict("type" => "unknown", "shape" => Any[s]) for (k, s) in
            (("px", "points"), ("py", "points"), ("gx", "generators"), ("gy", "generators"), ("assign", "points"))
    )
    vars["w"] = Dict("type" => "unknown", "shape" => Any["points"], "default" => 0.0)
    eqs = Any[
        Dict("lhs" => "px", "rhs" => _ct_const(px)), Dict("lhs" => "py", "rhs" => _ct_const(py)),
        Dict("lhs" => "gx", "rhs" => _ct_const(gx)), Dict("lhs" => "gy", "rhs" => _ct_const(gy)),
        Dict("lhs" => _ct_ix("assign", "i"), "rhs" => _ct_faq(assign, ["i"], P; args = Any["px", "py", "gx", "gy"])),
        Dict("lhs" => _ct_dlhs("w", ["i"], P), "rhs" => _ct_faq(_ct_op("-", _ct_ix("gx", _ct_ix("assign", "i")), _ct_ix("w", "i")), ["i"], P; args = Any["gx", "assign"])),
    ]
    model = Dict{String, Any}("variables" => vars, "equations" => eqs)
    tpl && (model["expression_template_imports"] = Any[_ct_import("relational.esm", ["argmin"])])
    return Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict("name" => "nearest_$(tpl)"),
        "index_sets" => Dict("points" => Dict("kind" => "interval", "size" => np), "generators" => Dict("kind" => "interval", "size" => ng)),
        "models" => Dict("Nearest" => model)
    )
end


# The other lib/relational.esm templates per cell of a state: the gated
# arg-witnesses (a contracted `faq` with a `filter`; no candidate passing
# gives `n + 1`), the composite keys, `rank_of` over literal members and
# `rank_of_set` over a named index set.
function _ct_relational_doc()
    P = Dict("i" => Dict("from" => "points"))
    x = _ct_ix("x", "i")
    g(k) = _ct_ix("gx", k)
    d(k) = _ct_op("*", _ct_op("-", x, g(k)), _ct_op("-", x, g(k)))
    pass(k) = _ct_op(">", g(k), x)
    ka = _ct_op("floor", _ct_op("*", 3, x))
    kb = _ct_op("floor", _ct_op("*", 2, x))
    sum = _ct_op(
        "+",
        _ct_apply("argmin_where"; f = d("k_argmin_where_1"), p = pass("k_argmin_where_1"), n = 6),
        _ct_apply("argmax_where"; f = d("k_argmax_where_1"), p = pass("k_argmax_where_1"), n = 6),
        _ct_apply("pair_key"; a = ka, b = kb, lo_a = 0, lo_b = 1, n_a = 8, n_b = 5),
        _ct_apply("edge_key"; u = ka, v = kb, lo = 0, n = 8),
        _ct_apply("rank_of"; x = x, members = _ct_const([0.5, 1.0, 1.5, 2.25]), n = 4),
        _ct_apply("rank_of_set"; x = x, members = "gx", S = "generators"),
    )
    vars = Dict{String, Any}(
        "gx" => Dict("type" => "unknown", "shape" => Any["generators"]),
        "x" => Dict("type" => "unknown", "shape" => Any["points"], "default" => 1.0),
        "y" => Dict("type" => "unknown", "shape" => Any["points"]),
    )
    eqs = Any[
        Dict("lhs" => "gx", "rhs" => _ct_const([0.5, 1.0, 1.5, 1.0, 2.0, 2.5])),
        Dict("lhs" => "y", "rhs" => _ct_faq(sum, ["i"], P)),
        Dict("lhs" => _ct_dlhs("x", ["i"], P), "rhs" => _ct_faq(_ct_op("-", _ct_op("*", 0.01, _ct_ix("y", "i")), x), ["i"], P)),
    ]
    model = Dict{String, Any}(
        "variables" => vars, "equations" => eqs,
        "expression_template_imports" => Any[_ct_import("relational.esm", ["argmin_where", "argmax_where", "pair_key", "edge_key", "rank_of", "rank_of_set"])]
    )
    return Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict("name" => "relational"),
        "index_sets" => Dict("points" => Dict("kind" => "interval", "size" => 7), "generators" => Dict("kind" => "interval", "size" => 6)),
        "models" => Dict("Rel" => model)
    )
end

@testset "phase-3 templates under strict native (closed-AST phase 3)" begin
    @testset "JSON numbers after a float in an array" begin
        x = JSON3.read("""{"a": [0.5, {"r": [1, "n"], "s": 3, "t": [2, 2.5, 3, {"u": 4}]}, [1]], "b": [1, 2.0, 2.5, 3]}""")
        for conv in (_CT._to_ordered, _CT._to_native_json)
            d = conv(x)
            o = d["a"][2]
            @test o["r"][1] === 1 && o["s"] === 3 && o["t"][4]["u"] === 4
            # Within one array JSON3 keeps the numbers after a float as floats.
            @test o["t"][1] === 2 && o["t"][2] === 2.5 && o["t"][3] === 3.0
            @test d["a"][3][1] === 1
            @test d["b"] == Any[1, 2, 2.5, 3.0] && d["b"][2] === 2
        end
        # The template body that hit it: `0.5 * faq(ranges [1, n])`.
        lib = JSON3.read(read(joinpath(_CT_LIB, "geometry.esm"), String))
        bad = Ref(0)
        walk(e) = e isa AbstractDict ? (haskey(e, "ranges") && foreach(r -> r isa AbstractVector && r[1] isa Float64 && (bad[] += 1), values(e["ranges"])); foreach(walk, values(e))) :
            e isa AbstractVector ? foreach(walk, e) : nothing
        walk(_CT._to_ordered(lib))
        @test bad[] == 0
    end

    @testset "calendar" begin
        tp = _ct_write(_ct_calendar_doc(40; tpl = true))
        dn = _ct_du(tp, :native)
        @test _ct_same(dn, _ct_du(tp, :interpreter))
        @test _ct_same(dn, _ct_du(_ct_write(_ct_calendar_doc(40; tpl = false)), :native))
        # Pre-1970 and leap-day instants.
        tn = _ct_write(_ct_calendar_doc(30; tpl = true, t0 = -2.2e9))
        @test _ct_same(_ct_du(tn, :native), _ct_du(tn, :interpreter))
        @test _ct_same(_ct_du(tn, :native), _ct_du(_ct_write(_ct_calendar_doc(30; tpl = false, t0 = -2.2e9)), :native))
    end

    @testset "geometry ($manifold)" for manifold in ("planar", "spherical")
        tp = _ct_write(_ct_regrid_doc(4, manifold))
        dn = _ct_du(tp, :native)
        @test _ct_same(dn, _ct_du(tp, :interpreter))
        dl = _ct_du(_ct_write(_ct_regrid_doc(4, manifold; area = :leaf)), :native)
        @test keys(dl) == keys(dn)
        @test maximum(maximum(abs.(dn[k] .- dl[k])) for k in keys(dn)) <= 1.0e-12
        # The setup body runs as native code under native, walked under the
        # interpreter (which gave the same bits above).
        for (c, want) in ((:native, true), (:interpreter, false))
            _CT._reset_cascade_tally!()
            _CT.esm_problem(tp, (0.0, 1.0); compiler = c)
            @test (get(_CT._CASCADE_TALLY, :geo_kernel, 0) >= 1) == want
        end
        # The overlap areas are materialized at setup: no per-pair work is
        # left in the right-hand side.
        prob = _CT.esm_problem(tp, (0.0, 1.0); compiler = :native)
        du = similar(prob.u0)
        prob.f!(du, copy(prob.u0), prob.p, 0.1)
        VERSION >= v"1.12" && @test (@allocated prob.f!(du, prob.u0, prob.p, 0.2)) == 0
    end

    # The template-expanded copy validation and the build take of a model
    # copies only the containers expansion rewrites: an equation it leaves
    # alone (a polygon table's inline rings) is the original's tree, and the
    # original keeps its references. One validation pass builds the expanded
    # view once and its checks read it, with the findings of a check that
    # expands for itself.
    @testset "template expansion copies share the inline data" begin
        file = _CT.load_path(_ct_write(_ct_regrid_doc(4, "planar")))
        model = file.models["Regrid"]
        view = _CT._units_view(file, "Regrid", model)
        @test view !== model && view.equations !== model.equations
        names = [eq.lhs isa _CT.VarExpr ? eq.lhs.name : "" for eq in model.equations]
        poly = findfirst(==("src_poly"), names)
        aij = findfirst(==("A_ij"), names)
        @test view.equations[poly].rhs === model.equations[poly].rhs
        @test view.equations[aij].rhs !== model.equations[aij].rhs
        @test _CT._model_has_surviving_refs(model)
        @test !_CT._model_has_surviving_refs(view)
        copy_ = _CT._expansion_copy(model)
        @test copy_.equations !== model.equations && copy_.variables !== model.variables
        @test all(copy_.equations[i].rhs === model.equations[i].rhs for i in eachindex(names))
        sig(es) = sort!([(e.path, e.error_type, e.message) for e in es])
        bad = _CT.load_path(joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "faq", "template_from_param_undeclared.esm"))
        for f in (file, bad)
            u = _CT._UnitsInputs(f)
            @test sig(_CT.validate_reference_integrity(f; views = u.models)) == sig(_CT.validate_reference_integrity(f))
            @test sig(_CT.validate_aggregate_semantics(f; views = u.models)) == sig(_CT.validate_aggregate_semantics(f))
        end
        @test "undefined_index_set" in [e.error_type for e in _CT.validate_structural(bad)]
    end

    # Near misses of the setup seed: a gated faq whose body has no nested
    # reduction (left to the right-hand-side tiers), an ungated one nested one
    # deep, and one whose body leaves the setup language are not seeded. The
    # setup sweep loops only over `1:n`: an ungated body whose nested range
    # does not start at 1 is not seeded (the right-hand-side tiers take it),
    # a gated one is refused by name, since no right-hand-side tier folds it.
    @testset "setup seed near misses" begin
        flat = _ct_op("+", _ct_ix("src_lon", "i"), _ct_ix("tgt_lon", "j"))
        @test !_CT._is_setup_join_reduction(_CT.expression_from_json(_ct_faq(flat, ["i", "j"], Dict("i" => Dict("from" => "s"), "j" => Dict("from" => "t")); join = Any[Dict("on" => Any[Any["a", "b"]])])))
        nested = _ct_faq(_ct_ix("src_poly", "i", "k", 1), [], Dict("k" => Any[1, 4]); reduce = "max")
        @test _CT._is_setup_join_reduction(_CT.expression_from_json(_ct_faq(nested, ["i", "j"], Dict("i" => Dict("from" => "s"), "j" => Dict("from" => "t")); join = Any[Dict("on" => Any[Any["a", "b"]])])))
        # No join: reductions nested one deep are left to the right-hand-side
        # tiers; two deep (the overlap templates' shape) is a setup array.
        @test !_CT._is_setup_join_reduction(_CT.expression_from_json(_ct_faq(nested, ["i", "j"], Dict("i" => Dict("from" => "s"), "j" => Dict("from" => "t")))))
        nested2 = _ct_faq(_ct_op("+", 1, nested), [], Dict("m" => Any[1, 3]))
        @test _CT._is_setup_join_reduction(_CT.expression_from_json(_ct_faq(nested2, ["i", "j"], Dict("i" => Dict("from" => "s"), "j" => Dict("from" => "t")))))
        # A body outside the setup language (`exp`) is not seeded.
        @test !_CT._is_setup_join_reduction(_CT.expression_from_json(_ct_faq(_ct_op("exp", nested), ["i", "j"], Dict("i" => Dict("from" => "s"), "j" => Dict("from" => "t")); join = Any[Dict("on" => Any[Any["a", "b"]])])))
        off = _ct_faq(_ct_ix("src_poly", "i", _ct_op("-", "k", 1), 1), [], Dict("k" => Any[2, 4]); reduce = "max")
        off2 = _ct_faq(_ct_op("+", 1, off), [], Dict("m" => Any[1, 3]))
        @test !_CT._is_setup_join_reduction(_CT.expression_from_json(_ct_faq(off2, ["i", "j"], Dict("i" => Dict("from" => "s"), "j" => Dict("from" => "t")))))
        err = try
            _CT.esm_problem(_ct_write(_ct_regrid_doc(2, "planar"; area = off)), (0.0, 1.0); compiler = :native)
            nothing
        catch e
            e
        end
        @test err !== nothing && occursin("dense [1, n] range", sprint(showerror, err))
    end

    @testset "keyed and gated relational templates" begin
        tp = _ct_write(_ct_relational_doc())
        @test _ct_same(_ct_du(tp, :native), _ct_du(tp, :interpreter))
    end

    @testset "argmin" begin
        tp = _ct_write(_ct_nearest_doc(40, 9; tpl = true))
        dn = _ct_du(tp, :native)
        @test _ct_same(dn, _ct_du(tp, :interpreter))
        @test _ct_same(dn, _ct_du(_ct_write(_ct_nearest_doc(40, 9; tpl = false)), :native))
    end
end
