"""Assert that the generated fixtures are what manifest.json claims they are.

Every assertion here is about the fixtures themselves: shape (rows, fragments,
deletion files, data files), schema (Arrow type, C format string, tier), and
the expected/*.jsonl references.  P1-P4 build SQL cases on top of these
numbers, so a fixture that drifts from its manifest entry has to fail here
rather than show up as a mysterious regress diff later.
"""

import json
import os
from decimal import Decimal

import lance
import pyarrow as pa
import pytest

import gen_fixtures as gen
from conftest import dataset_path

#: WORKPLAN §2.0 freezes these names; 'big' is opt-in and not listed here.
FROZEN_NAMES = [
    "types_all", "types_b", "deleted", "empty",
    "frag_1", "frag_2", "frag_3", "frag_7", "frag_100", "frag_gap",
    "evolved", "blob", "large_text", "versions",
]

#: Every A-tier Arrow type of DESIGN §2 has to appear in types_all.  Losing a
#: dimension here silently would make AC3 vacuous, so spell them all out.
A_TIER_TYPES = [
    pa.bool_(), pa.int8(), pa.int16(), pa.int32(), pa.int64(),
    pa.uint8(), pa.uint16(), pa.uint32(),
    pa.float16(), pa.float32(), pa.float64(),
    pa.string(), pa.large_string(), pa.binary(), pa.large_binary(),
    pa.date32(),
    pa.timestamp("s"), pa.timestamp("ms"), pa.timestamp("us"), pa.timestamp("ns"),
    pa.timestamp("s", tz="UTC"), pa.timestamp("ms", tz="UTC"),
    pa.timestamp("us", tz="Asia/Shanghai"), pa.timestamp("ns", tz="UTC"),
    pa.decimal128(38, 10), pa.decimal128(10, 2),
    pa.list_(pa.float32(), 4), pa.list_(pa.float64(), 4),
    pa.list_(pa.int64()), pa.list_(pa.string()),
]

DELETED_IDS = [0, 3, 11, 19]


def entry(manifest, name):
    assert name in manifest["datasets"], "manifest has no entry for %r" % name
    return manifest["datasets"][name]


def expected_lines(fixtures_root, name):
    with open(os.path.join(fixtures_root, "expected", "%s.jsonl" % name)) as fh:
        return fh.readlines()


# --------------------------------------------------------------------------
# manifest <-> data
# --------------------------------------------------------------------------

def test_manifest_covers_the_frozen_dataset_names(manifest):
    assert list(manifest["datasets"]) == FROZEN_NAMES
    assert list(gen.BUILDERS) == FROZEN_NAMES
    assert manifest["manifest_format"] == gen.MANIFEST_FORMAT
    assert manifest["generated_by"]["pylance"] == lance.__version__


@pytest.mark.parametrize("name", FROZEN_NAMES)
def test_shape_matches_manifest(manifest, opened, name):
    e = entry(manifest, name)
    ds = opened(name)
    frags = ds.get_fragments()

    assert ds.version == e["version"]
    assert ds.count_rows() == e["rows"]
    assert len(frags) == e["fragments"]
    assert [f.fragment_id for f in frags] == e["fragment_ids"]
    assert [f.count_rows() for f in frags] == e["fragment_rows"]
    assert [f.metadata.physical_rows for f in frags] == e["fragment_physical_rows"]
    assert [f.fragment_id for f in frags
            if f.metadata.deletion_file is not None] == e["fragments_with_deletion_file"]
    assert [len(f.metadata.files) for f in frags] == e["data_files_per_fragment"]
    assert sum(e["fragment_rows"]) == e["rows"]


@pytest.mark.parametrize("name", FROZEN_NAMES)
def test_lance_format_version_matches_manifest(manifest, opened, name):
    e = entry(manifest, name)
    ds = opened(name)
    assert ds.data_storage_version == e["data_storage_version"]
    seen = sorted({"%d.%d" % (f.file_major_version, f.file_minor_version)
                   for frag in ds.get_fragments() for f in frag.metadata.files})
    assert seen == e["file_format_versions"]


@pytest.mark.parametrize("name", FROZEN_NAMES)
def test_schema_matches_manifest(manifest, opened, name):
    e = entry(manifest, name)
    ds = opened(name)
    assert [f.name for f in ds.schema] == [c["name"] for c in e["schema"]]

    for field, col in zip(ds.schema, e["schema"]):
        assert str(field.type) == col["arrow_type"], field.name
        assert gen.arrow_c_format(field) == col["arrow_format"], field.name
        assert field.nullable == col["nullable"], field.name
        md = None
        if field.metadata:
            md = {k.decode(): v.decode() for k, v in field.metadata.items()}
        assert md == col["metadata"], field.name
        tier, pg_type = gen.classify(field.type)
        assert (tier, pg_type) == (col["tier"], col["pg_type"]), field.name


@pytest.mark.parametrize("name", FROZEN_NAMES)
def test_history_matches_manifest(manifest, name):
    e = entry(manifest, name)
    assert [v["version"] for v in e["history"]] == list(range(1, e["version"] + 1))
    for v in e["history"]:
        ds = lance.dataset(dataset_path(name), version=v["version"])
        assert ds.count_rows() == v["rows"], (name, v["version"])
    assert e["history"][-1]["rows"] == e["rows"]


# --------------------------------------------------------------------------
# expected/*.jsonl
# --------------------------------------------------------------------------

@pytest.mark.parametrize("name", FROZEN_NAMES)
def test_expected_has_one_line_per_row(manifest, opened, fixtures_root, name):
    e = entry(manifest, name)
    lines = expected_lines(fixtures_root, name)
    assert len(lines) == opened(name).count_rows()
    assert len(lines) == e["expected_rows"]


@pytest.mark.parametrize("name", FROZEN_NAMES)
def test_expected_is_what_pylance_reads_back(manifest, opened, fixtures_root, name):
    """The reference is generated, never hand-written: re-derive and compare."""
    rows, encodings = gen.encode_table(opened(name).to_table())
    on_disk = "".join(expected_lines(fixtures_root, name))
    assert gen.dump_expected(rows) == on_disk
    for col in entry(manifest, name)["schema"]:
        assert encodings[col["name"]] == col["expected_encoding"], col["name"]


@pytest.mark.parametrize("name", FROZEN_NAMES)
def test_expected_rows_are_objects_in_schema_order(manifest, fixtures_root, name):
    order = [c["name"] for c in entry(manifest, name)["schema"]]
    for line in expected_lines(fixtures_root, name):
        row = json.loads(line)
        assert list(row) == order


@pytest.mark.parametrize("name", FROZEN_NAMES)
def test_expected_ids_ascend(manifest, fixtures_root, name):
    """SQL cases order by id; the reference must already be in that order."""
    if entry(manifest, name)["schema"][0]["name"] != "id":
        pytest.skip("%s has no id column" % name)
    ids = [json.loads(line)["id"] for line in expected_lines(fixtures_root, name)]
    assert ids == sorted(ids)
    assert len(set(ids)) == len(ids)


# --------------------------------------------------------------------------
# per-dataset properties the later packages rely on
# --------------------------------------------------------------------------

def test_types_all_covers_every_a_tier_arrow_type(manifest, opened):
    present = {str(f.type) for f in opened("types_all").schema}
    missing = [str(t) for t in A_TIER_TYPES if str(t) not in present]
    assert not missing, "types_all lost A-tier dimensions: %s" % missing
    assert all(c["tier"] == "A" for c in entry(manifest, "types_all")["schema"])


def test_types_all_has_nulls_and_out_of_range_values(fixtures_root, manifest):
    rows = [json.loads(line) for line in expected_lines(fixtures_root, "types_all")]
    for col in entry(manifest, "types_all")["schema"]:
        name = col["name"]
        values = [r[name] for r in rows]
        if name == "id":
            assert None not in values
            continue
        assert None in values, "%s has no NULL" % name
        assert any(v is not None for v in values), "%s is all NULL" % name
    # P3 needs values that do not fit the narrower PG types (I7).
    assert 9223372036854775807 in [r["c_int64"] for r in rows]
    assert -9223372036854775808 in [r["c_int64"] for r in rows]
    assert any(v is not None and len(v.split(".")[0].lstrip("-")) > 5
               for v in [r["c_dec128_38_10"] for r in rows])
    assert "NaN" in [r["c_float32"] for r in rows]
    assert "Infinity" in [r["c_float32"] for r in rows]


def test_types_b_mixes_b_tier_columns_with_importable_ones(manifest):
    schema = entry(manifest, "types_b")["schema"]
    by_name = {c["name"]: c for c in schema}
    b_tier = [c["name"] for c in schema if c["tier"] == "B"]
    a_tier = [c["name"] for c in schema if c["tier"] == "A"]
    assert a_tier, "IMPORT would fail outright with no A-tier column left"
    for expect in ("c_struct", "c_dict", "c_uint64", "c_list_list"):
        assert expect in b_tier, expect
    assert all(by_name[n]["pg_type"] is None for n in b_tier)


def test_deleted_hides_exactly_the_deleted_rows(manifest, fixtures_root):
    ids = [json.loads(line)["id"] for line in expected_lines(fixtures_root, "deleted")]
    assert ids == [i for i in range(20) if i not in DELETED_IDS]
    e = entry(manifest, "deleted")
    assert e["fragments_with_deletion_file"] == [0, 2, 3]
    assert e["fragment_rows"] != e["fragment_physical_rows"]


def test_frag_gap_has_non_contiguous_fragment_ids(manifest):
    e = entry(manifest, "frag_gap")
    ids = e["fragment_ids"]
    assert ids == sorted(ids)
    assert ids[-1] - ids[0] + 1 > len(ids), "no gap in %r" % ids


def test_frag_datasets_have_the_advertised_fragment_counts(manifest):
    for name in ("frag_1", "frag_2", "frag_3", "frag_7", "frag_100"):
        e = entry(manifest, name)
        assert e["fragments"] == int(name.split("_")[1])
        assert len(set(e["fragment_rows"])) == 1, "fragments must be even-sized"


def test_empty_dataset_has_a_schema_but_no_rows(manifest, opened, fixtures_root):
    e = entry(manifest, "empty")
    assert (e["rows"], e["fragments"]) == (0, 0)
    assert e["schema"]
    assert expected_lines(fixtures_root, "empty") == []
    assert opened("empty").to_table().num_rows == 0


def test_evolved_spreads_columns_over_several_data_files(manifest):
    e = entry(manifest, "evolved")
    assert min(e["data_files_per_fragment"]) >= 2
    assert [c["name"] for c in e["schema"]] == ["id", "v", "n", "v10", "vup"]


def test_versions_are_append_only_prefixes(manifest, fixtures_root):
    e = entry(manifest, "versions")
    assert [v["rows"] for v in e["history"]] == [10, 20, 35]
    lines = expected_lines(fixtures_root, "versions")
    for v in e["history"]:
        ds = lance.dataset(dataset_path("versions"), version=v["version"])
        rows, _ = gen.encode_table(ds.to_table())
        assert gen.dump_expected(rows) == "".join(lines[:v["rows"]]), v["version"]


def test_blob_column_keeps_the_lance_blob_encoding(manifest, opened):
    field = opened("blob").schema.field("blob")
    assert field.metadata == {b"lance-encoding": b"blob"}
    col = {c["name"]: c for c in entry(manifest, "blob")["schema"]}["blob"]
    assert col["arrow_type"] == "large_binary"
    assert col["expected_encoding"] == "bytes-digest"


def test_blob_and_large_text_reach_the_advertised_sizes(fixtures_root, manifest):
    blobs = [json.loads(line)["blob"] for line in expected_lines(fixtures_root, "blob")]
    assert max(b["bytes"] for b in blobs if b) >= 1 << 20
    texts = [json.loads(line)["txt"] for line in expected_lines(fixtures_root, "large_text")]
    assert max(t["bytes"] for t in texts if t) >= 1 << 20
    assert any(t and t["bytes"] > t["chars"] for t in texts), "no multi-byte value"
    col = {c["name"]: c for c in entry(manifest, "large_text")["schema"]}
    assert col["txt"]["arrow_type"] == "large_string"
    assert col["small"]["expected_encoding"] == "text", "short column must stay literal"


# --------------------------------------------------------------------------
# the generator itself
# --------------------------------------------------------------------------

def test_regeneration_is_byte_identical(manifest, fixtures_root, regenerated):
    other_root, other = regenerated
    for name in other["datasets"]:
        mine = json.dumps(entry(manifest, name), sort_keys=True)
        theirs = json.dumps(json.loads(gen.dumps_manifest(other["datasets"][name])),
                            sort_keys=True)
        assert mine == theirs, "manifest entry for %s is not reproducible" % name
        expected = entry(manifest, name)["expected"]
        if expected:
            with open(os.path.join(fixtures_root, expected), "rb") as fh:
                mine_bytes = fh.read()
            with open(os.path.join(other_root, expected), "rb") as fh:
                theirs_bytes = fh.read()
            assert mine_bytes == theirs_bytes, "%s is not reproducible" % expected


def test_generator_can_build_the_big_dataset(tmp_path):
    """'big' is opt-in and huge; exercise its code path at 1/100000 the size."""
    m = gen.generate(str(tmp_path), names=["big"], with_big=True,
                     big_shape=(3, 4, 1024))
    e = m["datasets"]["big"]
    assert (e["rows"], e["fragments"]) == (12, 3)
    assert e["expected"] is None and e["expected_rows"] is None
    assert not os.path.exists(os.path.join(str(tmp_path), "expected", "big.jsonl"))
    ds = lance.dataset(os.path.join(str(tmp_path), "data", "big.lance"))
    assert ds.count_rows() == 12
    assert len(set(ds.to_table().column("payload").to_pylist())) == 12


def test_generator_regenerates_a_subset_without_dropping_the_others(tmp_path):
    gen.generate(str(tmp_path), names=["frag_1", "frag_2"])
    first = json.load(open(os.path.join(str(tmp_path), "manifest.json")))
    assert list(first["datasets"]) == ["frag_1", "frag_2"]
    gen.generate(str(tmp_path), names=["frag_3"])
    second = json.load(open(os.path.join(str(tmp_path), "manifest.json")))
    assert list(second["datasets"]) == ["frag_1", "frag_2", "frag_3"]
    assert second["datasets"]["frag_1"] == first["datasets"]["frag_1"]


def test_classify_follows_the_design_type_table():
    assert gen.classify(pa.int32()) == ("A", "integer")
    assert gen.classify(pa.uint32()) == ("A", "bigint")
    assert gen.classify(pa.timestamp("ns", tz="Asia/Shanghai")) == ("A", "timestamptz(6)")
    assert gen.classify(pa.timestamp("ns")) == ("A", "timestamp(6)")
    assert gen.classify(pa.decimal128(10, 2)) == ("A", "numeric(10,2)")
    assert gen.classify(pa.list_(pa.float32(), 4)) == ("A", "real[]")
    assert gen.classify(pa.list_(pa.string())) == ("A", "text[]")
    # B tier: DESIGN §2 keeps these out of the first block.
    for t in (pa.uint64(), pa.struct([("a", pa.int32())]),
              pa.map_(pa.string(), pa.int32()),
              pa.dictionary(pa.int32(), pa.string()),
              pa.list_(pa.list_(pa.int64())), pa.duration("us"),
              pa.month_day_nano_interval(), pa.list_(pa.int32(), 2)):
        assert gen.classify(t) == ("B", None), t


def test_timestamp_encoding_is_utc_iso8601():
    assert gen._iso_timestamp(0, "s", None) == "1970-01-01T00:00:00"
    assert gen._iso_timestamp(0, "us", "UTC") == "1970-01-01T00:00:00.000000Z"
    assert gen._iso_timestamp(-1, "ns", None) == "1969-12-31T23:59:59.999999999"
    assert gen._iso_timestamp(1, "ms", "Asia/Shanghai") == "1970-01-01T00:00:00.001Z"
    assert gen._decimal_string(Decimal("0E-10")) == "0.0000000000"
