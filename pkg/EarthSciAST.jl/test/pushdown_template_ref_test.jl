# The projection-pushdown desugar THROUGH surviving expression-template
# references (esm-spec §9.6.4 Option B, CONFORMANCE_SPEC §5.5.7).
#
# Option B has `load` PRESERVE `apply_expression_template` references so the
# build boundary can expand them once with site recording. `esm_problem` therefore
# hands `desugar_pushdown` an UNEXPANDED document — and an author who factored a
# binning body through a template used to hide the containment `ifelse` from the
# recogniser, which then declined SILENTLY: no derived support set, no gate, and
# the provider array fetched wholesale (330 GB on isrm.esm, surfacing hours later
# as a memory failure, with the numbers still correct).
#
# Rule 4 ("patterns do not see through surviving references") governs the §9.6.3
# rewrite-rule ENGINE. This is a different consumer, and rule 2 governs it: a
# reference DENOTES its expansion. So the invariant pinned here is:
#
#   whether the pushdown fires MUST NOT depend on whether the author factored
#   the binning body through a template.
#
# The conformance corpus (`tests/conformance/pushdown`, fixture
# `pushdown/template_body`) pins the emitted document cross-binding; this file
# pins the cases a golden document cannot express — the second binding spelling,
# the hard post-condition error, and the residual-diagnostic split.
module PushdownTemplateRefTests

using Test
using EarthSciAST
import JSON
const EA = EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

_ix(f, args...) = Dict{String,Any}("op"=>"index", "args"=>Any[f, args...])
_op(o, args...) = Dict{String,Any}("op"=>o, "args"=>Any[args...])
_apply(name, bindings) = Dict{String,Any}(
    "op"=>"apply_expression_template", "args"=>Any[], "name"=>name,
    "bindings"=>Dict{String,Any}(bindings))
function _agg(output_idx, ranges, expr; reduce=nothing, args=String[], extra...)
    d = Dict{String,Any}("op"=>"aggregate", "output_idx"=>collect(output_idx),
                         "ranges"=>ranges, "args"=>collect(args), "expr"=>expr)
    reduce === nothing || (d["reduce"] = reduce)
    for (k, v) in extra; d[String(k)] = v; end
    return d
end
_param(shape) = Dict{String,Any}("type"=>"parameter", "default"=>0.0, "shape"=>shape)
# The DECLARATION of an observed unknown. From esm 1.0.0 the body is not here —
# it is the variable's defining equation; see `_define!`.
_obs(shape) = Dict{String,Any}("type"=>"unknown", "shape"=>shape)

# The defining right-hand side of `name`, where 0.x kept `variables[name]["expression"]`.
function _defrhs(model, name)
    for eq in model["equations"]
        get(eq, "lhs", nothing) == name && return eq["rhs"]
    end
    error("$(name) has no defining equation")
end

# Declare `name` an observed unknown of `model` and DEFINE it by the
# bare-variable-LHS equation whose LHS is `name`, replacing any definition
# already there (these testsets redeclare `E_PM25` over `base_doc`'s).
function _define!(model, name, shape, expr)
    model["variables"][name] = _obs(shape)
    for eq in model["equations"]
        if get(eq, "lhs", nothing) == name
            eq["rhs"] = expr
            return model
        end
    end
    push!(model["equations"], Dict{String,Any}("lhs"=>name, "rhs"=>expr))
    return model
end
_contain() = _op("and",
    _op("<=", _ix("src_W","c"), _ix("px","r")), _op("<", _ix("px","r"), _ix("src_E","c")),
    _op("<=", _ix("src_S","c"), _ix("py","r")), _op("<", _ix("py","r"), _ix("src_N","c")))
_ERANGES() = Dict{String,Any}("c"=>Dict{String,Any}("from"=>"src_cells"),
                              "r"=>Dict{String,Any}("from"=>"emis_records"))
const _EARGS = ["src_W","src_S","src_E","src_N","px","py","emis_annual"]

# The minimal forward document: one provider-backed SR array, one binning
# `E[c]`, one `conc[rcv]`. Same shape as the `pushdown_gated_dense` fixture.
function base_doc()
    v = Dict{String,Any}()
    for n in ("src_W","src_S","src_E","src_N"); v[n] = _param(["src_cells"]); end
    for n in ("px","py","emis_annual"); v[n] = _param(["emis_records"]); end
    v["SR_PM25"] = _param(["src_cells","rcv_cells"])
    d = Dict{String,Any}(
        "esm"=>"1.0.0", "metadata"=>Dict{String,Any}("name"=>"pd_tmpl"),
        "index_sets"=>Dict{String,Any}(
            "src_cells"=>Dict{String,Any}("kind"=>"interval","size"=>4),
            "rcv_cells"=>Dict{String,Any}("kind"=>"interval","size"=>2),
            "emis_records"=>Dict{String,Any}("kind"=>"interval","size"=>3)),
        "models"=>Dict{String,Any}("Binned"=>Dict{String,Any}(
            "variables"=>v, "equations"=>Any[])))
    m = d["models"]["Binned"]
    # Listed in the §5.5.7 canonical order — definitions sorted by defined name.
    _define!(m, "E_PM25", ["src_cells"], _agg(["c"], _ERANGES(),
        _op("*", _op("ifelse", _contain(), 1.0, 0.0), _ix("emis_annual","r"));
        reduce="+", args=_EARGS))
    _define!(m, "conc_PM25", ["rcv_cells"], _agg(["rcv"],
        Dict{String,Any}("s"=>Dict{String,Any}("from"=>"src_cells"),
                         "rcv"=>Dict{String,Any}("from"=>"rcv_cells")),
        _op("*", _ix("SR_PM25","s","rcv"), _ix("E_PM25","s"));
        reduce="+", args=["SR_PM25","E_PM25"]))
    return d
end

@testset "pushdown sees through surviving template references" begin

    # ---- SPELLING 2: the binding carries the SUBSCRIPTED expression --------
    # (`pushdown/template_body` in the corpus pins spelling 1, the bare factor
    # name.) Here the template body names its params as plain operands and the
    # call site binds `index(src_W, c)`; the rect factor is reached by the same
    # `bindings` traversal, through the `index` arm instead of the string arm.
    @testset "subscripted bindings" begin
        d = base_doc()
        m = d["models"]["Binned"]
        m["expression_templates"] = Dict{String,Any}("bin2"=>Dict{String,Any}(
            "params"=>Any["lo_x","lo_y","hi_x","hi_y","x","y","wgt"],
            "body"=>_op("*", _op("ifelse", _op("and",
                _op("<=", "lo_x", "x"), _op("<", "x", "hi_x"),
                _op("<=", "lo_y", "y"), _op("<", "y", "hi_y")), 1.0, 0.0), "wgt")))
        _define!(m, "E_PM25", ["src_cells"], _agg(["c"], _ERANGES(),
            _apply("bin2", ["lo_x"=>_ix("src_W","c"), "lo_y"=>_ix("src_S","c"),
                            "hi_x"=>_ix("src_E","c"), "hi_y"=>_ix("src_N","c"),
                            "x"=>_ix("px","r"), "y"=>_ix("py","r"),
                            "wgt"=>_ix("emis_annual","r")]);
            reduce="+", args=_EARGS))
        tpl_before = deepcopy(m["expression_templates"])

        r = EA.desugar_pushdown(d; model_name="Binned")
        @test r !== d                                            # it fired
        rv = r["models"]["Binned"]["variables"]
        @test rv["E_PM25"]["shape"] == Any["pd_support__src_cells"]
        edef = _defrhs(r["models"]["Binned"], "E_PM25")
        @test edef["ranges"]["c"]["from"] == "pd_support__src_cells"
        b = edef["expr"]["bindings"]
        @test b["lo_x"]["args"][1] == "pd_cell__src_cells__src_W"
        @test b["hi_y"]["args"][1] == "pd_cell__src_cells__src_N"
        @test b["x"]["args"][1] == "px"                          # records untouched
        # Option B survives: the SHARED body is not edited.
        @test r["models"]["Binned"]["expression_templates"] == tpl_before
        @test EA.desugar_pushdown(r) === r                       # idempotent
        @test isempty(EA.pushdown_diagnostics(d; model_name="Binned"))
    end

    # ---- the HARD error: a rect factor named FREE in the template body -----
    # The rewrite edits call sites only (that is what keeps the body shared and
    # singly-lowered), so a free reference cannot be re-pointed. Left alone it
    # would index the compact per-support cell gathers with FULL-GRID positions —
    # wrong numbers, silently. Hence an error, not a warning.
    @testset "rect factor free in the template body is rejected" begin
        d = base_doc()
        m = d["models"]["Binned"]
        m["expression_templates"] = Dict{String,Any}("bin3"=>Dict{String,Any}(
            "params"=>Any["wgt"],
            "body"=>_op("*", _op("ifelse", _contain(), 1.0, 0.0), _ix("wgt","r"))))
        _define!(m, "E_PM25", ["src_cells"], _agg(["c"], _ERANGES(),
            _apply("bin3", ["wgt"=>"emis_annual"]); reduce="+", args=_EARGS))
        err = try
            EA.desugar_pushdown(d; model_name="Binned"); nothing
        catch e; e end
        @test err isa EA.ExpressionTemplateError
        @test err.code == "template_body_references_pushdown_rewritten_variable"
        @test occursin("src_W", err.message)
        @test occursin("E_PM25", err.message)
        @test occursin("Bind the value through the template's params", err.message)
    end

    # ---- the residual diagnostic: "not a join" vs "a join I cannot read" ---
    @testset "residual diagnostics" begin
        # (a) genuinely dense: no containment anywhere ⇒ SILENT. Firing here
        #     would cry wolf on every ordinary reduction in every document.
        dense = base_doc()
        _define!(dense["models"]["Binned"], "E_PM25", ["src_cells"],
            _agg(["c"], _ERANGES(), _op("*", _ix("emis_annual","r"), 1.0);
                 reduce="+", args=["emis_annual"]))
        @test isempty(EA.pushdown_diagnostics(dense; model_name="Binned"))
        @test EA.desugar_pushdown(dense; model_name="Binned") === dense

        # (b) a surviving reference the detector could NOT see through — here
        #     because the registry is gone, so expansion cannot resolve it. The
        #     document is join-shaped, so this is reported, naming the template.
        orphan = base_doc()
        _define!(orphan["models"]["Binned"], "E_PM25", ["src_cells"],
            _agg(["c"], _ERANGES(), _apply("gone", ["wgt"=>"emis_annual"]);
                 reduce="+", args=_EARGS))
        dg = EA.pushdown_diagnostics(orphan; model_name="Binned")
        @test length(dg) == 1
        @test dg[1]["code"] == "pushdown_join_unrecognised"
        @test dg[1]["reason"] == "surviving_template_reference"
        @test dg[1]["template"] == "gone"
        @test dg[1]["variable"] == "E_PM25"
        @test dg[1]["array"] == "SR_PM25"
        @test dg[1]["index_set"] == "src_cells"
        # a diagnostic is never a rewrite: the document comes back untouched
        @test EA.desugar_pushdown(orphan; model_name="Binned") === orphan
    end

    # ---- ACCEPTANCE: the sanctioned spelling flattens AND is recognised ----
    # `flatten.jl` rejects a template body naming a variable a coupling
    # `variable_map` rewrote (`template_body_references_coupling_rewritten_variable`)
    # and tells the author to "Bind the value through the template's params".
    # That advice must now buy BOTH: a clean flatten and a firing pushdown.
    @testset "coupling-fed factors bound through params: flatten + pushdown" begin
        fx = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "pushdown",
                      "fixtures", "pushdown_l1.esm")
        @test isfile(fx)
        doc = JSON.parsefile(fx)
        m = doc["models"]["ISRM"]
        tpl_contain = _op("and",
            _op("<=", _ix("xmin","c"), _ix("ptx","r")), _op("<", _ix("ptx","r"), _ix("xmax","c")),
            _op("<=", _ix("ymin","c"), _ix("pty","r")), _op("<", _ix("pty","r"), _ix("ymax","c")))
        m["expression_templates"] = Dict{String,Any}("bin_emissions"=>Dict{String,Any}(
            "params"=>Any["xmin","ymin","xmax","ymax","ptx","pty","tot","frac"],
            "body"=>_op("*", _op("ifelse", tpl_contain, 1.0, 0.0),
                             _op("*", _ix("tot","r"), _ix("frac","r")))))
        # `emis_annual` and `is_*` are COUPLING-FED (MockPts.annual → ISRM.emis_annual):
        # naming them in the body would trip the flatten guard; they ride as bindings.
        for (Ename, isp) in (("E_VOC","is_VOC"), ("E_NOx","is_NOx"), ("E_NH3","is_NH3"),
                             ("E_SOx","is_SOx"), ("E_PM25","is_PM25"))
            _defrhs(m, Ename)["expr"] = _apply("bin_emissions",
                ["xmin"=>"src_W", "ymin"=>"src_S", "xmax"=>"src_E", "ymax"=>"src_N",
                 "ptx"=>"X", "pty"=>"Y", "tot"=>"emis_annual", "frac"=>isp])
        end

        file = EA.load_document(doc)
        @test file.component_templates !== nothing
        @test haskey(file.component_templates, "models.ISRM")
        EA.flatten(file)                                # the guard must NOT fire

        raw = EA.serialize_esm_file(EA.load_document(doc))        # the `esm_problem` input form
        r = EA.desugar_pushdown(raw; model_name="ISRM")
        @test r !== raw
        rec = r["metadata"]["x_esd"]["pushdown"]
        @test rec["derived_set"] == "pd_support__src_cells"
        # EVERY declared provider-backed array is gated, not just the first.
        @test sort(String.(rec["gated_select"]["applies_to"])) ==
              ["SR_PrimaryPM25", "SR_SOA", "SR_pNH4", "SR_pNO3", "SR_pSO4"]
        for E in ("E_VOC","E_NOx","E_NH3","E_SOx","E_PM25")
            ex = _defrhs(r["models"]["ISRM"], E)
            @test r["models"]["ISRM"]["variables"][E]["shape"] == Any["pd_support__src_cells"]
            @test ex["ranges"]["c"]["from"] == "pd_support__src_cells"
            @test haskey(ex, "join")
            @test ex["expr"]["bindings"]["xmin"] == "pd_cell__src_cells__src_W"
        end
        @test r["models"]["ISRM"]["expression_templates"] ==
              raw["models"]["ISRM"]["expression_templates"]     # body untouched
        @test isempty(EA.pushdown_diagnostics(raw; model_name="ISRM"))
    end
end

end # module PushdownTemplateRefTests
