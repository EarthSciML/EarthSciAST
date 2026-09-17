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
            "rate" => ModelVariable(UnknownVariable, default=0.0),
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
            @test errcode(() -> EarthSciAST.load_path(asm)) == "subsystem_ref_is_coupling_library"

            # §4.7 nested subsystem ref targeting a library.
            asmn = joinpath(dir, "asmn.esm")
            write(asmn, JSON3.write(Dict{String,Any}(
                "esm" => "0.8.0",
                "metadata" => Dict{String,Any}("name" => "asmn"),
                "models" => Dict{String,Any}("Parent" => Dict{String,Any}(
                    "variables" => Dict{String,Any}("x" => Dict{String,Any}("type" => "unknown")),
                    "equations" => Any[],
                    "subsystems" => Dict{String,Any}("Sub" => Dict{String,Any}("ref" => "clib.esm")),
                )),
            )))
            @test errcode(() -> EarthSciAST.load_path(asmn)) == "subsystem_ref_is_coupling_library"

            # §9.7.2 template import (component-scoped) targeting a library.
            asm2 = joinpath(dir, "asm2.esm")
            write(asm2, JSON3.write(Dict{String,Any}(
                "esm" => "0.8.0",
                "metadata" => Dict{String,Any}("name" => "asm2"),
                "models" => Dict{String,Any}("M" => Dict{String,Any}(
                    "expression_template_imports" => Any[Dict{String,Any}("ref" => "clib.esm")],
                    "variables" => Dict{String,Any}("x" => Dict{String,Any}("type" => "unknown")),
                    "equations" => Any[],
                )),
            )))
            @test errcode(() -> EarthSciAST.load_path(asm2)) == "template_import_is_coupling_library"
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

# A relative `coupling_import` `ref` names a file relative to the importing
# document (esm-spec §10.10 -> §4.7), so `flatten` with its default `base_path`
# must find ./rothermel_fuel.esm beside assembly_import.esm from a working
# directory that holds no such file. Before the fix the import resolved against
# the working directory and threw `coupling_import_unresolved`.
@testset "coupling_import ref resolves against the importing document (§10.10 -> §4.7)" begin
    corpus = joinpath(TESTUTILS_REPO_ROOT, "tests", "coupling_libraries")
    cd(mktempdir()) do
        @test !isfile("rothermel_fuel.esm")
        imported = flatten(load_path(joinpath(corpus, "assembly_import.esm")))
        inline = flatten(load_path(joinpath(corpus, "assembly_inline.esm")))
        se(f) = [EarthSciAST.serialize_equation(e) for e in f.equations]
        @test se(imported) == se(inline)
        @test sort(collect(keys(imported.parameters))) == sort(collect(keys(inline.parameters)))
    end
    # The document's own base wins over an unrelated keyword, and the authored
    # `ref` round-trips verbatim (§10.10.3).
    file = load_path(joinpath(corpus, "assembly_import.esm"))
    @test flatten(file; base_path=joinpath("does", "not", "exist")) isa EarthSciAST.FlattenedSystem
    @test only(e for e in file.coupling if e isa CouplingImport).ref == "./rothermel_fuel.esm"
    @test occursin("\"./rothermel_fuel.esm\"", EarthSciAST.to_json(file))
end

# A document with no location of its own — built in memory, or parsed from text
# with no `base_path` — leaves `flatten`'s `base_path` in charge, and one given an
# explicit base anchors on it. All five bindings agree on this, so a caller's
# base is never silently replaced by the working directory.
@testset "an in-memory coupling_import document keeps the caller's base (§10.10 -> §4.7)" begin
    corpus = joinpath(TESTUTILS_REPO_ROOT, "tests", "coupling_libraries")
    text = read(joinpath(corpus, "assembly_import.esm"), String)
    doc = EarthSciAST._to_ordered(JSON3.read(text))
    cd(mktempdir()) do
        @test !isfile("rothermel_fuel.esm")
        # No base of its own -> the caller's `base_path` resolves the import.
        @test flatten(load_string(text); base_path=corpus) isa EarthSciAST.FlattenedSystem
        @test flatten(load_document(doc); base_path=corpus) isa EarthSciAST.FlattenedSystem
        # An explicit base of its own -> it wins, with no `base_path` at all.
        @test flatten(load_string(text; base_path=corpus)) isa EarthSciAST.FlattenedSystem
        @test flatten(load_document(doc; base_path=corpus)) isa EarthSciAST.FlattenedSystem
    end
end

# A structurally complete `bind` that points a role at a component lacking a
# referenced variable is reported by `validate` on the SOURCE document, not only
# at flatten, and the finding is re-pointed at the import entry and names the
# import, role and component (esm-spec §10.10.3).
@testset "validate reports a mis-bound coupling_import on the source document (§10.10.3)" begin
    corpus = joinpath(TESTUTILS_REPO_ROOT, "tests", "coupling_libraries")
    path = joinpath(corpus, "import_misbind_downstream.esm")
    result = EarthSciAST.validate(load_path(path))
    attributed = [e for e in result.structural_errors
                  if e.error_type == "unresolved_scoped_ref" &&
                     haskey(e.details, "coupling_import")]
    @test !isempty(attributed)
    found = first(attributed)
    @test found.path == "/coupling/0"
    @test found.details["bound_component"] == "RothermelNoW0"
    @test found.details["role"] == "Spread"
    @test endswith(found.details["reference"], ".w0")
    @test !result.is_valid

    # A document with no recorded base does no file I/O, so it reports nothing
    # about the import rather than resolving the ref against the working dir.
    no_base = EarthSciAST.validate(load_string(read(path, String)))
    @test isempty([e for e in no_base.structural_errors
                   if haskey(e.details, "coupling_import")])
end

@testset "coupling-library refs resolve against roles, not systems" begin
    # A library's from/to prefixes name ROLES, and it declares no models by
    # definition (esm-spec §10.9), so resolving them against the file's systems
    # rejected every well-formed library — including EarthSciModels' own
    # fastjx_superfast.esm and wildlandfire_behavior.esm.
    lib = """
    {
      "esm": "1.1.0",
      "metadata": {"name": "RoleScopedLib"},
      "coupling_roles": {
        "Source": {"description": "provides x"},
        "Sink": {"description": "consumes x"}
      },
      "coupling": [
        {"type": "variable_map", "from": "Source.x", "to": "Sink.x",
         "transform": "param_to_var"}
      ]
    }"""
    ok = EarthSciAST.validate(load_string(lib))
    @test isempty(ok.structural_errors)

    typo = replace(lib, "\"Sink.x\"" => "\"Snik.x\"")
    bad = EarthSciAST.validate(load_string(typo))
    @test length(bad.structural_errors) == 1
    @test bad.structural_errors[1].path == "/coupling/0/to"
    @test occursin("undeclared role 'Snik'", bad.structural_errors[1].message)
end

# esm-spec §10.10: a `coupling_import` ref "resolves by the §4.7 reference
# formats (relative path, absolute path, URL, `${VAR}`), with the same
# per-binding capability rules as a template import" — so the §4.7 env-var
# expansion reaches this ref too, on the same three rules: only the braced form
# with a C-identifier name expands, an unset variable is left literal so the ref
# fails with the ordinary `coupling_import_unresolved`, and an expanded relative
# ref still anchors at the importing document's directory.
@testset "coupling_import ref expands \${VAR} (§10.10 -> §4.7)" begin
    corpus = joinpath(TESTUTILS_REPO_ROOT, "tests", "coupling_libraries")
    text = read(joinpath(corpus, "assembly_import.esm"), String)
    var = "ESM_JL_ENVREF_COUPLING_LIB_DIR"
    mktempdir() do dir
        doc = replace(text, "\"./rothermel_fuel.esm\"" => "\"\${$(var)}/rothermel_fuel.esm\"")
        path = joinpath(dir, "assembly.esm")
        write(path, doc)

        # Unset: the token stays literal and the ref fails unresolved, naming it.
        haskey(ENV, var) && delete!(ENV, var)
        e = try
            flatten(load_path(path))
            nothing
        catch err
            err
        end
        @test e isa EarthSciAST.ExpressionTemplateError
        @test e.code == EarthSciAST.ERROR_CODES.COUPLING_IMPORT_UNRESOLVED
        @test occursin("\${$(var)}", sprint(showerror, e))

        # A bare `$VAR` is never expanded, even with the variable set.
        ENV[var] = corpus
        try
            bare = replace(text, "\"./rothermel_fuel.esm\"" => "\"\$$(var)/rothermel_fuel.esm\"")
            barepath = joinpath(dir, "assembly_bare.esm")
            write(barepath, bare)
            @test_throws EarthSciAST.ExpressionTemplateError flatten(load_path(barepath))

            # Set: the library resolves and the import expands to the inline edges.
            se(f) = [EarthSciAST.serialize_equation(e) for e in f.equations]
            inline = flatten(load_path(joinpath(corpus, "assembly_inline.esm")))
            @test se(flatten(load_path(path))) == se(inline)
        finally
            delete!(ENV, var)
        end
    end
end
