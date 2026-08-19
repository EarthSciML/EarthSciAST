# The loader-ingest surface of esm-spec §8.9, executed: `reader_options`,
# `codes`, `record_filter`, `extent` and `select` served by
# `providers_from_document` + `prepare`, over real local fixtures (an FF10 zip
# and a Zarr v2 store, both over the `file` transport — no network).
#
# The document under test is the committed conformance fixture
# `tests/valid/data_loaders_ingest_and_select.esm`; only its two `url_template`s
# are patched onto the temporary fixtures, so what the validation sweep checks
# and what this file runs are the same declaration. The Rust mirror is
# `pkg/earthsci-ast-rs/tests/loader_ingest_and_select.rs` — same fixture, same
# numbers, which is the point of the exercise.
#
# ESM_COMPLIANCE_VALIDATION_MATRIX rows exercised here:
#   FORMAT-08-A-006  an unrecognised `reader_options` key is an ERROR
#   FORMAT-08-A-007  a text column with no `codes` map is a boundary error
#   FORMAT-08-A-008  a dropped record leaves EVERY variable of the loader
#   FORMAT-08-A-009  `select` is over the DELIVERED axis; both paths agree
#   FORMAT-08-A-010  `extent` closes a metaparameter before the typed load

using Test
using EarthSciAST
using EarthSciIO
using EarthSciIO: Cache, LocalStore, const_provider
import Blosc
import JSON
import ZipFile

const EA_LIS = EarthSciAST

# --------------------------------------------------------------------------- #
# Fixtures — an EPA-2016fd-shaped FF10 zip and a 1-D Zarr v2 grid store.
# --------------------------------------------------------------------------- #

# The FF10 point schema's 77 columns, by the indices this fixture writes.
const _LIS_N_COL = 77
const _LIS_C_POLID = 13      # 1-based Julia index of FF10 column 12 (0-based)
const _LIS_C_ANN = 14
const _LIS_C_LON = 24
const _LIS_C_LAT = 25

function _lis_ff10_row(polid, ann, lon, lat)
    r = fill("", _LIS_N_COL)
    r[1] = "US"; r[2] = "01001"
    r[_LIS_C_POLID] = polid; r[_LIS_C_ANN] = ann
    r[_LIS_C_LON] = lon; r[_LIS_C_LAT] = lat
    return join(r, ",")
end

# Two `*egu*` members plus one the glob must exclude. The `*egu*` rows, in the
# order the reader concatenates them (member name ascending), and what the
# document's declarations do to each:
#
#   | POLID | ann | lon | fate                                        |
#   | NOX   | 100 | -90 | kept, code 36                               |
#   | CO    |  50 | -91 | DROPPED — not in the `codes` map            |
#   | SO2   |  25 |     | DROPPED — blank longitude is not finite     |
#   | nox   |   7 | -92 | kept, code 36 (`case_insensitive`)          |
#   | VOC   |   3 | -93 | kept, code 1                                |
function _lis_write_ff10_zip(dir)
    header = join(vcat(["country_cd", "region_cd", "tribal_code", "facility_id",
                        "unit_id", "rel_point_id", "process_id", "agy_facility_id",
                        "agy_unit_id", "agy_rel_point_id", "agy_process_id", "scc",
                        "polid", "ann_value"],
                       ["col$i" for i in 14:(_LIS_N_COL - 1)]), ",")
    member(rows) = "#FORMAT=FF10_POINT\n$header\n" * join(rows, "\n") * "\n"
    path = joinpath(dir, "2016fd_inputs_point.zip")
    w = ZipFile.Writer(path)
    for (name, rows) in [
        ("point/egu_alpha.csv", [_lis_ff10_row("NOX", "100.0", "-90.0", "40.0"),
                                 _lis_ff10_row("CO", "50.0", "-91.0", "41.0"),
                                 _lis_ff10_row("SO2", "25.0", "", "42.0")]),
        ("point/egu_beta.csv", [_lis_ff10_row("nox", "7.0", "-92.0", "43.0"),
                                _lis_ff10_row("VOC", "3.0", "-93.0", "44.0")]),
        ("point/ptnonipm.csv", [_lis_ff10_row("NOX", "999.0", "-94.0", "45.0")]),
    ]
        f = ZipFile.addfile(w, name; method = ZipFile.Store)
        write(f, member(rows))
    end
    close(w)
    return "file://" * path
end

# A Zarr v2 store with one uncompressed 1-D `W` array, `W[i] = 100 + i`.
function _lis_write_grid_store(dir, n)
    store = joinpath(dir, "grid.zarr")
    arr = joinpath(store, "W")
    mkpath(arr)
    write(joinpath(arr, ".zarray"), JSON.json(Dict(
        "zarr_format" => 2, "shape" => [n], "chunks" => [n], "dtype" => "<f8",
        "compressor" => nothing, "fill_value" => 0.0, "order" => "C",
        "filters" => nothing)))
    write(joinpath(arr, ".zattrs"), JSON.json(Dict("_ARRAY_DIMENSIONS" => ["cell"])))
    open(joinpath(arr, "0"), "w") do io
        for i in 0:(n - 1)
            write(io, htol(100.0 + i))
        end
    end
    return "file://" * store * "/"
end

"""The committed fixture with its two placeholder URLs pointed at `dir`."""
function _lis_document(dir)
    path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "data_loaders_ingest_and_select.esm")
    doc = JSON.parsefile(path)
    doc["data_loaders"]["EGU_Emis"]["source"]["url_template"] = _lis_write_ff10_zip(dir)
    doc["data_loaders"]["Grid"]["source"]["url_template"] = _lis_write_grid_store(dir, 10)
    return doc
end

_lis_sample(doc, cache_root, key) = Float64.(EA_LIS.provider_sample(
    EA_LIS.providers_from_document(doc; cache_root = cache_root)[key], 0.0))

@testset "loader ingest + select (esm-spec §8.9)" begin

    # ---- U1: the ingest is the LOADER's, not the caller's ------------------ #

    @testset "the document alone decodes, maps and filters the FF10 table" begin
        mktempdir() do dir
            doc = _lis_document(dir)
            cache = joinpath(dir, "cache")
            # reader_options selected the two *egu* members and dropped their
            # header lines; codes mapped POLID; record_filter removed the
            # unmapped CO record and the SO2 record with no longitude. All of it
            # from the declaration — FORMAT-08-A-006/007/008.
            @test _lis_sample(doc, cache, "EGU_Emis.pollutant") == [36.0, 36.0, 1.0]
            @test _lis_sample(doc, cache, "EGU_Emis.annual") == [100.0, 7.0, 3.0]
            @test _lis_sample(doc, cache, "EGU_Emis.lon") == [-90.0, -92.0, -93.0]
            @test _lis_sample(doc, cache, "EGU_Emis.lat") == [40.0, 43.0, 44.0]
        end
    end

    @testset "every variable of a filtered loader declares the same extent" begin
        mktempdir() do dir
            doc = _lis_document(dir)
            provs = EA_LIS.providers_from_document(doc; cache_root = joinpath(dir, "cache"))
            for (key, p) in provs
                declared = EA_LIS.provider_extent_metaparameter(p)
                if startswith(key, "EGU_Emis.")
                    @test declared == "N_REC"
                else
                    @test declared === nothing
                end
            end
        end
    end

    @testset "prepare discovers N_REC and the graph is sized by it" begin
        mktempdir() do dir
            doc = _lis_document(dir)
            providers = EA_LIS.providers_from_document(doc; cache_root = joinpath(dir, "cache"))
            insp = EA_LIS.BuildInspection()
            # NOTE the absent metaparameters: the caller passes NO N_REC. The
            # document declares that the loader knows it (FORMAT-08-A-010).
            prep = EA_LIS.prepare(doc; providers = providers, inspect = insp,
                                  pushdown_rewrite = true)
            @test EA_LIS.observed_field(prep, insp, "is_NOx") == [1.0, 1.0, 0.0]
            # 100 + 7 — the dropped CO/SO2 records contribute nothing, because
            # they are not records.
            @test only(EA_LIS.observed_field(prep, insp, "E_NOx")) == 107.0
        end
    end

    @testset "a caller binding that contradicts the discovered extent errors" begin
        mktempdir() do dir
            doc = _lis_document(dir)
            providers = EA_LIS.providers_from_document(doc; cache_root = joinpath(dir, "cache"))
            err = try
                EA_LIS.prepare(doc; providers = providers, pushdown_rewrite = true,
                               metaparameters = Dict("N_REC" => 5))  # the RAW row count
                nothing
            catch e
                e
            end
            @test err !== nothing            # never silently prefer either side
            msg = sprint(showerror, err)
            @test occursin("N_REC", msg)
            @test occursin("discovers 3", msg)
        end
    end

    @testset "a text column with no codes map is a boundary error" begin
        mktempdir() do dir
            doc = _lis_document(dir)
            delete!(doc["data_loaders"]["EGU_Emis"]["variables"]["pollutant"], "codes")
            provs = EA_LIS.providers_from_document(doc; cache_root = joinpath(dir, "cache"))
            err = try
                EA_LIS.provider_sample(provs["EGU_Emis.pollutant"], 0.0)
                nothing
            catch e
                e
            end
            @test err !== nothing            # a text forcing must not load
            msg = sprint(showerror, err)
            @test occursin("decoded as strings", msg)
            @test occursin("codes", msg)
        end
    end

    # FORMAT-08-A-006: an unrecognised `reader_options` key is an ERROR, never a
    # silently-ignored one. EarthSciIO enforces it at Provider construction, so
    # a mis-spelling fails where `providers_from_document` builds the provider.
    @testset "an unrecognised reader_options key is refused" begin
        mktempdir() do dir
            doc = _lis_document(dir)
            doc["data_loaders"]["EGU_Emis"]["reader_options"] =
                Dict("member_filter" => "*egu*", "skip_header_row" => true)
            err = try
                EA_LIS.providers_from_document(doc; cache_root = joinpath(dir, "cache"))
                nothing
            catch e
                e
            end
            @test err !== nothing
            msg = sprint(showerror, err)
            @test occursin("member_filter", msg)
            @test occursin("member_glob", msg)     # says what it DOES take
        end
    end

    # ---- U2: a range select in the loader ---------------------------------- #

    @testset "a range select delivers a prefix of the same on-disk array" begin
        mktempdir() do dir
            doc = _lis_document(dir)
            cache = joinpath(dir, "cache")
            full = _lis_sample(doc, cache, "Grid.W")
            @test length(full) == 10               # the unselected variable is unaffected
            @test full[1] == 100.0
            # `stop` is the METAPARAMETER NAME N_SRC (default 4), not a literal.
            prefix = _lis_sample(doc, cache, "Grid.src_W")
            @test prefix == full[1:4]
            @test prefix == [100.0, 101.0, 102.0, 103.0]
        end
    end

    # FORMAT-08-A-009: pushing the selection to the reader and applying it after
    # the read MUST agree exactly. `Grid.src_W` is store-backed (pushed down);
    # the same declaration over a filtered table is applied engine-side.
    @testset "reader-pushed and engine-applied selections agree" begin
        mktempdir() do dir
            doc = _lis_document(dir)
            provs = EA_LIS.providers_from_document(doc; cache_root = joinpath(dir, "cache"))
            src = provs["Grid.src_W"]
            @test src.push_to_reader                       # zarr fetches pre-sliced
            pushed = Float64.(EA_LIS.provider_sample(src, 0.0))
            # the same provider forced onto the post-read path
            EXT = Base.get_extension(EarthSciAST, :EarthSciASTEarthSciIOExt)
            engine = EXT.DeclaredProvider(src.key, src.varname, src.inner, src.table,
                                          src.column, src.select, false, src.extent_mp,
                                          src.unit_conversion)
            @test Float64.(EA_LIS.provider_sample(engine, 0.0)) == pushed
        end
    end

    @testset "a range select over a filtered table counts SURVIVING records" begin
        mktempdir() do dir
            doc = _lis_document(dir)
            # A loader-level select is the default for every variable of the
            # loader — which is what keeps a truncated table aligned.
            doc["data_loaders"]["EGU_Emis"]["select"] =
                Dict("axes" => [Dict("range" => Dict("start" => 0, "stop" => 2))])
            cache = joinpath(dir, "cache")
            # [0:2] is the first two SURVIVING records (100, 7) — never the first
            # two raw rows (100, 50) of which one is dropped.
            @test _lis_sample(doc, cache, "EGU_Emis.annual") == [100.0, 7.0]
            @test _lis_sample(doc, cache, "EGU_Emis.pollutant") == [36.0, 36.0]
            @test _lis_sample(doc, cache, "EGU_Emis.lon") == [-90.0, -92.0]
        end
    end

    @testset "a truncated table re-discovers its own smaller extent" begin
        mktempdir() do dir
            doc = _lis_document(dir)
            doc["data_loaders"]["EGU_Emis"]["select"] =
                Dict("axes" => [Dict("range" => Dict("start" => 0, "stop" => 2))])
            providers = EA_LIS.providers_from_document(doc; cache_root = joinpath(dir, "cache"))
            insp = EA_LIS.BuildInspection()
            prep = EA_LIS.prepare(doc; providers = providers, inspect = insp,
                                  pushdown_rewrite = true)
            @test only(EA_LIS.observed_field(prep, insp, "E_NOx")) == 107.0
            # N_REC follows the DELIVERED records, so a reduced run needs no
            # other knob.
            @test length(EA_LIS.observed_field(prep, insp, "is_NOx")) == 2
        end
    end

    @testset "the selected prefix reaches the model as its own axis" begin
        mktempdir() do dir
            doc = _lis_document(dir)
            providers = EA_LIS.providers_from_document(doc; cache_root = joinpath(dir, "cache"))
            insp = EA_LIS.BuildInspection()
            prep = EA_LIS.prepare(doc; providers = providers, inspect = insp,
                                  pushdown_rewrite = true)
            w = EA_LIS.observed_field(prep, insp, "src_width")
            # src_W is delivered on src_cells (N_SRC), not the full pop_cells axis
            @test size(w) == (4,)
            @test w == [101.0, 102.0, 103.0, 104.0]
        end
    end

    @testset "an unrecognised axis selector is refused at construction" begin
        mktempdir() do dir
            doc = _lis_document(dir)
            doc["data_loaders"]["Grid"]["variables"]["src_W"]["select"] =
                Dict("axes" => [Dict("prefix" => 4)])
            err = try
                EA_LIS.providers_from_document(doc; cache_root = joinpath(dir, "cache"))
                nothing
            catch e
                e
            end
            @test err !== nothing               # an unknown selector is not ignored
            @test occursin("unrecognised axis selector keys", sprint(showerror, err))
        end
    end
end
