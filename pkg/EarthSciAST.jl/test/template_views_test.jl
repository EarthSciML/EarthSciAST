# Templates the build reads WHOLE without expanding them (call.jl):
#   * a body that is a joined, filtered aggregate (the conservative-overlap
#     regrid of EarthSciDiscretizations, as reseact uses it), or a whole-array
#     reference to one, is read through its VIEW: the body's loop header in
#     the caller, each leaf (term, filter) a call of that part of the template;
#   * a reduction over a whole index set named by a parameter;
#   * an elementwise operator over whole array-valued references in a body
#     (the body's elementwise lift).
# Under both compilers the right-hand side must be bit for bit the build of the
# expanded document's, and the build entry must expand no reference.

using Test
using JSON3
using EarthSciAST
const _TV = EarthSciAST
include("testutils.jl")  # TESTUTILS_REPO_ROOT

_tv_d(p...) = Dict{String, Any}(p...)
_tv_op(o, a...; kw...) = _tv_d("op" => o, "args" => Any[a...], (String(k) => v for (k, v) in kw)...)
_tv_ix(a, s...) = _tv_op("index", a, s...)
_tv_ref(n; b...) = _tv_d(
    "op" => "apply_operator", "args" => Any[], "name" => n,
    "bindings" => _tv_d((String(k) => v for (k, v) in b)...)
)
const _TV_JOIN = Any[_tv_d("overlap" => _tv_d("src_env" => Any["src_poly"], "tgt_env" => Any["tgt_poly"], "eps" => 1.0e-9))]

# The conservative-overlap templates (EarthSciDiscretizations
# regridding/conservative_overlap.esm), over lib/geometry.esm's planar area.
function _tv_overlap_templates()
    lib = JSON3.read(read(joinpath(pkgdir(_TV), "data", "lib", "geometry.esm"), String), Dict{String, Any})
    t = Dict{String, Any}(lib["operators"])
    IJ = _tv_d("i" => _tv_d("from" => "src_cells"), "j" => _tv_d("from" => "tgt_cells"))
    t["pairs_gated"] = _tv_d(
        "params" => Any["src_ring", "tgt_ring", "area"], "body" => _tv_op(
            "faq", "src_ring", "tgt_ring"; semiring = "sum_product", output_idx = Any["i", "j"], ranges = IJ,
            join = _TV_JOIN, expr = "area"
        )
    )
    t["area_planar_ij"] = _tv_d(
        "params" => Any["src_poly", "tgt_poly", "src_nv", "tgt_nv"], "body" => _tv_ref(
            "overlap_area_planar"; ring_a = "src_poly", cell_a = "i", nv_a = "src_nv", ring_b = "tgt_poly", cell_b = "j", nv_b = "tgt_nv"
        )
    )
    t["A_ij_gated_planar"] = _tv_d(
        "params" => Any["src_poly", "tgt_poly", "src_nv", "tgt_nv"], "body" => _tv_ref(
            "pairs_gated"; src_ring = "src_poly", tgt_ring = "tgt_poly",
            area = _tv_ref("area_planar_ij"; src_poly = "src_poly", tgt_poly = "tgt_poly", src_nv = "src_nv", tgt_nv = "tgt_nv")
        )
    )
    t["apply_gated"] = _tv_d(
        "params" => Any["A_ij", "A_j", "F_src", "src_poly", "tgt_poly", "atol"], "body" => _tv_op(
            "faq", "A_ij", "A_j", "F_src", "src_poly", "tgt_poly"; semiring = "sum_product", output_idx = Any["j"], ranges = IJ,
            join = _TV_JOIN, filter = _tv_op(">", _tv_ix("A_ij", "i", "j"), "atol"),
            expr = _tv_op("/", _tv_op("*", _tv_ix("A_ij", "i", "j"), _tv_ix("F_src", "i")), _tv_ix("A_j", "j"))
        )
    )
    return t
end

_tv_rings(boxes) = [[[b[1], b[2]], [b[3], b[2]], [b[3], b[4]], [b[1], b[4]]] for b in boxes]

function _tv_overlap_doc(ntracers)
    S = _tv_d("from" => "src_cells"); T = _tv_d("from" => "tgt_cells")
    vars = _tv_d(
        "src_poly" => _tv_d("type" => "unknown", "shape" => Any["src_cells", "verts", "coord"]),
        "tgt_poly" => _tv_d("type" => "unknown", "shape" => Any["tgt_cells", "verts", "coord"]),
        "A_ij" => _tv_d("type" => "unknown", "shape" => Any["src_cells", "tgt_cells"]),
        "A_full" => _tv_d("type" => "unknown", "shape" => Any["tgt_cells"]),
        "atol" => _tv_d("type" => "parameter", "default" => 1.0e-12),
    )
    eqs = Any[
        _tv_d("lhs" => "src_poly", "rhs" => _tv_op("const"; value = _tv_rings([(0.0, 0.0, 1.0, 1.0), (1.0, 0.0, 2.0, 1.0), (0.0, 1.0, 1.0, 2.0), (1.0, 1.0, 2.0, 2.0)]))),
        _tv_d("lhs" => "tgt_poly", "rhs" => _tv_op("const"; value = _tv_rings([(0.3, 0.2, 1.4, 1.1), (1.4, 0.2, 2.0, 1.9), (0.0, 1.1, 1.4, 2.0)]))),
        _tv_d("lhs" => "A_full", "rhs" => _tv_op("faq", "tgt_poly"; output_idx = Any["j"], ranges = _tv_d("j" => T), expr = _tv_op("+", 1.0, _tv_ix("tgt_poly", "j", 1, 1)))),
        _tv_d("lhs" => "A_ij", "rhs" => _tv_ref("A_ij_gated_planar"; src_poly = "src_poly", tgt_poly = "tgt_poly", src_nv = 4, tgt_nv = 4)),
    ]
    for n in 1:ntracers
        u, v, E = "u$n", "v$n", "E$n"
        vars[u] = _tv_d("type" => "unknown", "shape" => Any["src_cells"], "default" => 1.0 + 0.1 * n)
        vars[v] = _tv_d("type" => "unknown", "shape" => Any["tgt_cells"], "default" => 0.5)
        vars[E] = _tv_d("type" => "unknown", "shape" => Any["tgt_cells"])
        push!(eqs, _tv_d("lhs" => E, "rhs" => _tv_ref("apply_gated"; A_ij = "A_ij", A_j = "A_full", F_src = u, src_poly = "src_poly", tgt_poly = "tgt_poly", atol = "atol")))
        push!(
            eqs, _tv_d(
                "lhs" => _tv_op("faq"; output_idx = Any["i"], ranges = _tv_d("i" => S), expr = _tv_op("D", _tv_ix(u, "i"); wrt = "t")),
                "rhs" => _tv_op("faq"; output_idx = Any["i"], ranges = _tv_d("i" => S), expr = _tv_op("*", -0.1, _tv_ix(u, "i")))
            )
        )
        push!(
            eqs, _tv_d(
                "lhs" => _tv_op("faq"; output_idx = Any["j"], ranges = _tv_d("j" => T), expr = _tv_op("D", _tv_ix(v, "j"); wrt = "t")),
                "rhs" => _tv_op("faq", E; output_idx = Any["j"], ranges = _tv_d("j" => T), expr = _tv_op("-", _tv_ix(E, "j"), _tv_ix(v, "j")))
            )
        )
    end
    model = _tv_d("variables" => vars, "equations" => eqs, "operators" => _tv_overlap_templates())
    return _tv_d(
        "esm" => "2.0.0", "metadata" => _tv_d("name" => "tv_overlap"),
        "index_sets" => _tv_d(
            "src_cells" => _tv_d("kind" => "interval", "size" => 4), "tgt_cells" => _tv_d("kind" => "interval", "size" => 3),
            "verts" => _tv_d("kind" => "interval", "size" => 4), "coord" => _tv_d("kind" => "interval", "size" => 2)
        ),
        "models" => _tv_d("M" => model)
    )
end

# `du` by state name at a perturbed initial state, and the build's counts.
function _tv_du(input, compiler)
    (r, counts) = _TV.Internal.counting(() -> _TV.Internal.build(input; compiler = compiler))
    f!, u0, p, _, vm = r
    u = Float64[x + 0.01 * k for (k, x) in enumerate(u0)]
    du = similar(u0); fill!(du, NaN)
    f!(du, u, p, 0.3)
    return Dict(k => du[v] for (k, v) in vm), counts
end
_tv_same(a, b) = keys(a) == keys(b) && all(a[k] === b[k] for k in keys(a))
_tv_expanded(doc) = _TV.expand_document(_TV.load_document(doc))

@testset "joined and filtered aggregate bodies read through their view" begin
    for n in (1, 3)
        doc = _tv_overlap_doc(n)
        dn, cn = _tv_du(doc, :native)
        di, ci = _tv_du(doc, :interpreter)
        de, _ = _tv_du(_tv_expanded(doc), :native)
        @test _tv_same(dn, di)
        @test _tv_same(dn, de)
        @test get(cn, :tpl_expanded, 0) == 0
        @test get(ci, :tpl_expanded, 0) == 0
        @test all(isfinite, values(dn))
    end
    # The view: the aggregate's header in the caller, the leaves part calls.
    doc = _tv_overlap_doc(1)
    tt = _TV._TplTable(Dict{String, Any}(doc["models"]["M"]["operators"]))
    ap = _TV._tpl_augment(tt, _TV._tpl_structural_refs(tt, _TV.expression_from_json(doc["models"]["M"]["equations"][5]["rhs"])))
    @test _TV._tpl_compiles(tt, ap)
    v = _TV._tpl_agg_view(tt, ap)
    @test v.op == "faq" && v.join !== nothing && v.output_idx == ["j"]
    @test _TV._tpl_is_call(v.expr_body) && occursin(_TV._TPL_PART, v.expr_body.name)
    @test _TV._tpl_is_call(v.filter) && occursin(_TV._TPL_PART, v.filter.name)
    # The whole-reference body (A_ij_gated_planar = pairs_gated(…)) composes.
    aij = _TV._tpl_augment(tt, _TV.expression_from_json(doc["models"]["M"]["equations"][4]["rhs"]))
    w = _TV._tpl_agg_view(tt, aij)
    @test w.op == "faq" && w.join !== nothing && w.output_idx == ["i", "j"]
    @test _TV._tpl_is_call(w.expr_body)
end

@testset "a call body's reduction over an index set named by a parameter" begin
    D = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "expression_templates", "ranges_from_param")
    function du(path, comp)
        (prob, c) = _TV.Internal.counting(() -> _TV.esm_problem(path, (0.0, 1.0); compiler = comp))
        u = copy(prob.u0) .+ 0.1 .* (1:length(prob.u0))
        d = similar(u); prob.f!(d, u, prob.p, 0.3)
        return d, c
    end
    a, ca = du(joinpath(D, "fixture.esm"), :native)
    b, _ = du(joinpath(D, "fixture.esm"), :interpreter)
    e, _ = du(joinpath(D, "expanded.esm"), :native)
    @test all(a .=== b) && all(a .=== e)
    @test get(ca, :tpl_expanded, 0) == 0
    @test get(ca, :call_targets, 0) >= 2
end

@testset "an elementwise operator over whole array-valued references in a body" begin
    D = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "expression_templates", "flatten_registry_merge_transitive")
    mktempdir() do dir
        for lib in ("stencil_lib.esm", "rule_lib.esm")
            cp(joinpath(D, lib), joinpath(dir, lib))
        end
        raw = JSON3.read(read(joinpath(D, "fixture.esm"), String), Dict{String, Any})
        for m in values(raw["models"])
            m["variables"]["c"]["default"] = 1.0
        end
        haskey(raw, "index_sets") || (raw["index_sets"] = _tv_d("x" => _tv_d("kind" => "interval", "size" => 4)))
        p = joinpath(dir, "fixture.esm")
        write(p, JSON3.write(raw))
        flat = _TV.flatten(_TV.load_path(p))
        function du(f, comp)
            (r, c) = _TV.Internal.counting(() -> _TV.Internal.build(f; compiler = comp))
            f!, u0, pp = r
            u = Float64[1.0 + 0.1 * k for k in eachindex(u0)]
            d = similar(u); f!(d, u, pp, 0.3)
            return d, c
        end
        a, ca = du(flat, :native)
        b, _ = du(flat, :interpreter)
        e, _ = du(_TV.expand_flattened_refs(flat), :native)
        @test all(a .=== b) && all(a .=== e)
        @test get(ca, :tpl_expanded, 0) == 0
        # outer_stencil's body is array-valued: 2.5 * interior_stencil(f)[i1].
        tt = _TV._TplTable(flat.template_registry)
        b = _TV._tpl_def(tt, "A.outer_stencil").closed.body
        @test b.op == "faq" && length(b.output_idx) == 1
        @test _TV._tpl_call_info(tt, "A.outer_stencil") !== nothing
    end
end
