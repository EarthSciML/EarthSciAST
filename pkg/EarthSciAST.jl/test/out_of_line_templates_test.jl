# Conformance tests for the out-of-line-expression-templates RFC (Option B,
# reference-preserving expression templates): esm-spec §9.6.4 (rules 1-8),
# §9.6.7 (new fixtures), §9.6.9 (validation discharge), §10.7 (flatten registry
# merge). Drives tests/conformance/expression_templates/{emit_*, eager_*,
# opacity_*, per_instantiation_validation, flatten_registry_merge}.

using Test
using JSON3
using EarthSciAST
using EarthSciAST: lower_expression_templates, resolve_template_machinery,
    Expand, expand_document, emit_document, emit_esm_string,
    flatten_template_registries, ExpressionTemplateError,
    serialize_esm_file

include("testutils.jl")

# esm 1.0.0 (esm-spec §6.3.1): an observed unknown's defining right-hand side is
# a bare-variable-LHS EQUATION, not a field on the declaration. These documents
# are RAW (unparsed), so the lookup is by hand.
function _ool_defrhs(model, name::AbstractString)
    for eq in model["equations"]
        get(eq, "lhs", nothing) == name && return eq["rhs"]
    end
    error("no defining equation for '$name'")
end

@testset "out-of-line expression templates (Option B, esm-spec §9.6.4)" begin
    conf(parts...) = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                              "expression_templates", parts...)

    # Load a fixture under Option B (references preserved), returning the raw
    # loaded document view.
    function _load(dir, fixture="fixture.esm")
        fp = conf(dir, fixture)
        raw = JSON3.read(read(fp, String))
        resolved = resolve_template_machinery(raw, dirname(fp))
        return lower_expression_templates(resolved === nothing ? raw : resolved)
    end
    _emit(dir, fixture="fixture.esm") = begin
        fp = conf(dir, fixture)
        emit_esm_string(emit_document(JSON3.read(read(fp, String)), dirname(fp)))
    end
    _isapply(x) = x isa AbstractDict && get(x, "op", nothing) == "apply_expression_template"

    # -----------------------------------------------------------------------
    # BRIDGE GATE (esm-spec §9.6.7, RFC §12 gate 1): Expand(load(fixture)) is
    # structurally equal to the existing expanded*.esm oracle. The 21 goldens
    # are NOT regenerated — they are the Option-A image `Expand` must reproduce.
    # -----------------------------------------------------------------------
    @testset "bridge: Expand(load) == expanded oracle (21 goldens)" begin
        _core(d) = Dict(k => _normj(get(d, k, nothing))
                        for k in ("models", "reaction_systems", "coupling", "index_sets")
                        if haskey(d, k))
        # (dir, fixture, golden) — the raw-pipeline goldens (the two scope-
        # injection + metaparameter goldens go through the typed load path and
        # are pinned by scope_injection_test.jl / template_imports_test.jl).
        cases = [
            ("aggregate_int_ratio_golden", "fixture.esm", "expanded.esm"),
            ("arrhenius_smoke", "fixture.esm", "expanded.esm"),
            ("constrained_match_scope", "fixture.esm", "expanded.esm"),
            ("coupling_transform_expression", "fixture.esm", "expanded.esm"),
            ("fixpoint_nested_deriv", "fixture.esm", "expanded.esm"),
            ("godunov_beats_inner_deriv", "fixture.esm", "expanded.esm"),
            ("import_diamond", "fixture.esm", "expanded.esm"),
            ("import_order_determinism", "fixture_import_order.esm", "expanded_import_order.esm"),
            ("import_order_determinism", "fixture_priority_override.esm", "expanded_priority_override.esm"),
            ("import_rebind_keyed_factors", "fixture.esm", "expanded.esm"),
            ("import_rename_diamond", "fixture.esm", "expanded.esm"),
            ("import_rename_two_instances", "fixture.esm", "expanded.esm"),
            ("import_smoke", "fixture.esm", "expanded.esm"),
            ("import_where_rename_two_instances", "fixture.esm", "expanded.esm"),
            ("per_variable_scheme_literal_args", "fixture.esm", "expanded.esm"),
            ("scalar_field_param", "fixture.esm", "expanded.esm"),
            ("two_div_two_meshes", "fixture.esm", "expanded.esm"),
        ]
        for (dir, fix, gold) in cases
            got = _core(Expand(_load(dir, fix)))
            want = _core(JSON3.read(read(conf(dir, gold), String)))
            @test got == want
        end
    end

    # -----------------------------------------------------------------------
    # Expand determinism (§9.6.4 rule 2): two expansions of the same
    # (template, bindings) produce structurally identical ASTs, bit-equal
    # constants; caching unobservable.
    # -----------------------------------------------------------------------
    @testset "Expand is deterministic (rule 2)" begin
        loaded = _load("import_smoke")
        @test _normj(Expand(loaded)) == _normj(Expand(loaded))
        # non-destructive: the loaded view still carries surviving references
        d = loaded
        mk = d["models"]["Advection"]["equations"][1]["rhs"]["args"][2]
        @test _normj(mk)["op"] == "makearray"
    end

    # -----------------------------------------------------------------------
    # emit_materialized_registry (§9.6.4 rule 5, §9.6.7)
    # -----------------------------------------------------------------------
    @testset "emit_materialized_registry: imports gone, stencils materialized" begin
        s = _emit("emit_materialized_registry")
        @test s == read(conf("emit_materialized_registry", "emitted.esm"), String)
        doc = JSON3.read(s)
        adv = doc["models"]["Advection"]
        # Rule 8's stamp is a MINIMUM ("a consumer needs at least this"), so it
        # only ever raises: a 1.0.0 source keeps 1.0.0 rather than being
        # downgraded to a schema that cannot describe it.
        @test doc["esm"] == EarthSciAST.ESM_FORMAT_VERSION
        @test EarthSciAST._esm_stamp_floor("0.8.0") == "0.9.0"   # below the floor: raised
        @test EarthSciAST._esm_stamp_floor("1.0.0") == "1.0.0"   # at/above: untouched
        @test !haskey(adv, "expression_template_imports")     # imports consumed
        reg = adv["expression_templates"]
        @test Set(string.(keys(reg))) == Set(["central_D_lon_interior", "dlon_deg"])  # match-less only
        @test !haskey(reg, "central_D_lon_zero_grad_bc")      # match rule not materialized
        # Call site intact: the makearray interior region is a surviving ref.
        interior = adv["equations"][1]["rhs"]["args"][2]["values"][1]
        @test _isapply(interior) && interior["name"] == "central_D_lon_interior"
        # idempotency (§9.6.4 rule 5 / RFC gate 2)
        s2 = emit_esm_string(emit_document(JSON3.read(s),
                    dirname(conf("emit_materialized_registry", "emitted.esm"))))
        @test s2 == s
    end

    # -----------------------------------------------------------------------
    # emit_rename_dotted_keys (§9.6.4 rule 5, §7.5.6 dotted keys)
    # -----------------------------------------------------------------------
    @testset "emit_rename_dotted_keys: dotted registry keys on disk" begin
        s = _emit("emit_rename_dotted_keys")
        @test s == read(conf("emit_rename_dotted_keys", "emitted.esm"), String)
        doc = JSON3.read(s)
        reg = doc["models"]["TwoGrids"]["expression_templates"]
        @test Set(string.(keys(reg))) == Set(["fine.dx", "coarse.dx"])   # dotted keys
        @test Set(string.(keys(doc["index_sets"]))) == Set(["fine.x", "coarse.x"])
    end

    # -----------------------------------------------------------------------
    # eager_target_bearing (§9.6.4 rule 3, §9.6.7): positive + negative.
    # -----------------------------------------------------------------------
    @testset "eager_target_bearing: eager expands+lowers, target-free survives" begin
        loaded = _load("eager_target_bearing")
        d = loaded
        m = d["models"]["m"]
        # POSITIVE: deriv_c (D-bearing) reference eagerly expanded, then the D
        # lowered by the `central` rule → an aggregate. No surviving ref.
        deager = _normj(_ool_defrhs(m, "d_eager"))
        @test deager["op"] == "index"
        @test deager["args"][1]["op"] == "aggregate"
        # NEGATIVE: scale_c (target-free) reference SURVIVES.
        dsurv = _normj(_ool_defrhs(m, "d_survive"))
        @test _isapply(dsurv["args"][1]) && dsurv["args"][1]["name"] == "scale_c"
        # Emit golden.
        @test _emit("eager_target_bearing") ==
              read(conf("eager_target_bearing", "emitted.esm"), String)
    end

    # -----------------------------------------------------------------------
    # opacity_negative (§9.6.4 rule 4): the compound pattern MUST NOT fire
    # across a surviving-reference boundary.
    # -----------------------------------------------------------------------
    @testset "opacity_negative: compound rule does not see through a reference" begin
        loaded = _load("opacity_negative")
        d = loaded
        flux = _normj(_ool_defrhs(d["models"]["m"], "flux"))
        @test flux["op"] == "D"                    # compound did NOT fire (no marker 999)
        @test _isapply(flux["args"][1])            # its arg is the surviving reference
        @test flux["args"][1]["name"] == "flux_prod"
        @test _emit("opacity_negative") ==
              read(conf("opacity_negative", "emitted.esm"), String)
    end

    # -----------------------------------------------------------------------
    # opacity_priority_shadowing (§9.6.4 rule 4): the silent divergence — the
    # high-priority compound rule does NOT fire; a lower-priority generic rule
    # DOES, binding the surviving reference whole.
    # -----------------------------------------------------------------------
    @testset "opacity_priority_shadowing: generic fires, compound silently does not" begin
        loaded = _load("opacity_priority_shadowing")
        d = loaded
        flux = _normj(_ool_defrhs(d["models"]["m"], "flux"))
        @test flux["op"] == "*"
        @test flux["args"][1] == 1                 # generic marker (NOT compound 999)
        @test _isapply(flux["args"][2])            # reference bound WHOLE by metavariable f
        @test flux["args"][2]["name"] == "flux_prod"
        @test _emit("opacity_priority_shadowing") ==
              read(conf("opacity_priority_shadowing", "emitted.esm"), String)
    end

    # -----------------------------------------------------------------------
    # per_instantiation_validation (§9.6.9): manifold param, two call sites,
    # one inadmissible → geometry_manifold_invalid naming the call site.
    # -----------------------------------------------------------------------
    @testset "per_instantiation_validation: memoized manifold check names call site" begin
        err = try
            _load("per_instantiation_validation"); nothing
        catch e
            e
        end
        @test err isa ExpressionTemplateError
        @test err.code == "geometry_manifold_invalid"
        @test occursin("area_bad", err.message)     # offending call site named
        @test occursin("overlap", err.message)       # template name named
    end

    # -----------------------------------------------------------------------
    # flatten_registry_merge (§9.6.4 rule 7, §10.7): dedup + owner-path rename.
    # -----------------------------------------------------------------------
    @testset "flatten_registry_merge: dedup + deterministic collision rename" begin
        loaded = _load("flatten_registry_merge")
        root, merged = flatten_template_registries(loaded)
        @test Set(keys(merged)) == Set(["sten", "A.s", "B.s"])     # dedup + rename
        @test _normj(merged["sten"]["body"]) == Dict("op" => "*", "args" => Any[2, "f"])
        # references rewritten in lockstep
        @test _ool_defrhs(root["models"]["A"], "za")["name"] == "A.s"
        @test _ool_defrhs(root["models"]["B"], "zb")["name"] == "B.s"
        @test _ool_defrhs(root["models"]["A"], "ya")["name"] == "sten"
        @test _ool_defrhs(root["models"]["B"], "yb")["name"] == "sten"
        # per-component blocks surrendered to the merged registry
        @test !haskey(root["models"]["A"], "expression_templates")
        @test !haskey(root["models"]["B"], "expression_templates")
        # The typed FlattenedSystem carries the same merged registry as a
        # first-class field (esm-libraries-spec §4.7.5 step 4).
        flat = EarthSciAST.flatten(EarthSciAST.load(conf("flatten_registry_merge", "fixture.esm")))
        @test Set(keys(flat.template_registry)) == Set(["sten", "A.s", "B.s"])
    end

    # -----------------------------------------------------------------------
    # flatten_registry_merge_transitive (§9.6.4 rule 7, §10.7): TWO models in
    # ONE document import the same rule library. `interior_stencil` folds
    # differently per model (B rebinds its free `inv_dx`) and collides; the
    # byte-identical `outer_stencil` that REFERENCES it must collide too — a
    # single deduped `outer_stencil` would carry a reference to a name the
    # merged registry no longer holds, and expansion would fail with
    # `apply_expression_template_unknown_template` naming a transitively
    # imported stencil no model ever mentioned.
    # -----------------------------------------------------------------------
    @testset "flatten_registry_merge_transitive: collisions propagate along refs" begin
        dir = "flatten_registry_merge_transitive"
        _names(x) = EarthSciAST._collect_apply_names!(String[], x)
        loaded = _load(dir)
        root, merged = flatten_template_registries(loaded)
        @test Set(keys(merged)) == Set(["A.interior_stencil", "A.outer_stencil",
                                        "B.interior_stencil", "B.outer_stencil"])
        # Each owner's wrapper reaches its OWN leaf, never the other model's.
        @test _names(merged["A.outer_stencil"]["body"]) == ["A.interior_stencil"]
        @test _names(merged["B.outer_stencil"]["body"]) == ["B.interior_stencil"]
        # Component reference sites follow in lockstep.
        @test _names(root["models"]["A"]["equations"]) == ["A.outer_stencil"]
        @test _names(root["models"]["B"]["equations"]) == ["B.outer_stencil"]

        # The executing path: the typed FlattenedSystem's registry agrees, and
        # every surviving reference resolves against it — `expand_flattened_refs`
        # is the call that threw before the fix.
        flat = EarthSciAST.flatten(EarthSciAST.load(conf(dir, "fixture.esm")))
        @test Set(keys(flat.template_registry)) == Set(keys(merged))
        @test EarthSciAST.expand_flattened_refs(flat) isa EarthSciAST.FlattenedSystem
    end

    # -----------------------------------------------------------------------
    # The plain multi-model regression: N IDENTICAL models in one document.
    # Nothing collides in the authored registries, but `flatten` COMPONENT-SCOPES
    # each carried body's free variables (§10.7), so every body mentioning a
    # component variable becomes per-component distinct and renames. Before the
    # fix the reference sites did not follow and even the FIRST model's
    # references dangled — though that same model loaded and ran on its own.
    # Also asserts the two models stay independent: no equation of one reaches
    # into the other's namespace.
    # -----------------------------------------------------------------------
    @testset "multi-model: identical models each resolve their own registry" begin
        dir = "flatten_registry_merge_transitive"
        raw = JSON3.read(read(conf(dir, "fixture.esm"), String))
        mktempdir() do d
            for lib in ("stencil_lib.esm", "rule_lib.esm")
                cp(conf(dir, lib), joinpath(d, lib))
            end
            doc = Dict{String,Any}(String(k) => v for (k, v) in pairs(raw))
            # B becomes a byte-identical twin of A: nothing distinguishes the two
            # registries until component scoping runs.
            doc["models"] = Dict{String,Any}("A" => raw["models"]["A"],
                                             "B" => raw["models"]["A"])
            path = joinpath(d, "twins.esm")
            open(io -> JSON3.write(io, doc), path, "w")
            flat = EarthSciAST.flatten(EarthSciAST.load(path))
            @test Set(keys(flat.template_registry)) ==
                  Set(["A.interior_stencil", "A.outer_stencil",
                       "B.interior_stencil", "B.outer_stencil"])
            expanded = EarthSciAST.expand_flattened_refs(flat)
            # Twin models ⇒ twin equation sets, modulo the namespace prefix.
            _ser(eq) = JSON3.write(EarthSciAST.serialize_expression(eq.lhs)) * "~" *
                       JSON3.write(EarthSciAST.serialize_expression(eq.rhs))
            eqs = Set(_ser(eq) for eq in expanded.equations)
            a_eqs = [s for s in eqs if occursin("A.", s)]
            @test !isempty(a_eqs)
            @test all(replace(s, "A." => "B.") in eqs for s in a_eqs)
        end
    end

    # -----------------------------------------------------------------------
    # flatten_registry_merge_transitive/fixture_twins.esm (§9.6.4 rule 7,
    # §10.7): the SCOPING PRECONDITION, with BOTH halves pinned side by side.
    # Two byte-identical models import the same rule library;
    # `interior_stencil`'s body references the free name `inv_dx`, a model-local
    # parameter that denotes a DIFFERENT variable in each model.
    #
    #   - `flatten_template_registries` is the UNION half only, over the
    #     un-namespaced component view — the surface all five bindings share.
    #     Identical bodies dedupe under their bare names; the returned pair is
    #     self-consistent with the un-namespaced document, and the bodies keep
    #     their free `inv_dx`.
    #   - the executing `flatten` composes the §10.7 component SCOPING with that
    #     merge. Scoping rewrites `inv_dx` to `A.inv_dx` / `B.inv_dx`, which
    #     makes the two copies non-deep-equal and forces the owner-path rename of
    #     all four entries (the wrapper via the reference-DAG propagation).
    #
    # Deduping BEFORE scoping would keep one body whose `inv_dx` is correct for
    # neither model — which is exactly why the ordering is normative. Julia is
    # the only binding whose flattened representation carries a registry, so it
    # is the only one that can pin the composition; the other four pin the union
    # half against this same fixture (§10.7, "Applicability across bindings").
    # -----------------------------------------------------------------------
    @testset "registry merge: union half vs. scoping∘merge" begin
        dir = "flatten_registry_merge_transitive"
        _names(x) = EarthSciAST._collect_apply_names!(String[], x)
        loaded = _load(dir, "fixture_twins.esm")
        root, merged = flatten_template_registries(loaded)
        # Union half: dedup under the bare names.
        @test Set(keys(merged)) == Set(["interior_stencil", "outer_stencil"])
        @test _names(merged["outer_stencil"]["body"]) == ["interior_stencil"]
        @test _names(root["models"]["A"]["equations"]) == ["outer_stencil"]
        @test _names(root["models"]["B"]["equations"]) == ["outer_stencil"]
        # …and the free variable is NOT component-scoped by that surface.
        body = JSON3.write(merged["interior_stencil"]["body"])
        @test occursin("\"inv_dx\"", body)
        @test !occursin("A.inv_dx", body) && !occursin("B.inv_dx", body)

        # scoping ∘ merge: the executing flatten renames all four entries, and
        # every surviving reference resolves against the carried registry.
        flat = EarthSciAST.flatten(EarthSciAST.load(conf(dir, "fixture_twins.esm")))
        @test Set(keys(flat.template_registry)) ==
              Set(["A.interior_stencil", "A.outer_stencil",
                   "B.interior_stencil", "B.outer_stencil"])
        @test EarthSciAST.expand_flattened_refs(flat) isa EarthSciAST.FlattenedSystem
    end

    # -----------------------------------------------------------------------
    # Idempotency property over every new emit fixture (RFC §12 gate 2).
    # -----------------------------------------------------------------------
    @testset "emit ∘ load byte-wise fixed point (all emit fixtures)" begin
        for dir in ["emit_materialized_registry", "emit_rename_dotted_keys",
                    "eager_target_bearing", "opacity_negative",
                    "opacity_priority_shadowing"]
            s1 = _emit(dir)
            s2 = emit_esm_string(emit_document(JSON3.read(s1), conf(dir)))
            @test s1 == s2
        end
    end

    # -----------------------------------------------------------------------
    # Typed save == raw emit_document, byte-identically (esm-spec §9.6.4 rule 5
    # / R1): `apply_expression_template` references survive into the typed IR and
    # the per-component registries ride on the EsmFile, so the canonical typed
    # serialization is byte-identical to the raw `emit_document` path AND to the
    # committed `emitted.esm` golden. Also asserts the typed EsmFile actually
    # carries the surviving references (not the Expand-stripped form).
    # -----------------------------------------------------------------------
    @testset "typed save is reference-preserving, byte-identical to emit_document" begin
        for dir in ["emit_materialized_registry", "emit_rename_dotted_keys",
                    "eager_target_bearing", "opacity_negative",
                    "opacity_priority_shadowing"]
            f = EarthSciAST.load(conf(dir, "fixture.esm"))
            @test f.component_templates !== nothing        # registries survive into typed IR
            typed_bytes = emit_esm_string(serialize_esm_file(f))
            raw_bytes = emit_esm_string(emit_document(
                JSON3.read(read(conf(dir, "fixture.esm"), String)), conf(dir)))
            golden = read(conf(dir, "emitted.esm"), String)
            @test typed_bytes == raw_bytes            # typed save == raw emit
            @test typed_bytes == golden               # == the committed golden
        end
        # ESS_TEMPLATE_REF_DISABLE=1 → Expand-at-load: references gone from the
        # typed IR, save reverts to the historical (expanded) form.
        withenv("ESS_TEMPLATE_REF_DISABLE" => "1") do
            f = EarthSciAST.load(conf("opacity_negative", "fixture.esm"))
            @test f.component_templates === nothing
        end
        # A template-LIBRARY file round-trips to itself (authored declarations
        # survive verbatim, §9.6.4 rule 5): the top-level registry is preserved.
        lib = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "template_import_lib.esm")
        if isfile(lib)
            lf = EarthSciAST.load(lib)
            @test lf.expression_templates !== nothing
            @test !isempty(lf.expression_templates)
        end
    end

    # -----------------------------------------------------------------------
    # Gate (d) — differential build (RFC §12 gate 3). The reference-aware
    # tree-walk build (references ALWAYS carried through flatten, expanded at
    # the build boundary against the merged `template_registry` — THE default
    # path) MUST be bit-identical to (a) the `expand_flattened_refs` boundary
    # utility's Expand image (RFC §7.7 "Expand at your boundary") and (b) the
    # `ESS_TEMPLATE_REF_DISABLE=1` Expand-at-load image — the ONE remaining
    # escape hatch. Compares the built `f!(du,u,p,t)` on several random
    # states — a stronger check than comparing only the solved trajectory (it
    # pins the RHS everywhere). The 3-axis 7×7×7
    # `tests/bench/transport_3axis_7cubed.esm` reference-heavy fixture is the
    # committed measurement stack (§12).
    # -----------------------------------------------------------------------
    @testset "gate (d): reference-aware build ≡ Expand build (bit-identical f!)" begin
        F = joinpath(TESTUTILS_REPO_ROOT, "tests", "bench", "transport_3axis_7cubed.esm")
        if isfile(F)
            f = EarthSciAST.load(F)
            @test f.component_templates !== nothing               # references survive load
            flat_fast = EarthSciAST.flatten(f)                    # references reach the build
            @test !isempty(flat_fast.template_registry)           # merged registry carried
            f1!, u01, p1, _t1, vm1 = EarthSciAST.build_evaluator(flat_fast)
            # The shared boundary utility: Expand the FlattenedSystem in place
            # of the build-entry expansion — the consumer-side fallback path.
            flat_exp = EarthSciAST.expand_flattened_refs(flat_fast)
            f2!, u02, p2, _t2, vm2 = EarthSciAST.build_evaluator(flat_exp)
            @test vm1 == vm2
            n = length(u01)
            # Deterministic, varied probe vectors (no RNG dependency).
            _probe(s) = Float64[sin(0.6k + 1.7s) + 0.3cos(0.31k - s) for k in 1:n]
            for s in (1, 7, 42)
                u = _probe(s)
                du1 = zeros(n); du2 = zeros(n)
                f1!(du1, u, p1, 0.3)
                f2!(du2, u, p2, 0.3)
                @test du1 == du2                                  # bit-identical RHS
            end
            # And bit-identical to the ESS_TEMPLATE_REF_DISABLE=1 Expand-at-load path.
            fd = withenv("ESS_TEMPLATE_REF_DISABLE" => "1") do
                EarthSciAST.load(F)
            end
            @test fd.component_templates === nothing
            f3!, u03, p3, _t3, _vm3 = EarthSciAST.build_evaluator(
                EarthSciAST.flatten(fd))
            u = _probe(1)
            du1 = zeros(n); du3 = zeros(n)
            f1!(du1, u, p1, 0.3); f3!(du3, u, p3, 0.3)
            @test du1 == du3
        end
    end
    # -----------------------------------------------------------------------
    # `expand_flattened_refs` covers EVERY expression-bearing variable, not
    # just the observeds. `_collect_model!` (namespacing.jl) namespaces
    # `v.expression` for EVERY variable type BEFORE partitioning it into the
    # flattened buckets — states to `state_variables`, parameters AND discrete
    # variables to `parameters`, observeds to `observed_variables` — and the
    # schema only REQUIRES an `expression` on an observed, it does not forbid
    # one elsewhere. So any of the three buckets can legally carry a surviving
    # `apply_expression_template`, and a consumer promised the Option-A image
    # (RFC §7.7 "Expand at your boundary") must not find an Option-B node in
    # one. Also pins memo-on ≡ memo-off, the sharing invariant item (2) rests
    # on: the expansion is a pure function of (template, bindings, registry),
    # so reusing one site's result at another is a DAG, never a different tree.
    # -----------------------------------------------------------------------
    @testset "expand_flattened_refs: every variable bucket, memo on ≡ off" begin
        OD = EarthSciAST.OrderedDict
        # A real FlattenedSystem to inherit the un-exercised fields from; its
        # own registry is empty, so everything under test is injected below.
        base = mktempdir() do d
            path = joinpath(d, "trivial.esm")
            open(io -> JSON3.write(io, Dict{String,Any}(
                "esm" => "0.8.0",
                "metadata" => Dict{String,Any}("name" => "trivial"),
                "models" => Dict{String,Any}("m" => Dict{String,Any}(
                    "variables" => Dict{String,Any}(
                        "c" => Dict{String,Any}("type" => "state", "units" => "1",
                                                "default" => 1.0)),
                    "equations" => Any[Dict{String,Any}(
                        "lhs" => Dict{String,Any}("op" => "D", "args" => Any["c"],
                                                  "wrt" => "t"),
                        "rhs" => Dict{String,Any}("op" => "-", "args" => Any["c"]))])))),
                path, "w")
            EarthSciAST.flatten(EarthSciAST.load(path))
        end
        @test isempty(base.template_registry)

        reg = Dict{String,Any}("scale" => Dict{String,Any}(
            "params" => Any["a"],
            "body" => Dict{String,Any}("op" => "*", "args" => Any["a", 2])))
        _apply(v) = EarthSciAST.OpExpr("apply_expression_template",
            EarthSciAST.ASTExpr[]; name = "scale",
            bindings = Dict{String,EarthSciAST.ASTExpr}("a" => EarthSciAST.VarExpr(v)))
        _var(t, e; kw...) = EarthSciAST.ModelVariable(t; expression = e, kw...)

        flat = EarthSciAST.FlattenedSystem(base;
            template_registry = reg,
            state_variables = OD{String,EarthSciAST.ModelVariable}(
                "m.c" => base.state_variables["m.c"],
                "m.s" => _var(EarthSciAST.StateVariable, _apply("m.c"))),
            parameters = OD{String,EarthSciAST.ModelVariable}(
                "m.p" => _var(EarthSciAST.ParameterVariable, _apply("m.c")),
                "m.d" => _var(EarthSciAST.DiscreteVariable, _apply("m.c");
                              shape = Any["x"])),
            observed_variables = OD{String,EarthSciAST.ModelVariable}(
                "m.o" => _var(EarthSciAST.ObservedVariable, _apply("m.c"))),
            equations = EarthSciAST.Equation[
                EarthSciAST.Equation(base.equations[1].lhs, _apply("m.c"))])

        _hasapply(e) = e === nothing ? false : begin
            hit = false
            EarthSciAST.foreach_subexpr(x -> (hit |= x isa EarthSciAST.OpExpr &&
                                              x.op == "apply_expression_template"), e)
            hit
        end
        # Precondition: the reference really is in every bucket before expansion.
        @test _hasapply(flat.state_variables["m.s"].expression)
        @test _hasapply(flat.parameters["m.p"].expression)
        @test _hasapply(flat.parameters["m.d"].expression)
        @test _hasapply(flat.observed_variables["m.o"].expression)
        @test _hasapply(flat.equations[1].rhs)

        _buckets(f) = (f.state_variables, f.parameters, f.observed_variables)
        for memo in (nothing, Dict{Tuple{String,String},EarthSciAST.OpExpr}())
            ex = EarthSciAST.expand_flattened_refs(flat; memo = memo)
            for b in _buckets(ex), (_, v) in b
                @test !_hasapply(v.expression)
            end
            @test !_hasapply(ex.equations[1].rhs)
            # …and the expansion is the template body with `a := m.c`.
            @test EarthSciAST.serialize_expression(ex.parameters["m.p"].expression) ==
                  EarthSciAST.serialize_expression(ex.observed_variables["m.o"].expression)
            # Non-expression fields survive the rebuild.
            @test ex.parameters["m.d"].type == EarthSciAST.DiscreteVariable
            @test ex.parameters["m.d"].shape == Any["x"]
            @test ex.state_variables["m.c"] === base.state_variables["m.c"]
        end
        _ser(f) = JSON3.write(Any[
            Any[[k, EarthSciAST.serialize_expression(v.expression)] for (k, v) in b
                if v.expression !== nothing] for b in _buckets(f)],
            ) * "~" * JSON3.write(Any[EarthSciAST.serialize_expression(eq.rhs)
                                      for eq in f.equations])
        @test _ser(EarthSciAST.expand_flattened_refs(flat; memo = nothing)) ==
              _ser(EarthSciAST.expand_flattened_refs(flat))
    end
end
