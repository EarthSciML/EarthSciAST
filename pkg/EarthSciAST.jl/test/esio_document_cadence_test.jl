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

@testset "providers_from_document — a monthly source with a bound sector" begin
    if !_ESIO_HAS_ESM
        @info "skipped: this EarthSciIO predates provider_from_esm"
    else
        mktempdir() do dir
            doc = _cadence_doc(dir)
            u(y, m, d = 1, h = 0) = datetime2unix(DateTime(y, m, d, h))
            window = (u(2016, 1), u(2016, 4))
            provs = providers_from_document(
                doc; cache_root = joinpath(dir, "cache"),
                substitutions = Dict("NEI" => Dict("sector" => "agr")), window = window
            )
            p = provs["Emis.nox"]
            @test !EarthSciAST.provider_is_const(p)
            # calendar months, not a mean month of 30.436875 days
            @test EarthSciAST.provider_refresh_times(p) == [u(2016, 1), u(2016, 2), u(2016, 3)]
            # the primary location is missing: each month comes from its mirror,
            # converted by the declared unit_conversion
            @test vec(EarthSciAST.provider_sample(p, u(2016, 2, 29, 23))) == [40.0, 42.0]
            @test vec(EarthSciAST.provider_sample(p, u(2016, 3))) == [60.0, 62.0]

            @test_throws EarthSciIO.EsmTemplateError providers_from_document(
                doc; cache_root = joinpath(dir, "cache2"), window = window
            )

            doc["models"]["Emis"]["variables"]["nox"]["update"]["from"]["records_per_sample"] = 2
            two = providers_from_document(
                doc; cache_root = joinpath(dir, "cache3"),
                substitutions = Dict("NEI" => Dict("sector" => "agr")), window = window
            )
            got = EarthSciAST.provider_sample(two["Emis.nox"], u(2016, 2, 15))
            # the record axis first, in the file's dimension order
            @test got == [40.0 42.0; 60.0 62.0]
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
            u(y, m, d = 1, h = 0) = datetime2unix(DateTime(y, m, d, h))
            window = (u(2016, 1), u(2016, 4))
            subs = Dict("NEI" => Dict("sector" => "agr"))
            provs = providers_from_document(
                _two_record_doc(dir); cache_root = joinpath(dir, "c1"),
                substitutions = subs, window = window
            )
            # February's record (at or before t) and March's, stacked along the
            # first declared dimension.
            @test EarthSciAST.provider_sample(provs["Emis.pair"], u(2016, 2, 15)) ==
                [20.0 21.0; 30.0 31.0]
            @test vec(EarthSciAST.provider_sample(provs["Emis.single"], u(2016, 2, 15))) ==
                [20.0, 21.0]
            @test vec(EarthSciAST.provider_sample(provs["Emis.inherited"], u(2016, 2, 15))) ==
                [20.0, 21.0]

            # The source's temporal.records_per_sample is the default; a
            # parameter's own value overrides it.
            inh = providers_from_document(
                _two_record_doc(dir; source_rps = 2); cache_root = joinpath(dir, "c2"),
                substitutions = subs, window = window
            )
            @test EarthSciAST.provider_sample(inh["Emis.inherited"], u(2016, 1)) ==
                [10.0 11.0; 20.0 21.0]
            @test vec(EarthSciAST.provider_sample(inh["Emis.single"], u(2016, 1))) ==
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
            @test EarthSciAST.provider_sample(same["Emis.pair"], u(2016, 2, 15)) ==
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
            substitutions = Dict("NEI" => Dict("sector" => "agr")), kw...
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
            u(y, m, d = 1, h = 0) = datetime2unix(DateTime(y, m, d, h))
            window = (u(2016, 1), u(2016, 4))
            subs = Dict("NEI" => Dict("sector" => "agr"))
            pair_from(doc) = doc["models"]["Emis"]["variables"]["pair"]["update"]["from"]

            # One value rule: the number 1 or 2, `2.0` included.
            doc = _two_record_doc(dir)
            pair_from(doc)["records_per_sample"] = 2.0
            provs = providers_from_document(
                doc; cache_root = joinpath(dir, "v1"), substitutions = subs, window = window
            )
            @test EarthSciAST.provider_sample(provs["Emis.pair"], u(2016, 2, 15)) ==
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
            u(y, m, d = 1, h = 0) = datetime2unix(DateTime(y, m, d, h))
            window = (u(2016, 1), u(2016, 4))
            subs = Dict("NEI" => Dict("sector" => "agr"))
            t = u(2016, 2, 15)
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

                    # The gated fetch reads at `t` and gathers the selection over
                    # the delivered axes, whose first is the record axis.
                    @test EarthSciAST.provider_supports_selection(pair)
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
