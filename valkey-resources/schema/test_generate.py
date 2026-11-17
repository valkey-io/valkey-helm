import json
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).parent))

import generate  # noqa: E402
from generate import (  # noqa: E402
    SPEC_DESCRIPTION,
    UnclassifiedFieldError,
    build_spec_schema,
    main,
    render_schema,
)

CHART_DIR = Path(__file__).resolve().parent.parent
CRD_FILE = CHART_DIR / "schema" / "valkey.io_valkeyclusters.yaml"


def crd(spec_props: dict, required: list[str] | None = None) -> dict:
    spec: dict = {"type": "object", "properties": spec_props}
    if required is not None:
        spec["required"] = required
    return {
        "spec": {
            "versions": [
                {
                    "schema": {
                        "openAPIV3Schema": {"type": "object", "properties": {"spec": spec}}
                    }
                }
            ]
        }
    }


def test_operator_object_is_strict():
    result = build_spec_schema(
        crd({"persistence": {"type": "object", "properties": {"size": {"type": "string"}}}})
    )
    persistence = result["properties"]["persistence"]
    assert persistence["additionalProperties"] is False
    assert persistence["type"] == ["object", "null"]


def test_open_path_is_unconstrained():
    result = build_spec_schema(
        crd(
            {
                "resources": {
                    "type": "object",
                    "description": "compute resources",
                    "properties": {"limits": {"type": "object"}},
                }
            }
        )
    )
    assert result["properties"]["resources"] == {
        "type": ["object", "null"],
        "description": "compute resources",
    }


def test_scalar_allows_null_and_enum_keeps_null():
    result = build_spec_schema(
        crd({"policy": {"type": "string", "enum": ["Retain", "Delete"]}})
    )
    policy = result["properties"]["policy"]
    assert policy["type"] == ["string", "null"]
    assert policy["enum"] == ["Retain", "Delete", None]


def test_int_or_string():
    result = build_spec_schema(
        crd(
            {
                "size": {
                    "x-kubernetes-int-or-string": True,
                    "anyOf": [{"type": "integer"}, {"type": "string"}],
                }
            }
        )
    )
    size = result["properties"]["size"]
    assert size["type"] == ["integer", "string", "null"]
    assert "anyOf" not in size


def test_minimum_and_maximum_carried():
    result = build_spec_schema(
        crd({"n": {"type": "integer", "minimum": 1, "maximum": 9}})
    )
    n = result["properties"]["n"]
    assert n["minimum"] == 1
    assert n["maximum"] == 9


def test_empty_object_is_strict():
    result = build_spec_schema(crd({"perNodeServices": {"type": "object"}}))
    assert result["properties"]["perNodeServices"] == {
        "type": ["object", "null"],
        "additionalProperties": False,
    }


def test_unclassified_map_raises():
    with pytest.raises(UnclassifiedFieldError, match="labels"):
        build_spec_schema(
            crd({"labels": {"type": "object", "additionalProperties": {"type": "string"}}})
        )


def test_preserve_unknown_fields_raises():
    with pytest.raises(UnclassifiedFieldError, match="blob"):
        build_spec_schema(
            crd({"blob": {"type": "object", "x-kubernetes-preserve-unknown-fields": True}})
        )


def test_top_level_required_is_shards_and_description_fixed():
    result = build_spec_schema(crd({"shards": {"type": "integer"}}, required=["shards", "other"]))
    assert result["required"] == ["shards"]
    assert result["additionalProperties"] is False
    assert result["description"] == SPEC_DESCRIPTION


def test_real_crd_builds():
    real = yaml.safe_load(CRD_FILE.read_text())
    result = build_spec_schema(real)
    assert "replicasPerShard" not in result["required"]


def test_check_detects_drift(tmp_path, capsys):
    real = yaml.safe_load(CRD_FILE.read_text())
    (tmp_path / "schema").mkdir()
    (tmp_path / "schema" / CRD_FILE.name).write_text(CRD_FILE.read_text())
    base = json.loads((CHART_DIR / "values.schema.json").read_text())
    fresh = render_schema(real, base)
    stale = json.loads(fresh)
    stale["properties"]["cluster"]["properties"]["spec"]["description"] = "stale"
    assert fresh != json.dumps(stale, indent=2) + "\n"

    target = tmp_path / "values.schema.json"
    target.write_text(json.dumps(stale, indent=2) + "\n")
    assert main(["--check", "--chart-dir", str(tmp_path)]) == 1
    assert "values.schema.json" in capsys.readouterr().out

    assert main(["--chart-dir", str(tmp_path)]) == 0
    assert target.read_text() == fresh
    assert main(["--check", "--chart-dir", str(tmp_path)]) == 0
    assert generate.OPEN_PATHS
