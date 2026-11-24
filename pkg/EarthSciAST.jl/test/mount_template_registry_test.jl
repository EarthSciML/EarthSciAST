# esm-spec §9.6.4 rules 1 and 7, §10.7: a mounted leaf keeps its template
# references; its definitions join the mounting component's registry in the
# leaf's OWN names, and a body's free names are read in the scope of the
# subsystem that owns the reference. Flatten closes every body (its free names
# become parameters each reference binds in its own scope), and the registry
# merge keeps one entry per distinct definition. Drives
# `tests/conformance/expression_templates/mount_registry_merge/` and
# `mount_shared_definition/` against their goldens, and checks that the native
# run of each document equals the run of its expanded document.

using Test
using JSON3
using OrderedCollections
using EarthSciAST

const _MTR_DIR = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance", "expression_templates")

_mtr(dir, f) = joinpath(_MTR_DIR, dir, f)
_mtr_block(reg) = EarthSciAST.emit_esm_string(
    OrderedDict{String, Any}("operators" => OrderedDict{String, Any}(reg))
)
_mtr_flat(p) = _mtr_block(EarthSciAST.flatten(EarthSciAST.load_path(p)).template_registry)
_mtr_loaded(p) = _mtr_block(EarthSciAST.load_path(p).component_templates["models.Host"])

# du at a fixed state, by variable name.
function _mtr_du(file)
    prob = EarthSciAST.esm_problem(file, (0.0, 1.0); compiler = :native)
    u = copy(prob.u0)
    d = similar(u)
    prob.f!(d, u, prob.p, 0.3)
    return Dict(String(k) => d[v] for (k, v) in prob.var_map)
end

@testset "mounted template registries (esm-spec §9.6.4 rule 1)" begin
    @testset "mount_registry_merge goldens" begin
        d = "mount_registry_merge"
        @test _mtr_flat(_mtr(d, "fixture.esm")) == read(_mtr(d, "flattened_registry.esm"), String)
        @test _mtr_flat(_mtr(d, "inline_form.esm")) == read(_mtr(d, "inline_flattened_registry.esm"), String)
        @test _mtr_loaded(_mtr(d, "fixture.esm")) == read(_mtr(d, "loaded_registry.esm"), String)
        p = _mtr(d, "inline_form.esm")
        emitted = EarthSciAST.emit_esm_string(EarthSciAST.emit_document(JSON3.read(read(p, String)), dirname(p)))
        @test emitted == read(_mtr(d, "inline_emitted.esm"), String)
    end

    @testset "mount_shared_definition: one leaf mounted twice" begin
        d = "mount_shared_definition"
        p = _mtr(d, "fixture.esm")
        @test _mtr_flat(p) == read(_mtr(d, "flattened_registry.esm"), String)
        @test _mtr_loaded(p) == read(_mtr(d, "loaded_registry.esm"), String)
        file = EarthSciAST.load_path(p)
        reg = file.component_templates["models.Host"]
        # One definition per leaf template, in the leaf's own names.
        @test sort!(collect(keys(reg))) == ["Host.rate", "Sub1.rate", "loss", "pull"]
        @test JSON3.read(JSON3.write(reg["Sub1.rate"]["body"]), Dict{String, Any}) ==
            Dict{String, Any}("op" => "*", "args" => ["k", "x"])
        # Each mount's references read its own `k`: Expand substitutes the body
        # into the subsystem, and the native run agrees with the expanded run.
        n = _mtr_du(file)
        @test n == _mtr_du(EarthSciAST.expanded_file(file))
        @test n["Host.Sub1.c"] == -0.25 * 1.0
        @test n["Host.Sub2.c"] == -2.0 * 1.0
        @test n["Host.Sub1.d"] == -0.25 * 0.5 * 0.5
        @test n["Host.Sub2.d"] == -2.0 * 0.5 * 0.5
        @test n["Host.y"] == -2.0
        # A Host template with a free name referenced from Host and from its
        # authored subsystem Inner reads each site's own `g`.
        @test n["Host.z"] == -0.5 * 2.0
        @test n["Host.Inner.w"] == -3.0 * 3.0
    end

    @testset "mount_registry_merge: native run equals the expanded run" begin
        for f in ("fixture.esm", "inline_form.esm")
            file = EarthSciAST.load_path(_mtr("mount_registry_merge", f))
            n = _mtr_du(file)
            @test n == _mtr_du(EarthSciAST.expanded_file(file))
            @test n["Host.Sub.c"] == -(0.25 * 3.0 * 1.0)
        end
    end

    @testset "mount_host_rule: the mounting component's rule fires in its mounts" begin
        # esm-spec §9.6.3: Host's `match` rule `cube` fires on the content of
        # the models Host mounts, at any depth (Sub, Sub's own mount Deep, and
        # Bare, which declares no templates), as on an authored subsystem's.
        d = "mount_host_rule"
        p = _mtr(d, "fixture.esm")
        @test _mtr_loaded(p) == read(_mtr(d, "loaded_registry.esm"), String)
        @test _mtr_flat(p) == read(_mtr(d, "flattened_registry.esm"), String)
        file = EarthSciAST.load_path(p)
        @test EarthSciAST.emit_esm_string(EarthSciAST.serialize_esm_file(EarthSciAST.expanded_file(file))) ==
            read(_mtr(d, "expanded.esm"), String)
        sub = file.models["Host"].subsystems["Sub"]
        @test sub.equations[1].rhs.args[1].op == "apply_operator"
        @test sub.equations[1].rhs.args[1].name == "cube"
        n = _mtr_du(file)
        @test n == _mtr_du(EarthSciAST.expanded_file(file))
        @test n["Host.y"] == -(1.5^3)
        @test n["Host.Sub.c"] == -1.0
        @test n["Host.Sub.d"] == -1.0
        @test n["Host.Sub.e"] == -(0.25 * 2.0^3)
        @test n["Host.Sub.Deep.h"] == -(2 * 0.5^3)
        @test n["Host.Bare.g"] == -(3.0^3)
    end
end
