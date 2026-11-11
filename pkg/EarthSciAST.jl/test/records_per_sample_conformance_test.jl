# Cross-language conformance for record axes and the deprecated
# `records_per_sample` (esm-spec §8.5.1).
#
# Drives the shared manifest at `tests/conformance/records_per_sample/`. Every
# diagnostic is filtered by the manifest's `record_codes`. A valid case must
# validate with none of them, flatten with each data-fed parameter's
# `LoaderField` reporting the number of records its record shape gives it, keep
# the deprecated field on the flattened parameter's `update.from` exactly as
# written, round-trip both that field and every index set's `records` flag
# through emit -> load, and report exactly `deprecated_fields` from
# `deprecated_records_per_sample_sites` — loading warning once when that list is
# non-empty and not at all when it is empty. An `invalid` case must be refused
# by validation with exactly one finding from `record_codes`, `code` at
# `pointer`; a `flatten_invalid` case validates clean of them and is refused by
# `flatten` with `code`, the message naming the pointer; a `refused` case is
# refused by whichever of the two first sees the record shape.

using Test
using Logging
using EarthSciAST
using JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _RPS_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "records_per_sample")
const _RPS_MANIFEST = JSON3.read(read(joinpath(_RPS_DIR, "manifest.json"), String))
const _RPS_CODES = Set(String.(_RPS_MANIFEST.record_codes))

_rps_from(v) = v.update === nothing ? nothing : only(v.update).from

function _rps_test_flatten_refuses(file, case)
    err = try
        flatten(file)
        nothing
    catch e
        e
    end
    @test err isa EarthSciAST.ExpressionTemplateError
    err isa EarthSciAST.ExpressionTemplateError || return
    @test err.code == String(case.code)
    return @test occursin(String(case.pointer), err.message)
end

# Load `path`, capturing the `deprecated_records_per_sample` warnings the load
# emits.
function _rps_load_logged(path)
    logger = Test.TestLogger(; min_level = Logging.Warn)
    file = with_logger(() -> EarthSciAST.load_path(path), logger)
    deprecations = [
        r for r in logger.logs
            if r.level == Logging.Warn &&
            startswith(string(r.message), "deprecated_records_per_sample:")
    ]
    return file, deprecations
end

# Every top-level model variable's `update.from`, as `(model, variable, from)`.
_rps_froms(file) = file.models === nothing ? [] : [
        (mname, vname, _rps_from(v)) for (mname, model) in file.models
        for (vname, v) in model.variables if _rps_from(v) !== nothing
    ]

# Every top-level reaction-system parameter's `update.from`, as
# `(system, parameter, from)`.
_rps_rs_froms(file) = file.reaction_systems === nothing ? [] : [
        (rname, p.name, _rps_from(p)) for (rname, rs) in file.reaction_systems
        for p in rs.parameters if _rps_from(p) !== nothing
    ]

@testset "conformance: record axes / records_per_sample (esm-spec §8.5.1)" begin
    for code in _RPS_CODES
        @test code in EarthSciAST.error_code_names()
    end
    for case in _RPS_MANIFEST.cases
        path = joinpath(_RPS_DIR, String(case.path))
        @testset "$(case.id)" begin
            file, deprecations = _rps_load_logged(path)
            result = EarthSciAST.validate(file)
            found = [e for e in result.structural_errors if e.error_type in _RPS_CODES]
            if case.expect == "valid"
                @test isempty(found)
                @test isempty(result.schema_errors)
                # Where the deprecated field is written, and the one warning
                # that names exactly those places.
                want_sites = String.(case.deprecated_fields)
                @test deprecated_records_per_sample_sites(file) == want_sites
                @test length(deprecations) == (isempty(want_sites) ? 0 : 1)
                if !isempty(deprecations)
                    msg = string(only(deprecations).message)
                    @test endswith(msg, "Written at: " * join(want_sites, ", ") * ".")
                end
                flat = flatten(file)
                got = Dict(lf.name => lf for lf in flat.loader_fields)
                for want in case.loader_fields
                    lf = get(got, String(want.name), nothing)
                    @test lf !== nothing
                    lf === nothing && continue
                    @test lf.subkey == want.source
                    @test lf.var == want.file_variable
                    @test lf.cadence == want.cadence
                    @test lf.records_per_sample == want.records_per_sample
                end
                if haskey(case, :flattened_from_records_per_sample)
                    for (name, written) in pairs(case.flattened_from_records_per_sample)
                        from = _rps_from(flat.parameters[String(name)])
                        @test from !== nothing
                        @test from.records_per_sample == written
                    end
                end
                # The deprecated field and each index set's `records` flag
                # survive emit -> load unchanged.
                again = with_logger(NullLogger()) do
                    EarthSciAST.load_string(EarthSciAST.to_json(file))
                end
                for (mname, vname, from) in _rps_froms(file)
                    @test _rps_from(again.models[mname].variables[vname]).records_per_sample ==
                        from.records_per_sample
                end
                for (rname, pname, from) in _rps_rs_froms(file)
                    p = only(filter(q -> q.name == pname, again.reaction_systems[rname].parameters))
                    @test _rps_from(p).records_per_sample == from.records_per_sample
                end
                @test Set(keys(again.index_sets)) == Set(keys(file.index_sets))
                for (name, iset) in file.index_sets
                    @test again.index_sets[name].records === iset.records
                end
                @test deprecated_records_per_sample_sites(again) == want_sites
            elseif case.expect == "invalid"
                @test [(e.error_type, e.path) for e in found] ==
                    [(String(case.code), String(case.pointer))]
            elseif case.expect == "flatten_invalid"
                @test isempty(found)
                _rps_test_flatten_refuses(file, case)
            elseif case.expect == "refused"
                # Whichever stage first sees the record shape refuses it.
                if isempty(found)
                    _rps_test_flatten_refuses(file, case)
                else
                    @test [(e.error_type, e.path) for e in found] ==
                        [(String(case.code), String(case.pointer))]
                end
            else
                error("unknown expectation '$(case.expect)' in case $(case.id)")
            end
        end
    end

    # Outside deciding how many records a data-fed parameter receives, a record
    # axis is an ordinary interval of size 2, carried by `flatten` with its flag
    # (esm-spec §8.5.1).
    @testset "the records flag survives flatten" begin
        file = EarthSciAST.load_path(joinpath(_RPS_DIR, "fixtures", "record_axis.esm"))
        flat = flatten(file)
        @test flat.index_sets["rec"].records === true
        @test flat.index_sets["pair2"].records === nothing
    end

    # Reaction-system data-fed parameters are judged exactly as model ones are,
    # at validation and at the flatten re-check.
    function rs_doc(t_shape; written = nothing, temporal = true)
        source = Dict{String, Any}(
            "kind" => "grid",
            "source" => Dict("url_template" => "file:///data/met_{date:%Y%m%d}.nc"),
        )
        if temporal
            t = Dict{String, Any}(
                "start" => "2024-05-01T00:00:00Z", "frequency" => "PT1H",
                "file_period" => "P1D", "records_per_file" => 24,
            )
            written === nothing || (t["records_per_sample"] = written)
            source["temporal"] = t
        end
        return Dict{String, Any}(
            "esm" => "1.3.0",
            "metadata" => Dict("name" => "ReactionSystemRecords"),
            "index_sets" => Dict(
                "rec" => Dict("kind" => "interval", "size" => 2, "records" => true),
                "cells" => Dict("kind" => "interval", "size" => 4),
            ),
            "data_sources" => Dict("met" => source),
            "reaction_systems" => Dict(
                "Chem" => Dict(
                    "species" => Dict("A" => Dict("units" => "mol/mol", "default" => 1.0)),
                    "parameters" => Dict(
                        "T" => Dict(
                            "units" => "K", "default" => 298.0, "shape" => t_shape,
                            "update" => Dict(
                                "kind" => "data", "source" => "met",
                                "from" => Dict("file_variable" => "t2m"),
                            ),
                        ),
                    ),
                    "reactions" => [
                        Dict(
                            "id" => "R1",
                            "substrates" => [Dict("species" => "A", "stoichiometry" => 1)],
                            "products" => nothing, "rate" => 0.1,
                        ),
                    ],
                ),
            ),
        )
    end
    rs_load(d) = with_logger(() -> EarthSciAST.load_string(JSON3.write(d)), NullLogger())
    rs_found(file) = [
        (e.error_type, e.path) for e in EarthSciAST.validate(file).structural_errors
            if e.error_type in _RPS_CODES
    ]
    rs_at = "/reaction_systems/Chem/parameters/T/update"

    @testset "reaction-system data-fed parameters" begin
        @test rs_found(rs_load(rs_doc(["cells"]; written = 2))) ==
            [("records_per_sample_invalid", rs_at)]
        @test rs_found(rs_load(rs_doc(["rec", "cells"]; temporal = false))) ==
            [("record_axis_time_invariant_source", rs_at)]
        @test isempty(rs_found(rs_load(rs_doc(["rec", "cells"]; written = 2))))

        # The flatten re-check sees reaction systems too.
        file = rs_load(rs_doc(["cells"]))
        t = only(file.reaction_systems["Chem"].parameters)
        empty!(t.shape)
        append!(t.shape, ["cells", "rec"])
        _rps_test_flatten_refuses(
            file, (code = "record_axis_misplaced", pointer = rs_at)
        )
    end

    # Raw index-set merges (template import, mount rename, native mount) read
    # `"records": false` as an absent `records`; `true` against either differs.
    @testset "raw index-set merge equality reads records" begin
        plain = Dict{String, Any}("kind" => "interval", "size" => 2)
        off = Dict{String, Any}("kind" => "interval", "size" => 2, "records" => false)
        on = Dict{String, Any}("kind" => "interval", "size" => 2, "records" => true)
        @test EarthSciAST._index_set_raw_equal(plain, off)
        @test EarthSciAST._index_set_raw_equal(JSON3.read(JSON3.write(off)), plain)
        @test !EarthSciAST._index_set_raw_equal(plain, on)
        @test !EarthSciAST._index_set_raw_equal(off, on)
        dst = EarthSciAST.OrderedDict{String, Any}("gf_t" => plain)
        EarthSciAST._merge_named!(
            dst, "gf_t", off, "template_import_index_set_conflict", "index set", "lib"
        )
        @test_throws EarthSciAST.ExpressionTemplateError EarthSciAST._merge_named!(
            dst, "gf_t", on, "template_import_index_set_conflict", "index set", "lib"
        )
    end

    # A model subsystem still held as an unresolved ref may declare index sets,
    # so a first axis the document does not declare is not decidable yet: it is
    # skipped, not read as a plain axis.
    @testset "an undeclared first axis is skipped while a ref is unmounted" begin
        d = Dict{String, Any}(
            "esm" => "1.3.0",
            "metadata" => Dict("name" => "PendingRef"),
            "index_sets" => Dict("cells" => Dict("kind" => "interval", "size" => 4)),
            "data_sources" => Dict(
                "met" => Dict(
                    "kind" => "grid",
                    "source" => Dict("url_template" => "file:///data/met_{date:%Y%m%d}.nc"),
                    "temporal" => Dict(
                        "start" => "2024-05-01T00:00:00Z", "frequency" => "PT1H",
                        "file_period" => "P1D", "records_per_file" => 24,
                    ),
                ),
            ),
            "models" => Dict(
                "Met" => Dict(
                    "variables" => Dict(
                        "K" => Dict(
                            "type" => "parameter", "units" => "1/s", "default" => 0.1,
                            "shape" => ["rec_from_mount", "cells"],
                            "update" => Dict(
                                "kind" => "data", "source" => "met",
                                "from" => Dict(
                                    "file_variable" => "K", "records_per_sample" => 2,
                                ),
                            ),
                        ),
                    ),
                    "equations" => [],
                ),
            ),
        )
        file = rs_load(d)
        # A mount `load_string` would resolve; held unresolved here.
        file.models["Met"].subsystems["Grid"] = EarthSciAST.SubsystemRef("./grid.esm")
        @test isempty(rs_found(file))
        # With nothing left to mount, the same first axis is a plain one.
        delete!(file.models["Met"].subsystems, "Grid")
        @test rs_found(file) == [("records_per_sample_invalid", "/models/Met/variables/K/update")]
    end
end
