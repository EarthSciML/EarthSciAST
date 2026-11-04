# providers_from_document over a time-varying esm source (EarthSciIO
# spec/esm-sources.md): esm URL templates, a bound custom substitution, a
# mirror, and a calendar-month cadence. Mirrors the Python
# tests/test_esio_document_cadence.py.

using Test
using Dates
using EarthSciAST
using EarthSciIO
import EarthSciIO: NCDatasets

const _ESIO_HAS_ESM = isdefined(EarthSciIO, :provider_from_esm)

function _cadence_doc(dir)
    mirror = joinpath(dir, "mirror")
    mkpath(mirror)
    for m in 1:3
        NCDatasets.NCDataset(joinpath(mirror, "nei_agr_0$m.ncf"), "c") do ds
            NCDatasets.defDim(ds, "ROW", 2)
            NCDatasets.defDim(ds, "TSTEP", Inf)
            v = NCDatasets.defVar(ds, "NOX", Float32, ("ROW", "TSTEP"))
            v[:, 1] = Float32[m * 10, m * 10 + 1]
        end
    end
    return Dict{String, Any}(
        "esm" => "1.0.0",
        "data_sources" => Dict{String, Any}(
            "NEI" => Dict{String, Any}(
                "kind" => "grid",
                "source" => Dict{String, Any}(
                    "url_template" => "file://$dir/primary/nei_{sector}_{date:%m}.ncf",
                    "mirrors" => ["file://$mirror/nei_{sector}_{date:%m}.ncf"],
                ),
                "temporal" => Dict{String, Any}(
                    "start" => "2016-01-01T00:00:00Z", "end" => "2016-12-31T23:59:59Z",
                    "file_period" => "P1M", "frequency" => "P1M",
                    "records_per_file" => 1, "time_variable" => "TSTEP",
                ),
                "metadata" => Dict{String, Any}("esio_format" => "netcdf"),
            )
        ),
        "models" => Dict{String, Any}(
            "Emis" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "nox" => Dict{String, Any}(
                        "type" => "parameter", "units" => "mol/s", "shape" => ["row"],
                        "update" => Dict{String, Any}(
                            "kind" => "data", "source" => "NEI",
                            "from" => Dict{String, Any}(
                                "file_variable" => "NOX", "unit_conversion" => 2.0
                            ),
                        ),
                    )
                )
            )
        ),
    )
end

u(y, m, d = 1, h = 0) = datetime2unix(DateTime(y, m, d, h))
const _SECTOR = Dict("NEI" => Dict("sector" => "agr"))

@testset "providers_from_document — a monthly source with a bound sector" begin
    if !_ESIO_HAS_ESM
        @info "skipped: this EarthSciIO predates provider_from_esm"
    else
        mktempdir() do dir
            doc = _cadence_doc(dir)
            window = (u(2016, 1), u(2016, 4))
            provs = providers_from_document(
                doc; cache_root = joinpath(dir, "cache"),
                substitutions = _SECTOR, window = window
            )
            p = provs["Emis.nox"]
            @test !EarthSciAST.provider_is_const(p)
            # No domain origin: model time 0 is the window start. Calendar
            # months, not a mean month of 30.436875 days, on the model clock.
            t0 = u(2016, 1)
            @test EarthSciAST.provider_refresh_times(p) ==
                [0.0, u(2016, 2) - t0, u(2016, 3) - t0]
            # the primary location is missing: each month comes from its mirror,
            # converted by the declared unit_conversion
            @test vec(EarthSciAST.provider_sample(p, u(2016, 2, 29, 23) - t0)) == [40.0, 42.0]
            @test vec(EarthSciAST.provider_sample(p, u(2016, 3) - t0)) == [60.0, 62.0]

            # an unbound custom placeholder is EarthSciIO's refusal
            err = try
                providers_from_document(doc; cache_root = joinpath(dir, "cache2"), window = window)
                nothing
            catch e
                e
            end
            @test err isa EarthSciIO.EsmSourceError
            @test occursin("esm_template_unbound", sprint(showerror, err))

            # two records: set in the document, restated (not overridden) at run time
            doc["models"]["Emis"]["variables"]["nox"]["update"]["from"]["records_per_sample"] = 2
            two = providers_from_document(
                doc; cache_root = joinpath(dir, "cache3"),
                substitutions = _SECTOR, window = window,
                records_per_sample = Dict("Emis.nox" => 2)
            )
            got = EarthSciAST.provider_sample(two["Emis.nox"], u(2016, 2, 15) - t0)
            # the record axis first, in the file's dimension order
            @test got == [40.0 42.0; 60.0 62.0]
        end
    end
end

# The time origin of every provider (esm-spec §2.2.7), first match wins:
# reference_time, start, the window start, the POSIX epoch.
@testset "providers_from_document — the model clock's origin" begin
    if _ESIO_HAS_ESM
        mktempdir() do dir
            base = _cadence_doc(dir)
            window = (u(2016, 1), u(2016, 4))
            build(doc; kw...) = providers_from_document(
                doc; cache_root = joinpath(dir, "cache"), substitutions = _SECTOR, kw...
            )["Emis.nox"]
            with_temporal(t) = merge(base, Dict{String, Any}("domain" => Dict{String, Any}("temporal" => t)))

            # reference_time wins over start and the window
            p = build(
                with_temporal(
                    Dict{String, Any}(
                        "reference_time" => "2016-02-01T00:00:00Z",
                        "start" => "2016-01-01T00:00:00Z"
                    )
                ); window = window
            )
            @test p.origin == u(2016, 2)
            @test EarthSciAST.provider_refresh_times(p)[2] == 0.0
            @test vec(EarthSciAST.provider_sample(p, 0.0)) == [40.0, 42.0]
            @test vec(EarthSciAST.provider_sample(p, 86400.0 * 29)) == [60.0, 62.0]

            # an empty reference_time is skipped: start applies (with an offset)
            p = build(
                with_temporal(
                    Dict{String, Any}(
                        "reference_time" => "", "start" => "2016-03-01T01:00:00+01:00"
                    )
                ); window = window
            )
            @test p.origin == u(2016, 3)
            @test vec(EarthSciAST.provider_sample(p, 0.0)) == [60.0, 62.0]

            # a present, unreadable one is the clock accessor's error
            err = try
                build(with_temporal(Dict{String, Any}("reference_time" => "Jan 2016")); window = window)
                nothing
            catch e
                e
            end
            @test err isa EarthSciAST.ExpressionTemplateError
            @test occursin("/domain/temporal/reference_time", sprint(showerror, err))

            # no domain origin: the window start, here given as DateTimes
            p = build(base; window = (DateTime(2016, 2, 1), DateTime(2016, 4, 1)))
            @test p.origin == u(2016, 2)
            @test vec(EarthSciAST.provider_sample(p, 0.0)) == [40.0, 42.0]

            # no origin and no window: the POSIX epoch, bounded by temporal.end
            p = build(base)
            @test p.origin == 0.0
            rt = EarthSciAST.provider_refresh_times(p)
            @test length(rt) == 12 && rt[1] == u(2016, 1) && rt[3] == u(2016, 3)
            @test vec(EarthSciAST.provider_sample(p, u(2016, 2, 3))) == [40.0, 42.0]
        end
    end
end

@testset "providers_from_document — the default window from solver.time_span" begin
    if _ESIO_HAS_ESM
        mktempdir() do dir
            doc = merge(
                _cadence_doc(dir), Dict{String, Any}(
                    "domain" => Dict{String, Any}(
                        "temporal" => Dict{String, Any}("start" => "2016-01-01T00:00:00Z")
                    ),
                    "solver" => Dict{String, Any}(
                        "time_span" => Dict{String, Any}(
                            "start" => 86400.0 * 31, "end" => "2016-03-01T00:00:00Z"
                        )
                    ),
                )
            )
            p = providers_from_document(
                doc; cache_root = joinpath(dir, "cache"), substitutions = _SECTOR
            )["Emis.nox"]
            @test p.origin == u(2016, 1)
            # the window [Feb 1, Mar 1) holds the February anchor alone
            @test EarthSciAST.provider_refresh_times(p) == [u(2016, 2) - u(2016, 1)]
            # an explicit window still wins
            p = providers_from_document(
                doc; cache_root = joinpath(dir, "cache"), substitutions = _SECTOR,
                window = (u(2016, 1), u(2016, 4))
            )["Emis.nox"]
            @test length(EarthSciAST.provider_refresh_times(p)) == 3
        end
    end
end

@testset "providers_from_document — window forms" begin
    if _ESIO_HAS_ESM
        mktempdir() do dir
            doc = _cadence_doc(dir)
            build(window) = providers_from_document(
                doc; cache_root = joinpath(dir, "cache"), substitutions = _SECTOR,
                window = window
            )["Emis.nox"]
            want = [0.0, u(2016, 2) - u(2016, 1), u(2016, 3) - u(2016, 1)]
            for w in (
                    (u(2016, 1), u(2016, 4)), (DateTime(2016, 1), DateTime(2016, 4)),
                    (DateTime(2016, 1), u(2016, 4)), (Int(u(2016, 1)), Int(u(2016, 4))),
                )
                @test EarthSciAST.provider_refresh_times(build(w)) == want
            end
            for bad in (
                    ("2016-01-01", u(2016, 4)), (u(2016, 1), true), (u(2016, 1), NaN),
                    (u(2016, 1),), (u(2016, 1), u(2016, 2), u(2016, 3)), u(2016, 1),
                )
                @test_throws ArgumentError build(bad)
            end
        end
    end
end

@testset "providers_from_document — url_overrides and a missing url_template" begin
    if _ESIO_HAS_ESM
        mktempdir() do dir
            doc = _cadence_doc(dir)
            window = (u(2016, 1), u(2016, 4))
            err = try
                providers_from_document(
                    doc; cache_root = joinpath(dir, "cache"), substitutions = _SECTOR,
                    window = window, url_overrides = Dict("NEI" => "")
                )
                nothing
            catch e
                e
            end
            @test err isa EarthSciAST.RefreshError
            @test occursin("url_overrides[\"NEI\"] is empty", sprint(showerror, err))

            # an override is honoured: here it points at the mirror directly
            p = providers_from_document(
                doc; cache_root = joinpath(dir, "cache"), substitutions = _SECTOR,
                window = window,
                url_overrides = Dict("NEI" => "file://$dir/mirror/nei_{sector}_{date:%m}.ncf")
            )["Emis.nox"]
            @test vec(EarthSciAST.provider_sample(p, 0.0)) == [20.0, 22.0]

            # no url_template and no override: EarthSciIO's own refusal
            delete!(doc["data_sources"]["NEI"]["source"], "url_template")
            err = try
                providers_from_document(
                    doc; cache_root = joinpath(dir, "cache"), substitutions = _SECTOR,
                    window = window
                )
                nothing
            catch e
                e
            end
            @test err isa EarthSciIO.EsmSourceError
            @test occursin("url_template", sprint(showerror, err))
        end
    end
end

# A monthly netCDF with a 2-D field per record, (ROW = 3) x (LAY = 2) natively,
# plus two 1-D columns X / Y whose March X has a non-finite row.
function _grid_doc(dir; ds_extra = Dict{String, Any}(), from_extra = Dict{String, Any}(), table = false)
    for m in 1:3
        NCDatasets.NCDataset(joinpath(dir, "g_0$m.ncf"), "c") do ds
            NCDatasets.defDim(ds, "LAY", 2)
            NCDatasets.defDim(ds, "ROW", 3)
            NCDatasets.defDim(ds, "TSTEP", Inf)
            v = NCDatasets.defVar(ds, "F", Float64, ("LAY", "ROW", "TSTEP"))
            v[:, :, 1] = [100m + 10l + r for l in 1:2, r in 1:3]
            x = NCDatasets.defVar(ds, "X", Float64, ("ROW", "TSTEP"))
            x[:, 1] = [m, m == 3 ? NaN : 10m, 100m]
            y = NCDatasets.defVar(ds, "Y", Float64, ("ROW", "TSTEP"))
            y[:, 1] = [-m, -10m, -100m]
        end
    end
    ds = merge(
        Dict{String, Any}(
            "kind" => "grid",
            "source" => Dict{String, Any}("url_template" => "file://$dir/g_{date:%m}.ncf"),
            "temporal" => Dict{String, Any}(
                "start" => "2016-01-01T00:00:00Z", "end" => "2016-04-01T00:00:00Z",
                "file_period" => "P1M", "frequency" => "P1M",
                "records_per_file" => 1, "time_variable" => "TSTEP",
            ),
            "metadata" => Dict{String, Any}("esio_format" => "netcdf"),
        ), ds_extra
    )
    par(fv; extra = Dict{String, Any}()) = Dict{String, Any}(
        "type" => "parameter", "units" => "1",
        "update" => Dict{String, Any}(
            "kind" => "data", "source" => "G",
            "from" => merge(Dict{String, Any}("file_variable" => fv), extra),
        ),
    )
    vars = table ? Dict{String, Any}("x" => par("X"), "y" => par("Y")) :
        Dict{String, Any}("f" => par("F"; extra = from_extra))
    return Dict{String, Any}(
        "esm" => "1.0.0",
        "domain" => Dict{String, Any}(
            "temporal" => Dict{String, Any}("start" => "2016-01-01T00:00:00Z")
        ),
        "data_sources" => Dict{String, Any}("G" => ds),
        "models" => Dict{String, Any}("M" => Dict{String, Any}("variables" => vars)),
    )
end

@testset "providers_from_document — a record table follows time" begin
    if _ESIO_HAS_ESM
        mktempdir() do dir
            doc = _grid_doc(
                dir; table = true, ds_extra = Dict{String, Any}(
                    "record_filter" => Dict{String, Any}("require_finite" => ["X"])
                )
            )
            window = (u(2016, 1), u(2016, 4))
            provs = providers_from_document(doc; cache_root = joinpath(dir, "cache"), window = window)
            x, y = provs["M.x"], provs["M.y"]
            @test x.table === y.table
            @test !EarthSciAST.provider_is_const(x)
            mar = u(2016, 3) - u(2016, 1)
            @test EarthSciAST.provider_sample(x, 0.0) == [1.0, 10.0, 100.0]
            @test EarthSciAST.provider_sample(y, 0.0) == [-1.0, -10.0, -100.0]
            # March drops its non-finite row from BOTH columns, at a later t
            @test EarthSciAST.provider_sample(x, mar + 3600) == [3.0, 300.0]
            @test EarthSciAST.provider_sample(y, mar + 3600) == [-3.0, -300.0]
            @test x.table.anchor == u(2016, 3)
            # back to February: the decode follows the anchor, both ways
            @test EarthSciAST.provider_sample(y, mar - 1) == [-2.0, -20.0, -200.0]
            @test EarthSciAST.provider_sample(x, mar - 1) == [2.0, 20.0, 200.0]

            err = try
                providers_from_document(
                    doc; cache_root = joinpath(dir, "cache"), window = window,
                    records_per_sample = Dict("M.x" => 2)
                )
                nothing
            catch e
                e
            end
            @test err isa EarthSciAST.RefreshError
            @test occursin("record table", sprint(showerror, err))
        end
    end
end

@testset "providers_from_document — select on a time-varying source" begin
    if _ESIO_HAS_ESM
        mktempdir() do dir
            window = (u(2016, 1), u(2016, 4))
            feb = u(2016, 2) - u(2016, 1)
            fixed = Dict{String, Any}(
                "select" => Dict{String, Any}("axes" => Any["all", Dict("fixed" => 1)])
            )
            whole = providers_from_document(
                _grid_doc(dir); cache_root = joinpath(dir, "c0"), window = window
            )["M.f"]
            rec = EarthSciAST.provider_sample(whole, feb)
            # the native per-record axes, in the file's dimension order
            @test size(rec) == (3, 2)
            @test rec[:, 2] == [221.0, 222.0, 223.0]

            # a declared select is never pushed to the reader on a time-varying
            # source; it is applied after the record is sliced
            p = providers_from_document(
                _grid_doc(dir; from_extra = fixed); cache_root = joinpath(dir, "c1"),
                window = window
            )["M.f"]
            @test !p.push_to_reader
            @test !EarthSciAST.provider_supports_selection(p)
            @test EarthSciAST.provider_sample(p, feb) == [221.0, 222.0, 223.0]

            # records_per_sample = 2: a leading record axis the select takes whole
            # (set in the document: the run-time option may only restate it)
            two = providers_from_document(
                _grid_doc(dir; from_extra = merge(fixed, Dict{String, Any}("records_per_sample" => 2)));
                cache_root = joinpath(dir, "c2"), window = window,
                records_per_sample = Dict("M.f" => 2)
            )["M.f"]
            @test two.select[1] == "all"
            @test EarthSciAST.provider_sample(two, feb) ==
                [221.0 222.0 223.0; 321.0 322.0 323.0]

            # a selection reaching the provider anyway samples at t and slices
            # engine-side, an Integer keeping its axis as a reader would
            sl = EarthSciAST.provider_sample(whole, feb + 86400; selection = Any[[1, 3], 2])
            @test sl == reshape([221.0, 223.0], 2, 1)
            @test EarthSciAST.provider_sample(two, feb; selection = Any[Colon(), [3], 1]) ==
                reshape([213.0, 313.0], 2, 1, 1)

            # a gated select: its gate names the bracket axis too, and the
            # engine's no-pushdown fallback gets the whole record at t
            gated = Dict{String, Any}(
                "select" => Dict{String, Any}(
                    "axes" => Any[Dict("gated_by" => "Rows"), "all"]
                )
            )
            g = providers_from_document(
                _grid_doc(dir; from_extra = merge(gated, Dict{String, Any}("records_per_sample" => 2)));
                cache_root = joinpath(dir, "c3"), window = window
            )["M.f"]
            @test EarthSciAST.provider_gate_spec(g)["axes"] ==
                Any["all", Dict{String, Any}("gated_by" => "Rows"), "all"]
            @test !EarthSciAST.provider_supports_selection(g)
            @test size(EarthSciAST.provider_sample(g, feb)) == (2, 3, 2)
        end
    end
end

# `_cadence_doc` with three parameters reading NEI: `pair` sets
# `from.records_per_sample = 2` and declares the record axis `rec` (an interval
# of size 2) first, `single` sets 1, and `inherited` sets nothing, so it takes
# the source's `temporal.records_per_sample`.
function _two_record_doc(dir; source_rps = nothing)
    doc = _cadence_doc(dir)
    doc["index_sets"] = Dict{String, Any}(
        "rec" => Dict{String, Any}("kind" => "interval", "size" => 2),
        "row" => Dict{String, Any}("kind" => "interval", "size" => 2),
    )
    source_rps === nothing ||
        (doc["data_sources"]["NEI"]["temporal"]["records_per_sample"] = source_rps)
    function param(shape, rps)
        from = Dict{String, Any}("file_variable" => "NOX")
        rps === nothing || (from["records_per_sample"] = rps)
        return Dict{String, Any}(
            "type" => "parameter", "units" => "mol/s", "shape" => shape,
            "update" => Dict{String, Any}("kind" => "data", "source" => "NEI", "from" => from),
        )
    end
    doc["models"]["Emis"]["variables"] = Dict{String, Any}(
        "pair" => param(["rec", "row"], 2),
        "single" => param(["row"], 1),
        "inherited" => param(source_rps == 2 ? ["rec", "row"] : ["row"], nothing),
    )
    return doc
end

@testset "providers_from_document — from.records_per_sample reaches the provider" begin
    if !_ESIO_HAS_ESM
        @info "skipped: this EarthSciIO predates provider_from_esm"
    else
        mktempdir() do dir
            window = (u(2016, 1), u(2016, 4))
            subs = _SECTOR
            # No domain origin: model time 0 is the window start.
            t0 = u(2016, 1)
            provs = providers_from_document(
                _two_record_doc(dir); cache_root = joinpath(dir, "c1"),
                substitutions = subs, window = window
            )
            # February's record (at or before t) and March's, stacked along the
            # first declared dimension.
            @test EarthSciAST.provider_sample(provs["Emis.pair"], u(2016, 2, 15) - t0) ==
                [20.0 21.0; 30.0 31.0]
            @test vec(EarthSciAST.provider_sample(provs["Emis.single"], u(2016, 2, 15) - t0)) ==
                [20.0, 21.0]
            @test vec(EarthSciAST.provider_sample(provs["Emis.inherited"], u(2016, 2, 15) - t0)) ==
                [20.0, 21.0]

            # The source's temporal.records_per_sample is the default; a
            # parameter's own value overrides it.
            inh = providers_from_document(
                _two_record_doc(dir; source_rps = 2); cache_root = joinpath(dir, "c2"),
                substitutions = subs, window = window
            )
            @test EarthSciAST.provider_sample(inh["Emis.inherited"], u(2016, 1) - t0) ==
                [10.0 11.0; 20.0 21.0]
            @test vec(EarthSciAST.provider_sample(inh["Emis.single"], u(2016, 1) - t0)) ==
                [10.0, 11.0]

            # The run-time option may restate the document, never contradict it.
            err = try
                providers_from_document(
                    _two_record_doc(dir); cache_root = joinpath(dir, "c3"),
                    substitutions = subs, window = window,
                    records_per_sample = Dict("Emis.pair" => 1)
                )
                nothing
            catch e
                e
            end
            @test err isa EarthSciAST.RefreshError
            @test occursin("Emis.pair", sprint(showerror, err))
            @test occursin("update.from.records_per_sample", sprint(showerror, err))
            same = providers_from_document(
                _two_record_doc(dir); cache_root = joinpath(dir, "c4"),
                substitutions = subs, window = window,
                records_per_sample = Dict("Emis.pair" => 2, "Emis.single" => 1.0)
            )
            @test EarthSciAST.provider_sample(same["Emis.pair"], u(2016, 2, 15) - t0) ==
                [20.0 21.0; 30.0 31.0]
        end
    end
end

# The message `providers_from_document(doc; ...)` refuses `doc` with, or
# `nothing` when it does not.
function _refusal(doc, dir; kw...)
    try
        providers_from_document(
            doc; cache_root = joinpath(dir, "c-" * string(rand(UInt32))),
            substitutions = _SECTOR, kw...
        )
        return nothing
    catch e
        e isa EarthSciAST.RefreshError || rethrow()
        return sprint(showerror, e)
    end
end

@testset "providers_from_document — records_per_sample values and the sources that take 2" begin
    if !_ESIO_HAS_ESM
        @info "skipped: this EarthSciIO predates provider_from_esm"
    else
        mktempdir() do dir
            window = (u(2016, 1), u(2016, 4))
            subs = _SECTOR
            # No domain origin: model time 0 is the window start.
            t0 = u(2016, 1)
            pair_from(doc) = doc["models"]["Emis"]["variables"]["pair"]["update"]["from"]

            # One value rule: the number 1 or 2, `2.0` included.
            doc = _two_record_doc(dir)
            pair_from(doc)["records_per_sample"] = 2.0
            provs = providers_from_document(
                doc; cache_root = joinpath(dir, "v1"), substitutions = subs, window = window
            )
            @test EarthSciAST.provider_sample(provs["Emis.pair"], u(2016, 2, 15) - t0) ==
                [20.0 21.0; 30.0 31.0]
            for bad in (1.5, "2", true, 3, -2, 2^40)
                doc = _two_record_doc(dir)
                pair_from(doc)["records_per_sample"] = bad
                msg = _refusal(doc, dir; window = window)
                @test msg !== nothing && occursin("Emis.pair", msg) &&
                    occursin("update.from", msg) && occursin(repr(bad), msg)
            end
            doc = _two_record_doc(dir)
            doc["data_sources"]["NEI"]["temporal"]["records_per_sample"] = 1.5
            msg = _refusal(doc, dir; window = window)
            @test msg !== nothing && occursin("data_sources.NEI.temporal", msg)
            msg = _refusal(
                _two_record_doc(dir), dir; window = window,
                records_per_sample = Dict("Emis.pair" => "2")
            )
            @test msg !== nothing && occursin("run-time", msg) && occursin("\"2\"", msg)

            # A filtered source is one shared record table, which takes no time.
            doc = _two_record_doc(dir)
            doc["data_sources"]["NEI"]["record_filter"] =
                Dict{String, Any}("require_finite" => ["NOX"])
            msg = _refusal(doc, dir; window = window)
            @test msg !== nothing && occursin("Emis.pair", msg) &&
                occursin("data_sources.NEI", msg) && occursin("filtered or coded", msg)

            # A temporal block without a start is time-invariant: no successor.
            doc = _two_record_doc(dir)
            delete!(doc["data_sources"]["NEI"]["temporal"], "start")
            msg = _refusal(doc, dir; window = window)
            @test msg !== nothing && occursin("Emis.pair", msg) &&
                occursin("data_sources.NEI", msg) && occursin("time-invariant", msg)
            # Validation refuses it too (`records_per_sample_invalid`): the shared
            # conformance case `pair_from_startless_source` pins that.
        end
    end
end

# `_two_record_doc`, optionally re-pointed at files whose NOX is `(ROW, TSTEP)`
# in file order, so the time dimension is LAST rather than first; with
# `select`, `pair` and `single` each declare `[{fixed: 0}]`, which names the
# one non-time dimension (esm-spec §8.9.2).
function _layout_doc(dir; time_last::Bool, select::Bool)
    doc = _two_record_doc(dir)
    if time_last
        mirror = joinpath(dir, "mirror_time_last")
        mkpath(mirror)
        for m in 1:3
            f = joinpath(mirror, "nei_agr_0$m.ncf")
            isfile(f) && continue
            NCDatasets.NCDataset(f, "c") do ds
                NCDatasets.defDim(ds, "TSTEP", 1)
                NCDatasets.defDim(ds, "ROW", 2)
                # NCDatasets lists dims fastest-first: file order is (ROW, TSTEP).
                v = NCDatasets.defVar(ds, "NOX", Float32, ("TSTEP", "ROW"))
                v[1, :] = Float32[m * 10, m * 10 + 1]
            end
        end
        doc["data_sources"]["NEI"]["source"]["mirrors"] =
            ["file://$mirror/nei_{sector}_{date:%m}.ncf"]
    end
    if select
        vars = doc["models"]["Emis"]["variables"]
        for k in ("pair", "single")
            vars[k]["update"]["from"]["select"] =
                Dict{String, Any}("axes" => Any[Dict{String, Any}("fixed" => 0)])
        end
    end
    return doc
end

@testset "providers_from_document — the record axis first, a select over the rest" begin
    if !_ESIO_HAS_ESM
        @info "skipped: this EarthSciIO predates provider_from_esm"
    else
        mktempdir() do dir
            window = (u(2016, 1), u(2016, 4))
            subs = _SECTOR
            # No domain origin: model time 0 is the window start.
            t0 = u(2016, 1)
            t = u(2016, 2, 15) - t0
            build(doc, tag) = providers_from_document(
                doc; cache_root = joinpath(dir, tag), substitutions = subs, window = window
            )
            for time_last in (false, true)
                @testset "time $(time_last ? "last" : "first") in the file" begin
                    whole = build(_layout_doc(dir; time_last, select = false), "w$time_last")
                    pair = whole["Emis.pair"]
                    @test EarthSciAST.provider_sample(pair, t) == [20.0 21.0; 30.0 31.0]
                    @test vec(EarthSciAST.provider_sample(whole["Emis.single"], t)) ==
                        [20.0, 21.0]

                    # A time-varying source takes no pushed-down selection; one
                    # reaching it anyway is read at `t` and gathered over the
                    # delivered axes, whose first is the record axis.
                    @test !EarthSciAST.provider_supports_selection(pair)
                    @test EarthSciAST.provider_sample(pair, t; selection = Any[Colon(), [2]]) ==
                        reshape([21.0, 31.0], 2, 1)
                    @test EarthSciAST.provider_sample(pair, t; selection = Any[2, Colon()]) ==
                        [30.0 31.0]

                    # The declared select covers the non-time dim only.
                    sel = build(_layout_doc(dir; time_last, select = true), "s$time_last")
                    @test !sel["Emis.pair"].push_to_reader
                    got = EarthSciAST.provider_sample(sel["Emis.pair"], t)
                    @test size(got) == (2,)
                    @test got == [20.0, 30.0]
                    got = EarthSciAST.provider_sample(sel["Emis.single"], t)
                    @test size(got) == ()
                    @test got[] == 20.0
                end
            end
        end
    end
end
