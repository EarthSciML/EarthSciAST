# Closed-AST phase-4 benchmarks, Julia native side.
#
# Times the template documents generate_p4.py writes (and generate.py's
# `nearest_tpl_*`): one right-hand-side call under `:native`, its build, and,
# where the workload has one, a hand-written loop and an external library
# (Base `searchsortedfirst`, Interpolations.jl, Dates, GeometryOps for the
# planar overlap) computing the same derivative from the sidecar data. The
# hand-written loops are checked against the template's bits, the external
# libraries by their largest difference, and the template against the
# interpreter when INTERP_CHECK=1.
#
# Usage (an environment with EarthSciAST, JSON3, GeometryOps, GeoInterface and
# Interpolations):
#
#     julia --project=<env> bench/closed_templates/bench_p4.jl <family> [DIR|-] [filter]
#
# Families: search, linear, bilinear, calendar, overlap, nearest, fastjx, size.
# With no DIR (or `-`) the family's documents are generated at their default
# sizes into $CLOSED_TEMPLATES_P4_DIR, else closed_templates_p4 under $TMPDIR
# (nearest: generate.py into $CLOSED_TEMPLATES_DIR, else closed_templates under
# $TMPDIR). A DIR given must already hold them (generate_p4.py --out DIR ...,
# e.g. for larger sizes); otherwise the run stops with the command to write them.
# Output: one tab-separated `ROW` line per measurement, for aggregating medians
# over several processes. Environment: CALLS (calls per sample, default 200),
# INTERP_CHECK (default 0), BUILDS (default 2: the reported setup, problem
# construction plus the first call, is the last build's, after Julia has
# compiled the builder).

using EarthSciAST, JSON3, Statistics, Printf, Dates
import GeometryOps as GO, GeoInterface as GI, Interpolations

const E = EarthSciAST
const FAMILY = isempty(ARGS) ? "search" : ARGS[1]
include(joinpath(@__DIR__, "docs.jl"))
const DIR = let given = length(ARGS) > 1 && ARGS[2] != "-" ? ARGS[2] : nothing
    if FAMILY == "nearest"
        bench_docs(
            "generate.py", given, ["--only", "nearest"]; env = "CLOSED_TEMPLATES_DIR",
            name = "closed_templates", prefix = "nearest_tpl_"
        )
    else
        prefix = FAMILY == "search" ? "search_" : FAMILY * "_"
        bench_docs(
            "generate_p4.py", given, ["--only", FAMILY]; env = "CLOSED_TEMPLATES_P4_DIR",
            name = "closed_templates_p4", prefix = prefix
        )
    end
end
const FILTER = length(ARGS) > 2 ? ARGS[3] : ""
const CALLS = parse(Int, get(ENV, "CALLS", "200"))
const INTERP_CHECK = get(ENV, "INTERP_CHECK", "0") == "1"
const BUILDS = parse(Int, get(ENV, "BUILDS", "2"))
const TB = 1.3
const NOFOLD = E._plan_with(E._compiler_plan(:native); count_fold = false)

row(fields...) = (println(join(("ROW", FAMILY, fields...), '\t')); flush(stdout))

struct Built
    f!::Any
    u0::Vector{Float64}
    p::Any
    names::Vector{String}  # state name per slot
    build_s::Float64       # problem construction
    first_s::Float64       # the first call after it
end

setup_s(b::Built) = b.build_s + b.first_s

# `esm_problem` under a compiler name; a compiler plan (the count rewrite off)
# goes through the internal builder, as bench/interp_bracket does.
function build(path; compiler = :native)
    local f!, u0, p, vm
    dt = ft = 0.0
    for _ in 1:(compiler === :interpreter ? 1 : BUILDS)
        GC.gc()
        t0 = time_ns()
        if compiler isa Symbol
            prob = E.esm_problem(path, (0.0, 1.0); compiler = compiler)
            f!, u0, p, vm = prob.f!, prob.u0, prob.p, prob.var_map
        else
            f!, u0, p, _, vm = E._with_compiler_plan(
                () -> E._build_evaluator(E.load_path(path); compiler = compiler), compiler
            )
        end
        dt = (time_ns() - t0) / 1.0e9
        du = similar(u0)
        t1 = time_ns()
        f!(du, u0, p, 0.0)
        ft = (time_ns() - t1) / 1.0e9
    end
    names = Vector{String}(undef, length(u0))
    for (k, v) in vm
        names[v] = string(k)
    end
    return Built(f!, copy(u0), p, names, dt, ft)
end

dy(b::Built, t) = (du = fill(NaN, length(b.u0)); b.f!(du, b.u0, b.p, t); du)

# Median ns per call of f(i), i the call number (callers move t with it).
function per_call_ns(f)
    f(0)
    ts = Vector{Float64}(undef, 7)
    k = 1
    for r in eachindex(ts)
        t0 = time_ns()
        for _ in 1:CALLS
            f(k)
            k += 1
        end
        ts[r] = (time_ns() - t0) / CALLS
    end
    return median(ts)
end

tof(k) = TB + 1.0e-3 * (k % 1000)

function time_model(b::Built)
    du = similar(b.u0)
    return per_call_ns(k -> b.f!(du, b.u0, b.p, tof(k)))
end

same(a, b) = length(a) == length(b) && all(x === y || (isnan(x) && isnan(y)) for (x, y) in zip(a, b))
maxdiff(a, b) = maximum(abs.(a .- b); init = 0.0)

function oracle(path, b::Built)
    INTERP_CHECK || return "skipped"
    o = build(path; compiler = :interpreter)
    return all(same(dy(b, t), dy(o, t)) for t in (0.0, 0.7, TB, 1800.0)) ? "bit-identical" : "DIFFERS"
end

slotidx(name) = parse(Int, match(r"\[(\d+)\]", name).captures[1])

function sizes(prefix)
    out = String[]
    for f in readdir(DIR)
        m = match(Regex("^" * prefix * "(\\w+?)\\.esm\$"), f)
        m === nothing && continue
        occursin(FILTER, f) || continue
        push!(out, m.captures[1])
    end
    return sort!(out; by = s -> parse(Int, match(r"\d+", s).match))
end

data(stem) = JSON3.read(read(joinpath(DIR, stem * ".data.json"), String))
f64(v) = Float64.(collect(v))

# ---------------------------------------------------------------------------

function count_below(axis, x)
    c = 0
    @inbounds for a in axis
        c += !(a >= x)
    end
    return c
end

function bisect_below(axis, x)
    lo, hi = 0, length(axis)
    @inbounds while lo < hi
        mid = (lo + hi + 1) >>> 1
        if !(axis[mid] >= x)
            lo = mid
        else
            hi = mid - 1
        end
    end
    return lo
end

function run_search()
    for sz in sizes("search_tpl_")
        p(sp) = joinpath(DIR, "search_$(sp)_$(sz).esm")
        d = data("search_$sz")
        axis, c = f64(d.axis), f64(d.c)
        tb, tl, tf = build(p("tpl")), build(p("lin")), build(p("tpl"); compiler = NOFOLD)
        ref = dy(tb, TB)
        idx = slotidx.(tb.names)
        u = tb.u0
        du = similar(u)
        hand(t, how) = for (s, q) in enumerate(idx)
            x = (c[q] + u[s]) + 0.001 * t
            below = how == 0 ? count_below(axis, x) : how == 1 ? bisect_below(axis, x) : searchsortedfirst(axis, x) - 1
            du[s] = Float64(1 + below) - u[s]
        end
        ok = same(dy(tl, TB), ref) && same(dy(tf, TB), ref)
        for how in 0:2
            hand(TB, how)
            ok &= same(du, ref)
        end
        orc = oracle(p("lin"), tl)
        ts = map(time_model, (tb, tl, tf))
        hs = map(how -> per_call_ns(k -> hand(tof(k), how)), (0, 1, 2))
        row(
            sz, "tpl_binary", ts[1], "tpl_linear", ts[2], "tpl_fold", ts[3],
            "hand_linear", hs[1], "hand_binary", hs[2], "searchsortedfirst", hs[3],
            "bits", ok, "oracle", orc, "setup_tpl", setup_s(tb)
        )
    end
    return
end

function hand_linear(table, axis, x)
    n = length(axis)
    x <= axis[1] && return table[1]
    x >= axis[n] && return table[n]
    i = clamp(count(<=(x), axis), 1, n - 1)
    w = (x - axis[i]) / (axis[i + 1] - axis[i])
    return table[i] + w * (table[i + 1] - table[i])
end

clampto(axis, x) = x <= axis[1] ? axis[1] : x >= axis[end] ? axis[end] : x

function hand_bilinear(t, ax, ay, x, y)
    xc, yc = clampto(ax, x), clampto(ay, y)
    i = clamp(count(<=(xc), ax), 1, length(ax) - 1)
    j = clamp(count(<=(yc), ay), 1, length(ay) - 1)
    wx = (xc - ax[i]) / (ax[i + 1] - ax[i])
    wy = (yc - ay[j]) / (ay[j + 1] - ay[j])
    r0 = t[i, j] + wx * (t[i + 1, j] - t[i, j])
    r1 = t[i, j + 1] + wx * (t[i + 1, j + 1] - t[i, j + 1])
    return r0 + wy * (r1 - r0)
end

# The hand-written and Interpolations.jl loops, built behind a function barrier
# so the closures capture concretely typed arrays.
function linear_loops(d, idx, u, du, c)
    axis, tab = f64(d.axis), f64(d.table)
    itp = Interpolations.linear_interpolation(axis, tab; extrapolation_bc = Interpolations.Flat())
    hand = t -> @inbounds for (s, q) in enumerate(idx)
        du[s] = hand_linear(tab, axis, (c[q] + u[s]) + 0.001 * t) - u[s]
    end
    ext = t -> @inbounds for (s, q) in enumerate(idx)
        du[s] = itp((c[q] + u[s]) + 0.001 * t) - u[s]
    end
    return hand, ext
end

function bilinear_loops(d, idx, u, du, c)
    ax, ay, dd = f64(d.axis_x), f64(d.axis_y), f64(d.d)
    M = permutedims(reduce(hcat, [f64(r) for r in d.table]))
    itp = Interpolations.linear_interpolation((ax, ay), M; extrapolation_bc = Interpolations.Flat())
    hand = t -> @inbounds for (s, q) in enumerate(idx)
        du[s] = hand_bilinear(M, ax, ay, (c[q] + u[s]) + 0.001 * t, (dd[q] + u[s]) + 0.001 * t) - u[s]
    end
    ext = t -> @inbounds for (s, q) in enumerate(idx)
        du[s] = itp((c[q] + u[s]) + 0.001 * t, (dd[q] + u[s]) + 0.001 * t) - u[s]
    end
    return hand, ext
end

function run_interp(family)
    for sz in sizes("$(family)_tpl_")
        p(sp) = joinpath(DIR, "$(family)_$(sp)_$(sz).esm")
        d = data("$(family)_$sz")
        tp = build(p("tpl"))
        ref = dy(tp, TB)
        idx = slotidx.(tp.names)
        u = tp.u0
        du = similar(u)
        c = f64(d.c)
        hand, ext = family == "linear" ? linear_loops(d, idx, u, du, c) : bilinear_loops(d, idx, u, du, c)
        hand(TB)
        ok = same(du, ref)
        ext(TB)
        acc = maxdiff(du, ref)
        orc = oracle(p("tpl"), tp)
        b = time_model(tp)
        h = per_call_ns(k -> hand(tof(k)))
        x = per_call_ns(k -> ext(tof(k)))
        row(
            sz, "tpl", b, "hand", h, "Interpolations", x, "maxdiff_Interpolations", acc,
            "bits", ok, "oracle", orc, "setup_tpl", setup_s(tp)
        )
    end
    return
end

# The nine fields, summed in generate_p4.py's order, by Hinnant's civil_from_days.
function hand_calendar(t)
    ft = floor(t)
    secs = Int64(ft)
    d = fld(secs, 86400)
    s = mod(secs, 86400)
    z = d + 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146096), 365)
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    day = doy - div(153 * mp + 2, 5) + 1
    month = mp < 10 ? mp + 3 : mp - 9
    year = yoe + 400 * era + (month <= 2)
    leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 1 : 0
    dayofyr = doy >= 306 ? doy - 305 : doy + 60 + leap
    jd = (Float64(d) + 2440588.0) + ((Float64(s) - 43200.0) + (t - ft)) / 86400.0
    return Float64(year) + month + day + div(s, 3600) + mod(div(s, 60), 60) + mod(s, 60) + dayofyr + jd + leap
end

function dates_calendar(t)
    dt = unix2datetime(floor(t))
    return Float64(year(dt)) + month(dt) + day(dt) + hour(dt) + minute(dt) + second(dt) + dayofyear(dt) +
        datetime2julian(unix2datetime(t)) + isleapyear(dt)
end

function run_calendar()
    for sz in sizes("calendar_tpl_")
        p(sp) = joinpath(DIR, "calendar_$(sp)_$(sz).esm")
        t0 = Float64(data("calendar_$sz").T0)
        tp = build(p("tpl"))
        ref = dy(tp, TB)
        idx = slotidx.(tp.names)
        u = tp.u0
        du = similar(u)
        run(t, g) = for (s, h) in enumerate(idx)
            du[s] = g((t0 + 3600.0 * (h - 1)) + (t + u[s])) - u[s]
        end
        run(TB, hand_calendar)
        okh = same(du, ref)
        run(TB, dates_calendar)
        accd = maxdiff(du, ref)
        orc = oracle(p("tpl"), tp)
        b = time_model(tp)
        h = per_call_ns(k -> run(tof(k), hand_calendar))
        x = per_call_ns(k -> run(tof(k), dates_calendar))
        row(
            sz, "tpl", b, "hand", h, "Dates", x, "bits_hand", okh,
            "maxdiff_Dates", accd, "oracle", orc, "setup_tpl", setup_s(tp)
        )
    end
    return
end

# The planar overlap area by GeometryOps' convex clip.
function go_area(a, b)
    pa = GI.Polygon([GI.LinearRing([(v[1], v[2]) for v in vcat(a, a[1:1])])])
    pb = GI.Polygon([GI.LinearRing([(v[1], v[2]) for v in vcat(b, b[1:1])])])
    res = GO.intersection(GO.ConvexConvexSutherlandHodgman(GO.Planar()), pa, pb; target = GI.PolygonTrait())
    poly = res isa AbstractVector ? (isempty(res) ? nothing : first(res)) : res
    return poly === nothing ? 0.0 : GO.area(poly)
end

function run_overlap()
    for sz in sizes("overlap_planar_tpl_")
        d = data("overlap_$sz")
        ra = [[f64(v) for v in r] for r in d.ring_a]
        rb = [[f64(v) for v in r] for r in d.ring_b]
        for mf in ("planar", "spherical")
            tp = build(joinpath(DIR, "overlap_$(mf)_tpl_$(sz).esm"))
            at = dy(tp, TB)
            orc = length(ra) <= 200 ? oracle(joinpath(DIR, "overlap_$(mf)_tpl_$(sz).esm"), tp) : "skipped"
            ct = time_model(tp)
            n = length(ra)
            fields = Any[mf, sz, "pairs", n, "setup_tpl", setup_s(tp), "call_tpl", ct, "oracle", orc]
            if mf == "planar"
                idx = slotidx.(tp.names)
                areas = [go_area(ra[q], rb[q]) for q in idx]
                g = per_call_ns(k -> go_area(ra[k % n + 1], rb[k % n + 1]))
                append!(fields, ("GeometryOps_per_pair", g, "maxdiff_GO_tpl", maxdiff(areas, at)))
            end
            row(fields...)
        end
    end
    return
end

function const_eq(doc, var)
    m = first(values(doc.models))
    e = only(filter(e -> e.lhs == var, collect(m.equations)))
    return f64(e.rhs.value)
end

function run_nearest()
    for sz in sizes("nearest_tpl_")
        p(sp) = joinpath(DIR, "nearest_$(sp)_$(sz).esm")
        doc = JSON3.read(read(p("tpl"), String))
        px, py, gx, gy = (const_eq(doc, v) for v in ("px", "py", "gx", "gy"))
        tp = build(p("tpl"))
        ref = dy(tp, TB)
        idx = slotidx.(tp.names)
        w = tp.u0
        du = similar(w)
        # The assignment depends only on const data, so the compiler computes
        # it once at build; the hand-written version does the same: a nearest
        # search per point at setup, a gather per call.
        assign = nearest_assign(px, py, gx, gy)
        setup = per_call_ns(_ -> nearest_assign(px, py, gx, gy))
        hand = () -> @inbounds for (s, i) in enumerate(idx)
            du[s] = gx[assign[i]] - w[s]
        end
        hand()
        ok = same(du, ref)
        orc = oracle(p("tpl"), tp)
        b = time_model(tp)
        h = per_call_ns(_ -> hand())
        row(
            sz, "tpl", b, "hand", h, "hand_setup_s", setup / 1.0e9, "bits", ok, "oracle", orc,
            "setup_tpl", setup_s(tp)
        )
    end
    return
end

function nearest_assign(px, py, gx, gy)
    out = Vector{Int}(undef, length(px))
    @inbounds for i in eachindex(px)
        best, bd = 1, (px[i] - gx[1]) * (px[i] - gx[1]) + (py[i] - gy[1]) * (py[i] - gy[1])
        for k in 2:length(gx)
            dx, dyy = px[i] - gx[k], py[i] - gy[k]
            dd = dx * dx + dyy * dyy
            if dd < bd
                best, bd = k, dd
            end
        end
        out[i] = best
    end
    return out
end

function run_fastjx()
    for sz in sizes("fastjx_tpl_")
        tp = build(joinpath(DIR, "fastjx_tpl_$(sz).esm"))
        orc = oracle(joinpath(DIR, "fastjx_tpl_$(sz).esm"), tp)
        row(
            sz, "lookups", data("fastjx_$sz").lookups, "tpl", time_model(tp), "oracle", orc,
            "setup_tpl", setup_s(tp)
        )
    end
    return
end

function run_size()
    for fam in ("searchsorted", "linear", "bilinear", "calendar", "argmin", "overlap_planar", "mixed")
        for sz in sizes("size_$(fam)_tpl_")
            tp = build(joinpath(DIR, "size_$(fam)_tpl_$(sz).esm"))
            row(fam, sz, "setup_tpl", setup_s(tp), "call_tpl", time_model(tp))
        end
    end
    return
end

if FAMILY == "search"
    run_search()
elseif FAMILY in ("linear", "bilinear")
    run_interp(FAMILY)
elseif FAMILY == "calendar"
    run_calendar()
elseif FAMILY == "overlap"
    run_overlap()
elseif FAMILY == "nearest"
    run_nearest()
elseif FAMILY == "fastjx"
    run_fastjx()
elseif FAMILY == "size"
    run_size()
else
    error("unknown family $FAMILY")
end
