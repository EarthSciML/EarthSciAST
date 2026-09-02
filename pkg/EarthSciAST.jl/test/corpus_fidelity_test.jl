# Corpus round-trip FIDELITY: `save(load(F))` against **F itself**.
#
# `conformance_round_trip_test.jl` compares emit pass 2 against emit pass 3 —
# it proves the pipeline reaches a fixed point, which it does even when the
# fixed point has thrown half the document away. It cannot see a field that is
# lost on the FIRST load, because passes 2 and 3 agree perfectly about not
# having it. An audit against the original found 47 of the 94 `tests/valid`
# fixtures differing that way: `Model.reference` (26 fixtures),
# `ReactionSystem.reference` (11), a reaction-system parameter's `update` and
# `shape`, `ContinuousEvent.affect_neg` / `root_find`, `DiscreteEvent.reinitialize`,
# `DataSource.reader_options` / `record_filter` / `extent`, `analyses`, and more.
#
# That matters most HERE because Julia is the reference binding: the
# template-import goldens and the PDE / cadence / determinism producer chains
# take Julia's emit as the oracle, so a field Julia drops is missing from the
# goldens every other binding is then gated against.
#
# This file is the gate that would have caught them. Deliberately a NEW file
# and not an addition to the fixed-point test: the two ask different questions
# and one must not be able to satisfy the other.
#
# ── What "differs" means here ────────────────────────────────────────────────
# Exact JSON equality, with two documented relaxations, both applied to BOTH
# sides so neither can hide a drop:
#
#   1. Empty containers. `[]` / `{}` are stripped, because the emitters' uniform
#      `:nonempty` policy omits an empty collection — `"discrete_events": []`
#      re-emits as absent, which is the same document.
#   2. Written-out schema DEFAULTS the emitter omits: `domain.independent_variable`
#      when it is `"t"`, and a periodic trigger's `initial_offset` when it is `0`.
#      Emitting these unconditionally instead would not fix anything, it would
#      just move the difference onto every document that omits them.
#
# There was a third — `expect_cadence` was stripped from both sides — and it
# was this gate's own blind spot: the `tests/valid/cadence/` tier exists to pin
# the §5.7 partition contract, and its 41 assertions were being compared
# against nothing. The typed IR carries the field now; see `_relaxed_key`.
#
# Everything else must match, and int-vs-float spelling is the only scalar
# latitude (Julia's `==` gives `1 == 1.0`).
#
# ── The exemption list ───────────────────────────────────────────────────────
# `TRANSFORMED_AT_LOAD` names every fixture the spec REQUIRES `load` to rewrite,
# with the rule that requires it. It is an explicit list rather than a heuristic
# on purpose: a newly added fixture is held to exact fidelity by default and has
# to be named here, with a reason, before it is allowed to differ. A fixture
# listed here that starts round-tripping exactly is also a failure — the list
# would then be stale.

using Test
using JSON3
using OrderedCollections
using EarthSciAST

include("testutils.jl")

@testset "corpus round-trip fidelity (save(load(F)) == F)" begin

    # Spec-mandated load-time rewrites. Key: path relative to the repo root.
    TRANSFORMED_AT_LOAD = Dict{String,String}(
        # esm-spec §8.2.1: a scheme-less `source.url_template` is a filesystem
        # path, and a relative one resolves at load against the directory of the
        # file that declared it — the same base and the same timing rule §4.7
        # fixes for a `ref`. So the emitted template is the resolved absolute
        # `file://` URL, which is machine-specific; the resolved values are
        # pinned as repo-relative paths in
        # tests/conformance/data_source_url/manifest.json (CONFORMANCE_SPEC
        # §5.19) rather than as a golden here.
        "tests/valid/data_source_relative_url.esm" =>
            "esm-spec §8.2.1: a relative `source.url_template` resolves against the declaring file's directory",
        # §9.6.4 rule 3 eager template expansion / rule 5 `match`-only registry drop.
        "tests/valid/advection_reaction_loaded_ic_bc.esm" =>
            "esm-spec §9.6.4 rule 3: eager expansion of the derivative templates",
        "tests/valid/derivative_trailing_boundary_operands.esm" =>
            "esm-spec §9.6.4 rule 3 + rule 5: the component's `match`-only block is REQUIRED to be dropped",
        "tests/valid/template_import_minimal.esm" =>
            "esm-spec §9.7: `expression_template_imports` is consumed at load; the call site expands",
        "tests/valid/template_import_lib.esm" =>
            "esm-spec §9.7.6: metaparameter folding sizes `index_sets.cells`",
        "tests/valid/template_import_rename_lib.esm" =>
            "esm-spec §9.7.6: metaparameter folding sizes `index_sets.edges`",
        # §9.7.6 metaparameter folding.
        "tests/valid/data_sources_ingest_and_select.esm" =>
            "esm-spec §9.7.6: metaparameters N_SRC / N_REC / N_POP fold to integers",
        "tests/valid/makearray_empty_region_min_extent.esm" =>
            "esm-spec §9.7.6: metaparameter N folds into ranges and regions",
        # §9.3 enum lowering.
        "tests/valid/enums_categorical_lookup.esm" =>
            "esm-spec §9.3: `enum` op nodes are lowered to `const` integers at load",
        # §4.7 subsystem `{ref}` resolution.
        "tests/valid/lib_calendar_subsystem_inclusion.esm" =>
            "esm-spec §4.7: a `{ref}` subsystem is resolved and inlined at load",
        "tests/valid/lib_solar_subsystem_inclusion.esm" =>
            "esm-spec §4.7: a `{ref}` subsystem is resolved and inlined at load",
        "tests/valid/subsystem_index_set_merge.esm" =>
            "esm-spec §4.7 + §9.7: a `{ref}` subsystem is inlined and its index sets merged",
        "pkg/EarthSciAST.jl/test/fixtures/round_trip/open_op_attrs_match.esm" =>
            "esm-spec §9.6.3 + §9.6.4 rule 5: the `attrs.gamma` match rule fires at load and its match-only registry is dropped",
    )
    # ---- the relaxations ---------------------------------------------------
    _is_empty_container(v) = (v isa AbstractVector || v isa AbstractDict) && isempty(v)

    # `expect_cadence` USED to be relaxed away here, on the theory that the
    # typed IR deliberately did not parse it and that `reconstruct`'s
    # copy-every-field default would otherwise let a rewrite carry an assertion
    # made about the ORIGINAL node onto the rewritten one. Both halves were
    # wrong. The rewrite worry does not arise: the §5.7 partition pass is a
    # COMPILE-TIME classification (CONFORMANCE_SPEC.md §5.7) while the §9.6.3
    # rewrite fixpoint runs at LOAD, so an assertion is only ever checked
    # against the post-rewrite tree — and cadence class is a pure function of
    # the data-dependency DAG, which a semantics-preserving rewrite preserves.
    # Dropping the field across a rewrite would disarm the tripwire in exactly
    # the case it exists for. And the relaxation disarmed THIS gate too: the 41
    # `expect_cadence` occurrences across `tests/valid/cadence/**` were stripped
    # from BOTH sides, so the one corpus tier that pins the §5.7 partition
    # contract round-tripped vacuously. `OpExpr` now carries the field like any
    # other wire field (`OPEXPR_FIELD_TABLE`, types.jl), so it is held to exact
    # fidelity here with everything else.
    _relaxed_key(ks, key, y) =
        # `Domain.independent_variable` defaults to "t"; a periodic trigger's
        # `initial_offset` defaults to 0. Both are omitted on emit.
        (ks == "independent_variable" && key == "domain" && y == "t") ||
        (ks == "initial_offset" && y == 0)

    """
    Apply the three relaxations to a whole document. `key` is the wire key `v`
    itself was reached under, so `_relaxed_key`'s rules can be spelled
    precisely rather than as blanket value matches — `independent_variable` is
    relaxed only under `domain`.
    """
    function relax(v, key::String)
        if v isa AbstractDict
            out = OrderedDict{String,Any}()
            for (k, x) in v
                ks = String(k)
                y = relax(x, ks)
                (_is_empty_container(y) || _relaxed_key(ks, key, y)) && continue
                out[ks] = y
            end
            return out
        elseif v isa AbstractVector
            # An array element is reached under its array's key.
            return Any[relax(x, key) for x in v]
        else
            return v
        end
    end
    relax(doc) = relax(doc, "")

    "Every `/a/b[0]/c` path at which `a` and `b` differ."
    function json_diff(a, b, path = "")
        out = String[]
        if a isa AbstractDict && b isa AbstractDict
            for k in keys(a)
                haskey(b, k) ? append!(out, json_diff(a[k], b[k], "$path/$k")) :
                    push!(out, "$path/$k  DROPPED (value $(first(JSON3.write(a[k]), 120)))")
            end
            for k in keys(b)
                haskey(a, k) || push!(out, "$path/$k  ADDED")
            end
        elseif a isa AbstractVector && b isa AbstractVector
            if length(a) != length(b)
                push!(out, "$path  LENGTH $(length(a)) -> $(length(b))")
            else
                for i in eachindex(a)
                    append!(out, json_diff(a[i], b[i], "$path[$(i - 1)]"))
                end
            end
        elseif a != b
            push!(out, "$path  $(repr(a)) -> $(repr(b))")
        end
        return out
    end

    # ---- the corpus --------------------------------------------------------
    corpus_roots = [
        joinpath(TESTUTILS_REPO_ROOT, "tests", "valid"),
        # The package-local fixtures added for the fields NO shared fixture
        # exercised — a reaction system's hierarchy / events / constraints /
        # analyses, the Metadata extension points, and a `distribution`-valued
        # parameter carrying no `default` at all.
        joinpath(@__DIR__, "fixtures", "round_trip"),
    ]
    fixtures = String[]
    for root in corpus_roots
        isdir(root) || continue
        for (dir, _, files) in walkdir(root), f in files
            endswith(f, ".esm") && push!(fixtures, joinpath(dir, f))
        end
    end
    sort!(fixtures)
    @test !isempty(fixtures)

    exercised = Set{String}()
    for path in fixtures
        rel = replace(relpath(path, TESTUTILS_REPO_ROOT), '\\' => '/')
        original = relax(JSON3.read(read(path, String), OrderedDict{String,Any}))
        emitted = relax(JSON3.read(to_json_compact(load_path(path)),
                                   OrderedDict{String,Any}))
        diff = json_diff(original, emitted)
        if haskey(TRANSFORMED_AT_LOAD, rel)
            push!(exercised, rel)
            # A listed fixture that now round-trips exactly means the list is
            # stale — say so rather than letting the exemption rot in place.
            @test !isempty(diff)
        else
            @test isempty(diff) ||
                  error("$(rel) does not survive save(load(F)):\n  " *
                        join(diff, "\n  "))
        end
    end

    @testset "the exemption list is not stale" begin
        for rel in keys(TRANSFORMED_AT_LOAD)
            @test isfile(joinpath(TESTUTILS_REPO_ROOT, rel))
            @test rel in exercised
        end
    end

    # ---- the specific fields the audit found dropped -----------------------
    # Named individually so a regression reads as the field that broke rather
    # than as one line of a corpus-wide diff.
    @testset "named fields survive the round trip" begin
        function emit_of(rel)
            path = joinpath(TESTUTILS_REPO_ROOT, rel)
            return JSON3.read(to_json_compact(load_path(path)), OrderedDict{String,Any})
        end

        # Model.reference — 26 of 94 fixtures carried one and every one lost it.
        m = emit_of("tests/valid/metadata_minimal.esm")["models"]["SimpleModel"]
        @test haskey(m, "reference")

        # ReactionSystem.reference, and a reaction-system Parameter's
        # `update` / `shape` — `update` is the one that changes computed
        # results: an `update` block is the only channel binding a parameter to
        # a data source (esm-spec §5.4), so dropping it silently turned a
        # data-driven parameter into a constant.
        rs = emit_of("tests/valid/minimal_chemistry.esm")["reaction_systems"]["SimpleOzone"]
        @test haskey(rs, "reference")
        @test haskey(rs["parameters"]["T"], "update")
        @test haskey(rs["parameters"]["T"], "shape")

        # ContinuousEvent.affect_neg / root_find.
        ev = emit_of("tests/valid/events_continuous_affect_neg.esm"
                     )["models"]["BouncingBallSystem"]["continuous_events"][1]
        @test haskey(ev, "affect_neg")
        @test haskey(ev, "root_find")

        # DiscreteEvent.reinitialize.
        de = emit_of("tests/valid/events_discrete_periodic.esm"
                     )["models"]["PharmacokineticModel"]["discrete_events"][1]
        @test haskey(de, "reinitialize")

        # DataSource.reader_options / record_filter / extent.
        ds = emit_of("tests/valid/data_sources_ingest_and_select.esm"
                     )["data_sources"]["EGU_Emis"]
        @test haskey(ds, "reader_options")
        @test haskey(ds, "record_filter")
        @test haskey(ds, "extent")

        # ... and the two DataSource properties no shared fixture exercised:
        # source-level `select`, and `temporal.records_per_sample` (how many
        # records the source returns per QUERY TIME, as against
        # `records_per_file`, which counts records IN one file).
        rean = emit_of("pkg/EarthSciAST.jl/test/fixtures/round_trip/parameter_value_model.esm"
                       )["data_sources"]["Reanalysis"]
        @test length(rean["select"]["axes"]) == 3
        @test rean["temporal"]["records_per_sample"] == 2

        # Model.analyses and ReactionSystem.analyses.
        ta = emit_of("tests/valid/tests_analyses_comprehensive.esm")
        @test haskey(ta["models"]["LogisticGrowth"], "analyses")
        @test haskey(ta["reaction_systems"]["SimpleDecay"], "analyses")

        # ReactionSystem hierarchy: the struct HAD `subsystems`, but nothing
        # populated or emitted it, so a hierarchy flattened to its root at load.
        full = emit_of("pkg/EarthSciAST.jl/test/fixtures/round_trip/reaction_system_full_surface.esm")
        root = full["reaction_systems"]["Troposphere"]
        @test haskey(root, "constraint_equations")
        @test haskey(root, "discrete_events")
        @test haskey(root, "continuous_events")
        @test haskey(root["subsystems"]["Aerosol"]["subsystems"], "Nucleation")

        # Metadata's extension points. `x_esd`'s schema description is
        # normative: core tooling MUST preserve it across parse → emit.
        md = emit_of("pkg/EarthSciAST.jl/test/fixtures/round_trip/metadata_extension_fields.esm")["metadata"]
        @test md["system_class"] == "dae"
        @test md["dae_info"]["algebraic_equation_count"] == 1
        @test md["discretized_from"]["name"] == "ConstrainedSource"
        @test md["x_esd"]["nested"]["arbitrary"] == ["free", "form", 3]

        # Top-level `coupling_roles` — presence of this key is the SOLE
        # positive identifier of the coupling-library file kind (esm-spec
        # §10.9), so dropping it destroyed a library's identity on round trip.
        lib = emit_of("tests/coupling_libraries/full_surface_lib.esm")
        @test EarthSciAST._is_coupling_library_doc(lib)
        @test sort(collect(keys(lib["coupling_roles"]))) == ["Fuel", "Spread"]
        # ... and `CouplingEvent.name`, found by the same sweep.
        @test any(e -> get(e, "type", nothing) == "event" && haskey(e, "name"),
                  lib["coupling"])

        # `ExpressionNode.attrs` — the scheme parameters of an OPEN
        # rewrite-target op (esm-spec §4.2). NO fixture in ANY binding
        # exercised it, which is why nothing caught Julia dropping it: a custom
        # op's entire configuration went missing on load, and the document
        # re-emitted as a bare `godunov_hamiltonian(phi)`.
        oa = emit_of("pkg/EarthSciAST.jl/test/fixtures/round_trip/open_op_attrs.esm")
        rhs = oa["models"]["HamiltonJacobi"]["equations"][1]["rhs"]
        @test rhs["attrs"]["gamma"] == 1.4
        @test rhs["attrs"]["scheme"] == "lax_friedrichs"
        @test rhs["attrs"]["stencil_width"] == 3
        @test rhs["attrs"]["entropy_fix"] === true

        # `ExpressionNode.expect_cadence` — an author assertion on a node's
        # cadence class (CONFORMANCE_SPEC.md §5.7.6 rule 3). The corpus sweep
        # above now holds all 41 occurrences in `tests/valid/cadence/**` to
        # exact fidelity; this pins one by name so a regression reads as the
        # field rather than as one line of a corpus-wide diff.
        # Counted over the emitted BYTES against the SOURCE bytes, rather than
        # at one path: the assertion's whole point is that it sits on every
        # meaningful node, and reading the expected count off the fixture keeps
        # the pin from rotting when a fixture gains a node.
        for rel in ("tests/valid/cadence/pure_pointwise.esm",
                    "tests/valid/cadence/mixed_stencil.esm",
                    "tests/valid/cadence/discrete_remesh_stencil.esm")
            path = joinpath(TESTUTILS_REPO_ROOT, rel)
            n = count("\"expect_cadence\"", read(path, String))
            @test n > 0
            @test count("\"expect_cadence\"", to_json_compact(load_path(path))) == n
        end
    end

    # `esm-schema.json`'s `Parameter` has NO `required` list, so a parameter
    # valued by a `distribution` and carrying no `default` is a conforming
    # document. Julia's field table pinned `default` as required, which made
    # such a file a hard `KeyError` at load — a rejection, not a drop.
    @testset "a distribution-valued parameter needs no `default`" begin
        doc = Dict{String,Any}(
            "esm" => "1.0.0",
            "metadata" => Dict{String,Any}("name" => "DistOnly"),
            "reaction_systems" => Dict{String,Any}("RS" => Dict{String,Any}(
                "species" => Dict{String,Any}(
                    "A" => Dict{String,Any}("units" => "ppb", "default" => 1.0)),
                "parameters" => Dict{String,Any}("k" => Dict{String,Any}(
                    "units" => "s^-1",
                    "distribution" => Dict{String,Any}(
                        "kind" => "normal", "mean" => 1.0, "std" => 0.1))),
                "reactions" => Any[Dict{String,Any}(
                    "id" => "r1",
                    "substrates" => Any[Dict{String,Any}(
                        "species" => "A", "stoichiometry" => 1)],
                    "products" => nothing,
                    "rate" => Dict{String,Any}("op" => "*", "args" => Any["k", "A"]))],
            )),
        )
        @test isempty(validate_schema(doc))
        file = load_document(doc)
        k = only(file.reaction_systems["RS"].parameters)
        @test k.default === nothing
        @test k.distribution.kind == "normal"
        emitted = JSON3.read(to_json_compact(file), OrderedDict{String,Any})
        p = emitted["reaction_systems"]["RS"]["parameters"]["k"]
        @test !haskey(p, "default")
        @test p["distribution"]["mean"] == 1.0
    end
end
