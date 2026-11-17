import json
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).parent))

import generate  # noqa: E402
from generate import (  # noqa: E402
    OPEN_PATHS,
    SPEC_DESCRIPTION,
    UnclassifiedFieldError,
    build_spec_schema,
    documented_paths,
    main,
    render_schema,
    required_doc_paths,
    stale_doc_paths,
)

CHART_DIR = Path(__file__).resolve().parent.parent
CRD_FILE = CHART_DIR / "schema" / "valkey.io_valkeyclusters.yaml"


def crd(
    spec_props: dict, required: list[str] | None = None, version: str = "v1alpha1"
) -> dict:
    spec: dict = {"type": "object", "properties": spec_props}
    if required is not None:
        spec["required"] = required
    return {
        "spec": {
            "versions": [
                {
                    "name": version,
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
    (tmp_path / "values.yaml").write_text((CHART_DIR / "values.yaml").read_text())
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


def test_documented_paths_reads_live_and_commented_keys():
    text = (
        "cluster:\n"
        "  spec:\n"
        "    shards: 3\n"
        "    # persistence:\n"
        "    #   size: 1Gi\n"
        "    # acl:\n"
        "    #   users:\n"
        "    #     - name: alice\n"
        '    #       permissions: "+@all"\n'
        "  additionalSpec: {}\n"
    )
    assert documented_paths(text) == {
        "shards",
        "persistence",
        "persistence.size",
        "acl",
        "acl.users",
        "acl.users.name",
        "acl.users.permissions",
    }


def test_documented_paths_ignores_prose_and_other_blocks():
    text = (
        "metrics:\n"
        "  podMonitor:\n"
        "    port: metrics\n"
        "cluster:\n"
        "  spec:\n"
        "    # Example: something\n"
        "    # Sizes are in bytes. See: the docs\n"
        "    shards: 3\n"
        "  additionalSpec: {}\n"
        "serviceAccount:\n"
        "  create: false\n"
    )
    assert documented_paths(text) == {"shards"}


def test_required_doc_paths_stops_at_open_and_shallow_paths():
    paths = required_doc_paths(yaml.safe_load(CRD_FILE.read_text()))
    assert {"scheduling.affinity", "users", "acl.users.password.secret.name"} <= paths
    for prefix in ("scheduling.affinity.", "resources.", "users."):
        assert not any(p.startswith(prefix) for p in paths)


def test_check_reports_undocumented_paths(tmp_path, capsys):
    (tmp_path / "schema").mkdir()
    (tmp_path / "schema" / CRD_FILE.name).write_text(CRD_FILE.read_text())
    (tmp_path / "values.schema.json").write_text((CHART_DIR / "values.schema.json").read_text())
    lines = (CHART_DIR / "values.yaml").read_text().splitlines(keepends=True)
    kept = [line for line in lines if line.strip() != "#   size: 1Gi"]
    assert len(kept) < len(lines)
    (tmp_path / "values.yaml").write_text("".join(kept))
    assert main(["--check", "--chart-dir", str(tmp_path)]) == 1
    assert "persistence.size" in capsys.readouterr().out


def test_builds_from_v1alpha1_when_another_version_is_listed_first():
    v1beta1 = crd({"replicas": {"type": "integer"}}, version="v1beta1")["spec"]["versions"][0]
    v1alpha1 = crd({"users": {"type": "string"}}, version="v1alpha1")["spec"]["versions"][0]
    fake = {"spec": {"versions": [v1beta1, v1alpha1]}}
    result = build_spec_schema(fake)
    assert set(result["properties"]) == {"users"}
    assert required_doc_paths(fake) == {"users"}


def test_missing_v1alpha1_raises():
    with pytest.raises(ValueError, match="v1alpha1"):
        build_spec_schema(crd({"a": {"type": "string"}}, version="v1beta1"))
    with pytest.raises(ValueError, match="v1alpha1"):
        required_doc_paths(crd({"a": {"type": "string"}}, version="v1beta1"))


def _field(node: dict, path: str) -> dict:
    for name in path.split("."):
        if node.get("type") == "array":
            node = node["items"]
        node = node["properties"][name]
    return node


@pytest.mark.parametrize("path", sorted(OPEN_PATHS))
def test_open_paths_resolve_in_the_real_crd(path):
    root = generate.spec_root(yaml.safe_load(CRD_FILE.read_text()))
    assert _field(root, path)


def test_stale_doc_paths_skips_paths_below_open_and_shallow_paths():
    required = {"shards", "resources", "users"}
    documented = {"shards", "old", "resources.limits", "users.name", "old.child"}
    assert stale_doc_paths(required, documented) == {"old", "old.child"}


def test_check_reports_stale_documentation(tmp_path, capsys):
    (tmp_path / "schema").mkdir()
    (tmp_path / "schema" / CRD_FILE.name).write_text(CRD_FILE.read_text())
    (tmp_path / "values.schema.json").write_text((CHART_DIR / "values.schema.json").read_text())
    text = (CHART_DIR / "values.yaml").read_text()
    anchor = "    # workloadType: StatefulSet\n"
    assert anchor in text
    (tmp_path / "values.yaml").write_text(text.replace(anchor, anchor + "    # removedField: 1\n"))
    assert main(["--check", "--chart-dir", str(tmp_path)]) == 1
    assert "removedField" in capsys.readouterr().out
