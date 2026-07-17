# Tests for esm-spec §9.7.10 — scope-directed template injection
# (docs/content/rfcs/scoped-template-injection.md): the assembler- or
# test-chosen discretization for a discretization-agnostic PDE leaf, via
# `expression_template_imports` on a §4.7 subsystem-ref edge (form A), a §10
# coupling entry (form B), or a §6.6/§6.7 test/example (form C). Drives the
# shared conformance fixtures under tests/conformance/expression_templates/.

using Test
using JSON3
using EarthSciAST
using EarthSciAST: serialize_esm_file, ExpressionTemplateError,
    _ephemeral_injected_file

include("testutils.jl")  # TESTUTILS_REPO_ROOT + _normj

@testset "scope-directed template injection (esm-spec §9.7.10)" begin
    conf(parts...) = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                              "expression_templates", parts...)

    _golden(path) = _normj(JSON3.read(read(path, String)))
    _err_code(f) = try
        f(); nothing
    catch e
        e isa ExpressionTemplateError ? e.code : rethrow(e)
    end

    @testset "form A — subsystem-ref injection (§4.7 / §9.7.10)" begin
        # esm-spec §9.6.4 Option B: by default references survive and
        # `serialize_esm_file` is reference-preserving. The `expanded.esm` golden
        # is the Option-A image, so this pins it via `ESS_TEMPLATE_REF_DISABLE=1`.
        f = withenv("ESS_TEMPLATE_REF_DISABLE" => "1") do
            EarthSciAST.load(conf("inject_subsystem_ref", "fixture.esm"))
        end
        # The mounted, agnostic leaf's D(c, wrt: lon) is lowered by the injected
        # rule at the mount; the subsystem resolves to a Model (not a ref).
        runoff = f.models["Assembly"].subsystems["Runoff"]
        @test runoff isa EarthSciAST.Model
        @test runoff.equations[1].rhs.args[2].op == "makearray"
        # Injected library brought its grid into the importing registry.
        @test f.index_sets["lon"].size == 288
        @test f.index_sets["lat"].size == 181
        # Round-trip golden: the resolved+lowered assembly; the injection field
        # is gone (form A does not survive parse → emit).
        @test _normj(serialize_esm_file(f)) ==
              _golden(conf("inject_subsystem_ref", "expanded.esm"))

        # The leaf loads standalone with its D intact (agnostic; unlowered).
        leaf = EarthSciAST.load(conf("inject_subsystem_ref", "leaf.esm"))
        @test leaf.models["Advection"].equations[1].rhs.args[2].op == "D"

        # Negative twin: mounting WITHOUT injection loads cleanly (the D
        # survives — the op namespace is open); the unlowered_operator gate is
        # an evaluation-time concern, not a load error.
        ni = EarthSciAST.load(conf("inject_subsystem_ref", "no_inject.esm"))
        @test ni.models["Assembly"].subsystems["Runoff"] isa EarthSciAST.Model
        @test ni.models["Assembly"].subsystems["Runoff"].equations[1].rhs.args[2].op == "D"
    end

    @testset "form B — coupling-entry injection (§10.8 / §9.7.10)" begin
        # Option B: pin the Option-A `expanded.esm` golden via the disable hatch.
        f = withenv("ESS_TEMPLATE_REF_DISABLE" => "1") do
            EarthSciAST.load(conf("inject_coupling_entry", "fixture.esm"))
        end
        # Advection is discretized by name; its lon-derivative is lowered.
        @test f.models["Advection"].equations[1].rhs.args[2].op == "makearray"
        @test f.index_sets["lon"].size == 288
        # Emit (the 0-D partner) named no key and stays untouched.
        @test f.models["Emit"].equations[1].lhs.op == "D"
        # The injection map is consumed — form B does not survive parse → emit.
        ser = serialize_esm_file(f)
        @test !haskey(ser["coupling"][1], "expression_template_imports")
        @test _normj(ser) == _golden(conf("inject_coupling_entry", "expanded.esm"))

        # Diagnostics.
        @test _err_code(() -> EarthSciAST.load(
            conf("inject_coupling_entry", "neg_target_unknown.esm"))) ==
              "template_inject_target_unknown"
        @test _err_code(() -> EarthSciAST.load(
            conf("inject_coupling_entry", "neg_target_is_loader.esm"))) ==
              "template_inject_target_is_loader"
    end

    @testset "form C — test/example injection (§6.6.6 / §9.7.10)" begin
        f = EarthSciAST.load(conf("inject_test_block", "fixture.esm"))
        adv = f.models["Advection"]
        # The enclosing component round-trips with its D INTACT (form C does not
        # lower it at load) and each test keeps its import field (survives emit).
        @test adv.equations[1].rhs.args[2].op == "D"
        @test length(adv.tests) == 2
        @test all(!isempty(t.expression_template_imports) for t in adv.tests)
        @test _normj(serialize_esm_file(f)) ==
              _golden(conf("inject_test_block", "roundtrip.esm"))

        # One suite, many schemes: each test builds an INDEPENDENT ephemeral
        # instance with its own grid, with the D lowered in that build only —
        # the persisted component is never mutated.
        e1 = _ephemeral_injected_file(f, conf("inject_test_block", "fixture.esm"),
            "Advection", adv.tests[1].expression_template_imports,
            conf("inject_test_block"))
        e2 = _ephemeral_injected_file(f, conf("inject_test_block", "fixture.esm"),
            "Advection", adv.tests[2].expression_template_imports,
            conf("inject_test_block"))
        @test e1.models["Advection"].equations[1].rhs.args[2].op == "makearray"
        @test e2.models["Advection"].equations[1].rhs.args[2].op == "makearray"
        @test e1.index_sets["lon"].size == 288
        @test e2.index_sets["lon"].size == 144
        # The persisted file is untouched by the ephemeral builds.
        @test f.models["Advection"].equations[1].rhs.args[2].op == "D"
    end
end
