using EarthSciAST
using Test
import JSON3

include("testutils.jl")  # _op/_v/_n/_D builders + TESTUTILS_REPO_ROOT

# Does an ASTExpr tree contain a VarExpr whose name matches `target`?
function _uses_var(expr::EarthSciAST.ASTExpr, target::String)
    if expr isa EarthSciAST.VarExpr
        return expr.name == target
    elseif expr isa EarthSciAST.OpExpr
        return any(a -> _uses_var(a, target), expr.args)
    end
    return false
end

# Mirrors pkg/earthsci-ast-ts/src/coupling-imports.test.ts. Exercises detection,
# expansion, flatten equivalence, multiple instantiation, and every §10.11
# diagnostic code.

# A coupling-library file: roles + role-scoped edges, no models/loaders. Built
# fresh each call so per-test mutations never leak.
lib() = Dict{String,Any}(
    "esm" => "0.8.0",
    "metadata" => Dict{String,Any}("name" => "RothermelFuelCoupling"),
    "coupling_roles" => Dict{String,Any}(
        "Fuel" => Dict{String,Any}("description" => "fuel-property source"),
        "Spread" => Dict{String,Any}("description" => "Rothermel spread model"),
    ),
    "coupling" => Any[
        Dict{String,Any}("type" => "variable_map", "from" => "Fuel.sigma",
                         "to" => "Spread.sigma", "transform" => "param_to_var"),
        Dict{String,Any}("type" => "variable_map", "from" => "Fuel.w_0",
                         "to" => "Spread.w0", "transform" => "param_to_var"),
    ],
)

loadref(ref, base_path) = lib()

# An assembly mounting the two components the library wires. RothermelFireSpread
# carries an equation over its params so the param_to_var flatten is observable.
function assembly(coupling::Vector{CouplingEntry})
    fuel = Model(
        Dict{String,ModelVariable}(
            "sigma" => ModelVariable(ParameterVariable, default=1.0, units="1/m"),
            "w_0" => ModelVariable(ParameterVariable, default=1.0, units="kg/m^2"),
        ),
        Equation[])
    spread = Model(
        Dict{String,ModelVariable}(
            "rate" => ModelVariable(StateVariable, default=0.0),
            "sigma" => ModelVariable(ParameterVariable, default=0.0, units="1/m"),
            "w0" => ModelVariable(ParameterVariable, default=0.0, units="kg/m^2"),
        ),
        [Equation(_D("rate"), _op("+", _v("sigma"), _v("w0")))])
    return EsmFile("0.8.0", Metadata("wildfire");
        models=Dict("FuelModelLookup" => fuel, "RothermelFireSpread" => spread),
        coupling=coupling)
end

# One import entry, wrapped so the vector is typed `Vector{CouplingEntry}`.
imp(bind::AbstractDict; ref::String="lib.esm") =
    CouplingEntry[CouplingImport(ref, bind)]

const BOTH = Dict("Fuel" => "FuelModelLookup", "Spread" => "RothermelFireSpread")

function errcode(f)
    try
        f()
        return "NO_ERROR"
    catch e
        e isa EarthSciAST.ExpressionTemplateError && return e.code
        return "NON_CODE_ERROR: $(typeof(e))"
    end
end

_sc(e) = EarthSciAST.serialize_coupling_entry(e)

@testset "coupling_imports" begin
    @testset "_is_coupling_library_doc" begin
        @test EarthSciAST._is_coupling_library_doc(lib())
        @test !EarthSciAST._is_coupling_library_doc(
            Dict{String,Any}("esm" => "0.8.0", "models" => Dict{String,Any}()))
        @test !EarthSciAST._is_coupling_library_doc(nothing)
    end

    @testset "expand_coupling_imports" begin
        @testset "expands an import into the library edges with roles substituted" begin
            file = assembly(imp(BOTH))
            expanded = expand_coupling_imports(file; load_ref=loadref)
            @test _sc.(expanded) == [
                Dict{String,Any}("type" => "variable_map", "from" => "FuelModelLookup.sigma",
                                 "to" => "RothermelFireSpread.sigma", "transform" => "param_to_var"),
                Dict{String,Any}("type" => "variable_map", "from" => "FuelModelLookup.w_0",
                                 "to" => "RothermelFireSpread.w0", "transform" => "param_to_var"),
            ]
        end

        @testset "leaves a file without coupling_import entries untouched" begin
            file = assembly(CouplingEntry[
                CouplingVariableMap("FuelModelLookup.sigma", "RothermelFireSpread.sigma", "param_to_var"),
            ])
            @test expand_coupling_imports(file) === file.coupling
        end

        @testset "supports multiple instantiation with different binds" begin
            file = assembly(CouplingEntry[
                CouplingImport("lib.esm", BOTH),
                CouplingImport("lib.esm", Dict("Fuel" => "RothermelFireSpread", "Spread" => "FuelModelLookup")),
            ])
            expanded = expand_coupling_imports(file; load_ref=loadref)
            @test length(expanded) == 4
            d3 = _sc(expanded[3])
            @test d3["from"] == "RothermelFireSpread.sigma"
            @test d3["to"] == "FuelModelLookup.sigma"
        end
    end

    @testset "flatten equivalence (esm-spec §10.10.3)" begin
        imported = flatten(assembly(imp(BOTH)); load_ref=loadref)
        inline = flatten(assembly(CouplingEntry[
            CouplingVariableMap("FuelModelLookup.sigma", "RothermelFireSpread.sigma", "param_to_var"),
            CouplingVariableMap("FuelModelLookup.w_0", "RothermelFireSpread.w0", "param_to_var"),
        ]))
        # Same parameters survive (the two Spread params are consumed by param_to_var).
        @test sort(collect(keys(imported.parameters))) == sort(collect(keys(inline.parameters)))
        @test !haskey(imported.parameters, "RothermelFireSpread.sigma")
        @test !haskey(imported.parameters, "RothermelFireSpread.w0")
        # Identical flattened equations.
        se(f) = [EarthSciAST.serialize_equation(e) for e in f.equations]
        @test se(imported) == se(inline)
        # The rate equation now reads the fuel params.
        rate_eq = only(imported.equations)
        @test _uses_var(rate_eq.rhs, "FuelModelLookup.sigma")
        @test _uses_var(rate_eq.rhs, "FuelModelLookup.w_0")
    end

    @testset "diagnostics (esm-spec §10.11)" begin
        @test errcode(() -> expand_coupling_imports(
            assembly(imp(Dict("Fuel" => "FuelModelLookup"))); load_ref=loadref)) ==
            "coupling_import_role_unbound"

        @test errcode(() -> expand_coupling_imports(
            assembly(imp(Dict("Fuel" => "FuelModelLookup", "Spread" => "RothermelFireSpread",
                              "Ghost" => "FuelModelLookup"))); load_ref=loadref)) ==
            "coupling_import_unknown_role"

        @test errcode(() -> expand_coupling_imports(
            assembly(imp(Dict("Fuel" => "FuelModelLookup", "Spread" => "DoesNotExist"))); load_ref=loadref)) ==
            "coupling_import_bind_not_a_component"

        @test errcode(() -> expand_coupling_imports(
            assembly(imp(BOTH));
            load_ref=(r, b) -> Dict{String,Any}("esm" => "0.8.0",
                "metadata" => Dict("name" => "x"), "models" => Dict{String,Any}()))) ==
            "coupling_import_not_library"

        @test errcode(() -> expand_coupling_imports(
            assembly(imp(BOTH));
            load_ref=(r, b) -> merge(lib(), Dict{String,Any}("models" => Dict{String,Any}())))) ==
            "coupling_library_illegal_payload"

        # A declared role referenced by no edge.
        @test errcode(() -> expand_coupling_imports(
            assembly(imp(Dict("Fuel" => "FuelModelLookup", "Spread" => "RothermelFireSpread",
                              "Extra" => "FuelModelLookup")));
            load_ref=(r, b) -> begin
                d = lib()
                d["coupling_roles"]["Extra"] = Dict{String,Any}()
                d
            end)) == "coupling_role_unused"

        # An edge referencing an undeclared role.
        @test errcode(() -> expand_coupling_imports(
            assembly(imp(BOTH));
            load_ref=(r, b) -> begin
                d = lib()
                d["coupling"] = Any[Dict{String,Any}("type" => "variable_map",
                    "from" => "Ghost.sigma", "to" => "Spread.sigma", "transform" => "param_to_var")]
                d
            end)) == "coupling_edge_unknown_role"

        # A nested coupling_import inside a library (v1 forbids layering).
        @test errcode(() -> expand_coupling_imports(
            assembly(imp(BOTH));
            load_ref=(r, b) -> begin
                d = lib()
                push!(d["coupling"], Dict{String,Any}("type" => "coupling_import",
                    "ref" => "other.esm", "bind" => Dict{String,Any}()))
                d
            end)) == "coupling_library_nested_import"

        # Default loader against a non-existent file.
        @test errcode(() -> expand_coupling_imports(
            assembly(imp(BOTH)); base_path=mktempdir())) == "coupling_import_unresolved"
    end

    @testset "subsystem/template refs reject a coupling-library file" begin
        mktempdir() do dir
            clib = joinpath(dir, "clib.esm")
            write(clib, JSON3.write(lib()))

            # §4.7 subsystem ref (top-level model `{ref}`) targeting a library.
            asm = joinpath(dir, "asm.esm")
            write(asm, JSON3.write(Dict{String,Any}(
                "esm" => "0.8.0",
                "metadata" => Dict{String,Any}("name" => "asm"),
                "models" => Dict{String,Any}("Sub" => Dict{String,Any}("ref" => "clib.esm")),
            )))
            @test errcode(() -> EarthSciAST.load(asm)) == "subsystem_ref_is_coupling_library"

            # §4.7 nested subsystem ref targeting a library.
            asmn = joinpath(dir, "asmn.esm")
            write(asmn, JSON3.write(Dict{String,Any}(
                "esm" => "0.8.0",
                "metadata" => Dict{String,Any}("name" => "asmn"),
                "models" => Dict{String,Any}("Parent" => Dict{String,Any}(
                    "variables" => Dict{String,Any}("x" => Dict{String,Any}("type" => "state")),
                    "equations" => Any[],
                    "subsystems" => Dict{String,Any}("Sub" => Dict{String,Any}("ref" => "clib.esm")),
                )),
            )))
            @test errcode(() -> EarthSciAST.load(asmn)) == "subsystem_ref_is_coupling_library"

            # §9.7.2 template import (component-scoped) targeting a library.
            asm2 = joinpath(dir, "asm2.esm")
            write(asm2, JSON3.write(Dict{String,Any}(
                "esm" => "0.8.0",
                "metadata" => Dict{String,Any}("name" => "asm2"),
                "models" => Dict{String,Any}("M" => Dict{String,Any}(
                    "expression_template_imports" => Any[Dict{String,Any}("ref" => "clib.esm")],
                    "variables" => Dict{String,Any}("x" => Dict{String,Any}("type" => "state")),
                    "equations" => Any[],
                )),
            )))
            @test errcode(() -> EarthSciAST.load(asm2)) == "template_import_is_coupling_library"
        end
    end

    @testset "coupling_import round-trips through serialize" begin
        entry = CouplingImport("lib.esm", BOTH; description="fuel↔spread")
        d = _sc(entry)
        @test d["type"] == "coupling_import"
        @test d["ref"] == "lib.esm"
        @test d["bind"]["Fuel"] == "FuelModelLookup"
        @test d["bind"]["Spread"] == "RothermelFireSpread"
        @test d["description"] == "fuel↔spread"
        # Re-coerce yields an equivalent entry.
        back = EarthSciAST.coerce_coupling_entry(d)
        @test back isa CouplingImport
        @test back.ref == entry.ref
        @test back.bind == entry.bind
    end
end
