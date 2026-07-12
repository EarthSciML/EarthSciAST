using Test
using EarthSciAST
import OrdinaryDiffEqTsit5: Tsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT, _require_fixture

const ESM_RR = EarthSciAST

# Does an ASTExpr tree reference the (scoped) variable `target`?
_rr_uses_var(expr::EarthSciAST.VarExpr, target::String) = expr.name == target
_rr_uses_var(expr::EarthSciAST.OpExpr, target::String) =
    any(a -> _rr_uses_var(a, target), expr.args)
_rr_uses_var(::EarthSciAST.ASTExpr, ::String) = false

# Mounting an EXTERNAL reaction-system file by reference (esm-spec §4.7).
#
# A top-level `reaction_systems` entry may be a `{ref}` stub — the reaction-system
# analogue of a top-level model `{ref}` stub (schema: each block's entry is
# `oneOf [component, {ref}]`). The stub is inlined at load, before the typed
# pipeline, by `_inline_toplevel_reaction_system_refs!`, so after `load` the
# in-memory form is identical to a file with the reaction system inlined.
@testset "Top-level reaction_system {ref} import (esm-spec §4.7)" begin

    # The persistent single-reaction leaf: system "Chem", A -> B at rate k*A.
    chem_leaf = joinpath(@__DIR__, "fixtures", "reaction_ref", "chem_leaf.esm")

    @testset "ref-assembly loads and mounts the reaction system by name" begin
        @test _require_fixture(chem_leaf)
        tmp = mktempdir()
        try
            cp(chem_leaf, joinpath(tmp, "chem_leaf.esm"))
            refasm = joinpath(tmp, "assembly_ref.esm")
            write(refasm, """{
                "esm": "0.8.0",
                "metadata": {"name": "assembly_ref", "authors": ["Test"]},
                "reaction_systems": {"Chem": {"ref": "./chem_leaf.esm"}}
            }""")
            # No "no models block" error — the ref resolves to a reaction system.
            loaded = ESM_RR.load(refasm)
            @test haskey(loaded.reaction_systems, "Chem")
            rs = loaded.reaction_systems["Chem"]
            @test rs isa ESM_RR.ReactionSystem
            @test Set(s.name for s in rs.species) == Set(["A", "B"])
            @test length(rs.reactions) == 1
        finally
            rm(tmp, recursive=true, force=true)
        end
    end

    @testset "mounted-by-ref flattens & simulates identically to inlined" begin
        if _require_fixture(chem_leaf)
            tmp = mktempdir()
            try
                cp(chem_leaf, joinpath(tmp, "chem_leaf.esm"))
                refasm = joinpath(tmp, "assembly_ref.esm")
                write(refasm, """{
                    "esm": "0.8.0",
                    "metadata": {"name": "assembly_ref", "authors": ["Test"]},
                    "reaction_systems": {"Chem": {"ref": "./chem_leaf.esm"}}
                }""")

                # The inlined baseline: chem_leaf.esm IS a valid assembly whose
                # `reaction_systems` block holds "Chem" inline.
                inl = ESM_RR.load(chem_leaf)
                ref = ESM_RR.load(refasm)

                flat_inl = ESM_RR.flatten(inl)
                flat_ref = ESM_RR.flatten(ref)
                @test sort(collect(keys(flat_ref.state_variables))) ==
                      sort(collect(keys(flat_inl.state_variables)))
                @test sort(collect(keys(flat_ref.parameters))) ==
                      sort(collect(keys(flat_inl.parameters)))
                @test length(flat_ref.equations) == length(flat_inl.equations)
                @test haskey(flat_ref.state_variables, "Chem.A")
                @test haskey(flat_ref.state_variables, "Chem.B")

                # Simulate both; the by-ref trajectories are bit-identical to the
                # inlined ones (same spliced-in reaction system, same solver).
                tspan = (0.0, 10.0)
                r_inl = ESM_RR.simulate(chem_leaf, tspan; alg=Tsit5(), saveat=1.0)
                r_ref = ESM_RR.simulate(refasm, tspan; alg=Tsit5(), saveat=1.0)
                @test r_ref.success && r_inl.success
                @test r_ref["Chem.A"] == r_inl["Chem.A"]   # bit-close (identical)
                @test r_ref["Chem.B"] == r_inl["Chem.B"]

                # And they match the analytic solution A(t)=exp(-k t), k=0.3.
                @test isapprox(r_ref["Chem.A"][end], exp(-0.3 * 10.0); rtol=1e-5)
                @test isapprox(r_ref["Chem.B"][end], 1 - exp(-0.3 * 10.0); rtol=1e-5)
            finally
                rm(tmp, recursive=true, force=true)
            end
        end
    end

    @testset "mounted reaction system is referenceable in coupling by its key" begin
        if _require_fixture(chem_leaf)
            tmp = mktempdir()
            try
                cp(chem_leaf, joinpath(tmp, "chem_leaf.esm"))
                # A second model with its own D(A), composed onto the mounted
                # reaction system's A via operator_compose that references the
                # mounted system by its assembly key "Chem" and translates
                # Extra.A onto Chem.A (mirrors the flatten operator_compose test).
                asm = joinpath(tmp, "coupled.esm")
                write(asm, """{
                    "esm": "0.8.0",
                    "metadata": {"name": "coupled", "authors": ["Test"]},
                    "models": {"Extra": {
                        "variables": {
                            "A": {"type": "state", "units": "mol/m^3", "default": 1.0},
                            "j": {"type": "parameter", "units": "1/s", "default": 0.05}
                        },
                        "equations": [{"lhs": {"op": "D", "args": ["A"], "wrt": "t"},
                                       "rhs": {"op": "*", "args": [{"op": "-", "args": ["j"]}, "A"]}}]
                    }},
                    "reaction_systems": {"Chem": {"ref": "./chem_leaf.esm"}},
                    "coupling": [{"type": "operator_compose", "systems": ["Chem", "Extra"],
                                  "translate": {"Extra.A": "Chem.A"}}]
                }""")
                loaded = ESM_RR.load(asm)
                @test haskey(loaded.reaction_systems, "Chem")
                flat = ESM_RR.flatten(loaded)
                @test haskey(flat.state_variables, "Chem.A")
                @test haskey(flat.state_variables, "Chem.B")
                # The compose keyed on the mounted-by-ref system "Chem" is live:
                # some merged equation's RHS references BOTH the reaction rate
                # constant Chem.k and the Extra model's parameter Extra.j
                # (canonical dep name is compose-order dependent, so match on the
                # merged content rather than the surviving LHS name).
                merged = findfirst(
                    e -> _rr_uses_var(e.rhs, "Chem.k") && _rr_uses_var(e.rhs, "Extra.j"),
                    flat.equations)
                @test merged !== nothing
            finally
                rm(tmp, recursive=true, force=true)
            end
        end
    end

    @testset "multi-reaction-system file needs a `reaction_system` selector" begin
        tmp = mktempdir()
        try
            write(joinpath(tmp, "two.esm"), """{
                "esm": "0.8.0",
                "metadata": {"name": "two", "authors": ["Test"]},
                "reaction_systems": {
                    "X": {"species": {"A": {"default": 1.0}},
                          "parameters": {"k": {"default": 0.1}},
                          "reactions": [{"id": "r",
                              "substrates": [{"stoichiometry": 1, "species": "A"}],
                              "products": null, "rate": "k"}]},
                    "Y": {"species": {"B": {"default": 1.0}},
                          "parameters": {"k": {"default": 0.1}},
                          "reactions": [{"id": "r",
                              "substrates": [{"stoichiometry": 1, "species": "B"}],
                              "products": null, "rate": "k"}]}
                }
            }""")
            main_path = joinpath(tmp, "main.esm")
            # No selector over a 2-reaction-system file is an error.
            write(main_path, """{
                "esm": "0.8.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "reaction_systems": {"Sel": {"ref": "./two.esm"}}
            }""")
            @test_throws ESM_RR.SubsystemRefError ESM_RR.load(main_path)
            # `reaction_system` selects one.
            write(main_path, """{
                "esm": "0.8.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "reaction_systems": {"Sel": {"ref": "./two.esm", "reaction_system": "Y"}}
            }""")
            loaded = ESM_RR.load(main_path)
            @test any(s -> s.name == "B", loaded.reaction_systems["Sel"].species)
            @test !any(s -> s.name == "A", loaded.reaction_systems["Sel"].species)
            # A selector naming a missing reaction system errors.
            write(main_path, """{
                "esm": "0.8.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "reaction_systems": {"Sel": {"ref": "./two.esm", "reaction_system": "Z"}}
            }""")
            @test_throws ESM_RR.SubsystemRefError ESM_RR.load(main_path)
        finally
            rm(tmp, recursive=true, force=true)
        end
    end

    @testset "reaction_system ref to a file with no reaction_systems block errors" begin
        tmp = mktempdir()
        try
            write(joinpath(tmp, "modelonly.esm"), """{
                "esm": "0.8.0",
                "metadata": {"name": "modelonly", "authors": ["Test"]},
                "models": {"M": {"variables": {"u": {"type": "state", "default": 1.0}},
                                 "equations": []}}
            }""")
            main_path = joinpath(tmp, "main.esm")
            write(main_path, """{
                "esm": "0.8.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "reaction_systems": {"Chem": {"ref": "./modelonly.esm"}}
            }""")
            @test_throws ESM_RR.SubsystemRefError ESM_RR.load(main_path)
        finally
            rm(tmp, recursive=true, force=true)
        end
    end

    @testset "circular top-level reaction_system ref is detected" begin
        tmp = mktempdir()
        try
            write(joinpath(tmp, "a.esm"), """{
                "esm": "0.8.0",
                "metadata": {"name": "a", "authors": ["Test"]},
                "reaction_systems": {"B": {"ref": "./b.esm"}}
            }""")
            write(joinpath(tmp, "b.esm"), """{
                "esm": "0.8.0",
                "metadata": {"name": "b", "authors": ["Test"]},
                "reaction_systems": {"A": {"ref": "./a.esm"}}
            }""")
            @test_throws ESM_RR.SubsystemRefError ESM_RR.load(joinpath(tmp, "a.esm"))
        finally
            rm(tmp, recursive=true, force=true)
        end
    end

    # Smoke: the real SuperFast component (v0.8.0, no coupletype) mounts by ref.
    # Lives in the sibling EarthSciModels repo; skipped cleanly when absent.
    @testset "smoke: SuperFast mounts by ref" begin
        superfast = normpath(joinpath(TESTUTILS_REPO_ROOT, "..", "EarthSciModels",
                                      "components", "gaschem", "superfast.esm"))
        if _require_fixture(superfast)
            tmp = mktempdir()
            try
                asm = joinpath(tmp, "sf_assembly.esm")
                write(asm, """{
                    "esm": "0.8.0",
                    "metadata": {"name": "sf_assembly", "authors": ["Test"]},
                    "reaction_systems": {"SuperFast": {"ref": "$(superfast)"}}
                }""")
                loaded = ESM_RR.load(asm)
                @test haskey(loaded.reaction_systems, "SuperFast")
                @test loaded.reaction_systems["SuperFast"] isa ESM_RR.ReactionSystem
                @test length(loaded.reaction_systems["SuperFast"].species) == 15
            finally
                rm(tmp, recursive=true, force=true)
            end
        end
    end
end
