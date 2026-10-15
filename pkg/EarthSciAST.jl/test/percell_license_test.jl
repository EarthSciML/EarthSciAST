# "No fallback" as a structural property (esm-libraries-spec §2.5.10).
#
# Every per-cell routine — a resolve and compile per cell at construction, or a
# tree walk per cell on a call — takes a `_PerCellLicense` (compiler.jl), and so
# does every evaluator structure that walks per cell. A license is a value only
# a non-strict plan can make. This file pins the four facts that make that a
# guarantee rather than a convention:
#
#   * no strict plan can make a license, and `_percell_license` raises the
#     route's named refusal there (after its one-cell probe) instead;
#   * every per-cell routine requires a license in its signature (a probe for
#     the single-cell ones), so no call without one can dispatch;
#   * the walking structures cannot be built without one: a kernel section that
#     would walk and holds no license fails to construct, and the walked
#     recurrence sweep is a type parameterized by the license;
#   * no source file outside compiler.jl decides on strictness or makes a
#     license itself, and a native evaluator holds no license anywhere in it
#     while an interpreter evaluator of the same document does.
using Test
using EarthSciAST
include("testutils.jl")

const _LC = EarthSciAST

_lc_native(f) = _LC._with_compiler_plan(f, _LC._compiler_plan(:native))
_lc_interp(f) = _LC._with_compiler_plan(f, _LC._compiler_plan(:interpreter))
# The other strict plans, without needing their packages loaded.
const _LC_STRICT = (_LC._compiler_plan(:native), _LC._plan_all(:xla, true, true),
                    _LC._plan_with(_LC._plan_all(:mtk, true, false);
                                   setup_map_compile_once = true))

function _lc_refusal(f)
    try
        f()
    catch err
        err isa _LC.TreeWalkError || rethrow()
        return err
    end
    return nothing
end

# True when a `_PerCellLicense` is reachable from `x` through fields, closure
# captures, tuples, arrays and dicts. Runtime machinery (tasks, locks, modules,
# types) is not followed.
function _lc_holds_license(x, seen = IdDict{Any,Nothing}(), depth = 0)
    x isa _LC._PerCellLicense && return true
    depth > 200 && return false
    T = typeof(x)
    (isbitstype(T) || x isa Union{Module,Type,String,Symbol,Task,Base.AbstractLock,
                                  Core.MethodInstance, Method, IO, Ptr}) && return false
    if ismutable(x) || x isa AbstractArray
        haskey(seen, x) && return false
        seen[x] = nothing
    end
    if x isa AbstractArray
        (eltype(x) <: Union{Number,Bool,Symbol,String}) && return false
        for i in eachindex(x)
            isassigned(x, i) && _lc_holds_license(x[i], seen, depth + 1) && return true
        end
        return false
    end
    if x isa AbstractDict
        for (k, v) in x
            (_lc_holds_license(k, seen, depth + 1) ||
             _lc_holds_license(v, seen, depth + 1)) && return true
        end
        return false
    end
    for i in 1:nfields(x)
        isdefined(x, i) && _lc_holds_license(getfield(x, i), seen, depth + 1) && return true
    end
    return false
end

@testset "per-cell evaluation needs a license" begin

    @testset "no strict plan can make a license" begin
        for plan in _LC_STRICT
            e = _lc_refusal(() -> _LC._with_compiler_plan(() -> _LC._PerCellLicense(), plan))
            @test e !== nothing && e.code == _LC.ERROR_CODES.COMPILER_REFUSED_RULE
            @test occursin("compiler=:$(plan.name)", e.detail)
        end
        @test _lc_interp(() -> _LC._PerCellLicense()) isa _LC._PerCellLicense
    end

    @testset "a strict plan's license request is the route's named refusal" begin
        probes = Ref(0)
        probe(pr) = (@test pr isa _LC._PerCellProbe; probes[] += 1; :seen)
        e = _lc_refusal(() -> _lc_native(() ->
            _LC._percell_license("M.x", r -> "because $(r)"; probe = probe)))
        @test e.code == _LC.ERROR_CODES.COMPILER_REFUSED_RULE
        @test occursin("compiler=:native refuses 'M.x': because seen", e.detail)
        @test probes[] == 1
        # A probe's own error is the document's, and it is what surfaces.
        bad(_) = throw(_LC.TreeWalkError("E_TREEWALK_CONSTARRAY_OOB", "cell 9"))
        e = _lc_refusal(() -> _lc_native(() ->
            _LC._percell_license("M.x", "never said"; probe = bad)))
        @test e.code == "E_TREEWALK_CONSTARRAY_OOB"
        # Under the interpreter the probe never runs.
        probes[] = 0
        @test _lc_interp(() -> _LC._percell_license("M.x", "no"; probe = probe)) isa
              _LC._PerCellLicense
        @test probes[] == 0
    end

    @testset "every per-cell routine requires a license in its signature" begin
        lic = _LC._PerCellLicense
        access = _LC._PerCellAccess
        # routine => the type its first argument must be within.
        routines = [
            _LC._eval_cellwise           => access,  # resolve + compile one cell
            _LC._resolve_field_ic        => access,  # a field `ic`, one cell
            _LC._faq_diagnostic_cell     => access,  # an array equation's first cell
            _LC._fill_map_percell        => lic,     # setup arrays, every cell
            _LC._walk_init_once!         => lic,     # initialization equations
            _LC._percell_discrete_fill   => lic,     # the discrete materializer
            _LC._seed_expression_percell! => lic,    # `seed_expression_ic!`
            _LC._walk_kernels!           => lic,     # the kernel section's runner
            # The scalar walker: its `nothing` methods are empty, and the
            # section (or `_make_rhs`) holds no license only with nothing to walk.
            _LC._walk_prelude_slots!     => Union{lic,Nothing},
            _LC._walk_scalar_rhs!        => Union{lic,Nothing},
            _LC._compile_faq_percell!    => Union{lic,_LC._OopCells},  # per-cell build
        ]
        for (f, want) in routines
            ms = collect(methods(f))
            @test !isempty(ms)
            for m in ms
                sig = Base.unwrap_unionall(m.sig)
                first_arg = sig.parameters[2]
                @test first_arg !== Any && first_arg <: want
            end
        end
        # The walked recurrence sweep is the license-parameterized type; the
        # draft the emitter reads (`gen === nothing`) has no walk.
        Tsw = _LC._RecurrenceSweep
        @test hasmethod(_LC._walk_recurrence!,
                        Tuple{Tsw{_LC._PerCellLicense,Tuple{}},Vector{Float64},Nothing,
                              Float64,Type{Float64}})
        @test !hasmethod(_LC._walk_recurrence!,
                         Tuple{Tsw{Nothing,Tuple{}},Vector{Float64},Nothing,Float64,
                               Type{Float64}})
    end

    @testset "a kernel section that walks cannot be built without a license" begin
        # A non-strict plan with the emitter off: every kernel stays on the
        # per-cell runner, and the section carries the license for it.
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "bench", "transport_3axis_7cubed.esm")
        file = _LC.load_path(path)
        lax = _LC._plan_with(_LC._compiler_plan(:native); strict = false, codegen = false)
        f_lax = first(_LC._build_evaluator(file; compiler = lax))
        f_nat = first(_LC._build_evaluator(file; compiler = :native))
        sec = getfield(f_lax, :kernel_section)
        @test sec.walk isa _LC._PerCellLicense && !isempty(sec.kernels)
        rebuild(walk) = _LC._KernelSection(sec.cgf, sec.cgtabs, sec.n_emitted, sec.kernels,
            sec.dualf, sec.dualtabs, sec.n_dual_emitted, sec.dual_resid, sec.f64cg,
            sec.tcache, sec.dual_tcache, sec.ntiles, walk)
        @test_throws ArgumentError rebuild(nothing)
        @test rebuild(sec.walk) isa _LC._KernelSection
        nsec = getfield(f_nat, :kernel_section)
        @test typeof(nsec).parameters[end] === Nothing
        @test _lc_holds_license(f_lax)
        @test !_lc_holds_license(f_nat)
    end

    @testset "a native evaluator holds no license; the interpreter's does" begin
        # The discrete-cadence materializer: one compiled fill under native, a
        # per-cell walk at every refill under the interpreter.
        file = _LC.load_path(joinpath(@__DIR__, "fixtures", "discrete_materialize.esm"))
        function build(c)
            dm = _LC.DiscreteMaterializer()
            f! = first(_LC._build_evaluator(file;
                initial_conditions = Dict("c[1]" => 0.0, "c[2]" => 0.0, "c[3]" => 0.0),
                const_arrays = Dict("W" => [1.0 2.0 3.0; 4.0 5.0 6.0]),
                param_arrays = Dict("src" => [0.3, 1.7]), materialize_out = dm,
                compiler = c))
            return (f!, dm)
        end
        @test _lc_holds_license(build(:interpreter))
        @test !_lc_holds_license(build(:native))
    end

    @testset "no route outside compiler.jl decides on strictness or mints a license" begin
        src = joinpath(pkgdir(EarthSciAST), "src")
        offenders = String[]
        for (dir, _, files) in walkdir(src), f in files
            endswith(f, ".jl") || continue
            path = joinpath(dir, f)
            path == joinpath(src, "compiler.jl") && continue
            for (n, line) in enumerate(eachline(path))
                code = first(split(line, '#'; limit = 2))
                (occursin("_compiler_is_strict", code) || occursin(".strict", code) ||
                 occursin("_PerCellLicense()", code)) &&
                    push!(offenders, "$(relpath(path, src)):$(n)")
            end
        end
        # `.strict` also names a table lookup's strictness (`_Interp*Spec`), which
        # is a property of the document, not of the compiler.
        filter!(o -> !any(occursin(f, o) for f in ("acc_merge.jl", "xcse.jl",
                                                   "registered_functions.jl")), offenders)
        @test isempty(offenders)
    end
end
