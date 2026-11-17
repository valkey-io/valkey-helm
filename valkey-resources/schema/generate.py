# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml"]
# ///
"""Generate the cluster.spec part of values.schema.json from the pinned CRD.

Usage:
    uv run valkey-resources/schema/generate.py [--check] [--chart-dir PATH]

Without --check the script rewrites <chart-dir>/values.schema.json. With --check
it exits 1 when the committed file differs from what would be generated.
"""

import argparse
import copy
import json
import re
import sys
from pathlib import Path

import yaml

CRD_NAME = "valkey.io_valkeyclusters.yaml"

# Paths whose content the chart passes through unvalidated. Dotted, with no
# segment for array items.
OPEN_PATHS: frozenset[str] = frozenset(
    {
        "resources",
        "containers",
        "imagePullSecrets",
        "podSecurityContext",
        "exporter.resources",
        "exporter.securityContext",
        "scheduling.affinity",
        "scheduling.tolerations",
        "scheduling.topologySpreadConstraints",
        "scheduling.nodeSelector",
        "podMetadata.labels",
        "podMetadata.annotations",
        "config",
    }
)

# Deprecated paths where only the top-level key has to be documented.
SHALLOW_DOC_PATHS: frozenset[str] = frozenset({"users"})

SPEC_DESCRIPTION = (
    "ValkeyCluster.spec. Unknown keys are rejected: put fields this chart does "
    "not cover in cluster.additionalSpec."
)


class UnclassifiedFieldError(Exception):
    """A CRD field the generator has no rule for."""


def _nullable(*types: str) -> list[str]:
    return [*types, "null"]


def _describe(node: dict, out: dict) -> dict:
    if "description" in node:
        out["description"] = node["description"]
    return out


def convert(node: dict, path: str) -> dict:
    if path in OPEN_PATHS:
        return _describe(node, {"type": _nullable(node.get("type", "object"))})

    if node.get("x-kubernetes-int-or-string"):
        return _describe(node, {"type": _nullable("integer", "string")})

    kind = node.get("type")

    if kind == "object":
        if "additionalProperties" in node or node.get("x-kubernetes-preserve-unknown-fields"):
            raise UnclassifiedFieldError(
                f"{path}: map or preserve-unknown-fields object is not in OPEN_PATHS"
            )
        out = _describe(node, {"type": _nullable("object")})
        if "properties" in node:
            out["properties"] = {
                name: convert(child, f"{path}.{name}" if path else name)
                for name, child in node["properties"].items()
            }
        out["additionalProperties"] = False
        if "required" in node:
            out["required"] = list(node["required"])
        return out

    if kind == "array":
        out = _describe(node, {"type": _nullable("array")})
        if "items" in node:
            out["items"] = convert(node["items"], path)
        return out

    if kind is None:
        raise UnclassifiedFieldError(f"{path}: node has no type")

    out = _describe(node, {"type": _nullable(kind)})
    for key in ("minimum", "maximum"):
        if key in node:
            out[key] = node[key]
    if "enum" in node:
        out["enum"] = [*node["enum"], None]
    return out


def build_spec_schema(crd: dict) -> dict:
    root = crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]
    schema = convert(root, "")
    schema["required"] = ["shards"]
    schema["description"] = SPEC_DESCRIPTION
    return schema


def render_schema(crd: dict, schema: dict) -> str:
    result = copy.deepcopy(schema)
    result["properties"]["cluster"]["properties"]["spec"] = build_spec_schema(crd)
    return json.dumps(result, indent=2) + "\n"


def required_doc_paths(crd: dict) -> set[str]:
    """Dotted paths values.yaml must document under cluster.spec."""
    root = crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]
    found: set[str] = set()

    def walk(node: dict, path: str) -> None:
        if node.get("type") == "array" and "items" in node:
            node = node["items"]
        for name, child in node.get("properties", {}).items():
            child_path = f"{path}.{name}" if path else name
            found.add(child_path)
            if child_path not in OPEN_PATHS and child_path not in SHALLOW_DOC_PATHS:
                walk(child, child_path)

    walk(root, "")
    return found


_KEY_LINE = re.compile(r"^(\s*)(- )?([a-z][A-Za-z0-9]*):(\s|$)")


def documented_paths(values_text: str) -> set[str]:
    """Dotted paths documented under cluster.spec, live or commented out.

    A commented-out field is "#", one space, then the YAML line at the
    indentation it would have uncommented.
    """
    lines = values_text.splitlines()
    in_cluster = False
    block: list[str] = []
    collecting = False
    for line in lines:
        if not collecting:
            if re.match(r"^cluster:\s*$", line):
                in_cluster = True
            elif in_cluster and re.match(r"^  spec:\s*$", line):
                collecting = True
            elif in_cluster and re.match(r"^\S", line):
                in_cluster = False
            continue
        if not line.strip():
            continue
        if len(line) - len(line.lstrip(" ")) <= 2:
            break
        block.append(line)

    paths: set[str] = set()
    stack: list[tuple[int, str]] = []
    for line in block:
        column = len(line) - len(line.lstrip(" "))
        text = line.lstrip(" ")
        if text.startswith("#"):
            after = text[1:]
            column += len(after) - len(after.lstrip(" ")) - 1
            text = after.lstrip(" ")
        match = _KEY_LINE.match(text)
        if not match:
            continue
        if match.group(2):
            column += 2
        name = match.group(3)
        while stack and stack[-1][0] >= column:
            stack.pop()
        path = f"{stack[-1][1]}.{name}" if stack else name
        stack.append((column, path))
        paths.add(path)
    return paths


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if values.schema.json is stale")
    parser.add_argument(
        "--chart-dir",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="chart directory (default: valkey-resources/)",
    )
    args = parser.parse_args(argv)

    chart_dir: Path = args.chart_dir
    target = chart_dir / "values.schema.json"
    crd = yaml.safe_load((chart_dir / "schema" / CRD_NAME).read_text())
    expected = render_schema(crd, json.loads(target.read_text()))

    if args.check:
        status = 0
        if target.read_text() != expected:
            print(f"{target} is out of date: run `just schema-resources`")
            status = 1
        missing = required_doc_paths(crd) - documented_paths((chart_dir / "values.yaml").read_text())
        if missing:
            print("values.yaml does not document these cluster.spec paths:")
            for path in sorted(missing):
                print(f"  {path}")
            status = 1
        return status

    target.write_text(expected)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
