"""esm-spec §9.6.4 rules 1 and 7, §10.7: mounted template registries.

A mounted leaf keeps its template references; its definitions join the
registry of the top-level component it is mounted under, in the leaf's OWN
names, and a body's free names are read in the scope of the subsystem that
owns the reference. An authored subsystem with its own block joins the same
way. Flatten closes every body (its free names become trailing parameters),
and the registry merge keeps one entry per distinct definition.

Drives ``tests/conformance/expression_templates/mount_registry_merge/`` and
``mount_shared_definition/`` against their goldens (written by the Julia
reference, compared byte for byte), and checks that each subsystem's expanded
equations read that subsystem's own names, by value.
"""

from __future__ import annotations

import json
import warnings

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import flatten, load_path
from earthsci_ast.lower_expression_templates import emit_document, emit_esm_string
from earthsci_ast.simulation_array import evaluate_rhs

DIR = CONFORMANCE_DIR / "expression_templates"


def _p(case: str, name: str) -> str:
    return str(DIR / case / name)


def _golden(case: str, name: str) -> str:
    return (DIR / case / name).read_text(encoding="utf-8")


def _block(reg: dict) -> str:
    return emit_esm_string({"expression_templates": reg})


def _flat(path: str) -> str:
    return _block(flatten(load_path(path)).template_registry)


def _loaded(path: str) -> str:
    return _block(load_path(path).component_templates["models.Host"])


def _du(path: str) -> dict[str, float]:
    """The right-hand side at the declared initial state, t = 0.3."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        flat = flatten(load_path(path))
    state = {n: float(v.default) for n, v in flat.state_variables.items()}
    return evaluate_rhs(flat, state, 0.3)


class TestMountRegistryMerge:
    case = "mount_registry_merge"

    def test_flattened_registry(self):
        assert _flat(_p(self.case, "fixture.esm")) == _golden(self.case, "flattened_registry.esm")

    def test_inline_flattened_registry(self):
        assert _flat(_p(self.case, "inline_form.esm")) == _golden(
            self.case, "inline_flattened_registry.esm"
        )

    def test_loaded_registry(self):
        assert _loaded(_p(self.case, "fixture.esm")) == _golden(self.case, "loaded_registry.esm")

    def test_inline_emitted(self):
        p = DIR / self.case / "inline_form.esm"
        raw = json.loads(p.read_text(encoding="utf-8"))
        emitted = emit_esm_string(emit_document(raw, str(p.parent)))
        assert emitted == _golden(self.case, "inline_emitted.esm")

    @pytest.mark.parametrize("name", ["fixture.esm", "inline_form.esm"])
    def test_subsystem_reads_its_own_names(self, name):
        du = _du(_p(self.case, name))
        # Sub's `rate` reads Sub's `k` (0.25) through Sub's `scale` (3x).
        assert du["Host.Sub.c"] == -(0.25 * 3.0 * 1.0)
        assert du["Host.y"] == -(2.0 * 1.0)
        assert du["Host.Inner.w"] == -(2.0 * 3.0)
        assert du["Host.z"] == -(2.0 / 2)


class TestMountSharedDefinition:
    case = "mount_shared_definition"

    def test_flattened_registry(self):
        assert _flat(_p(self.case, "fixture.esm")) == _golden(self.case, "flattened_registry.esm")

    def test_loaded_registry(self):
        assert _loaded(_p(self.case, "fixture.esm")) == _golden(self.case, "loaded_registry.esm")

    def test_one_definition_per_leaf_template(self):
        reg = load_path(_p(self.case, "fixture.esm")).component_templates["models.Host"]
        assert sorted(reg) == ["Host.rate", "Sub1.rate", "loss", "pull"]
        assert reg["Sub1.rate"]["body"] == {"op": "*", "args": ["k", "x"]}

    def test_expanded_equations_read_each_subsystem_names(self):
        """Expand substitutes each body into the subsystem that owns the
        reference: Sub1's equations read Sub1's `k`, Inner's read Inner's `g`."""
        from earthsci_ast.serialize import _serialize_expression

        host = load_path(_p(self.case, "fixture.esm")).models["Host"]
        sub1 = json.dumps(
            [_serialize_expression(eq.rhs) for eq in host.subsystems["Sub1"].equations]
        )
        assert '"k"' in sub1
        inner = json.dumps(
            [_serialize_expression(eq.rhs) for eq in host.subsystems["Inner"].equations]
        )
        assert '"g"' in inner
        flat = flatten(load_path(_p(self.case, "fixture.esm")))
        rendered = {
            str(eq.lhs.args[0]) if hasattr(eq.lhs, "args") else str(eq.lhs): json.dumps(
                _serialize_expression(eq.rhs)
            )
            for eq in flat.equations
        }
        assert "Host.Sub1.k" in rendered["Host.Sub1.c"]
        assert "Host.Inner.g" in rendered["Host.Inner.w"]
        assert '"Host.g"' in rendered["Host.z"]

    def test_values(self):
        du = _du(_p(self.case, "fixture.esm"))
        assert du["Host.Sub1.c"] == -0.25
        assert du["Host.Sub2.c"] == -2.0
        assert du["Host.Sub1.d"] == -0.0625
        assert du["Host.Sub2.d"] == -0.5
        assert du["Host.y"] == -2.0
        assert du["Host.z"] == -1.0
        assert du["Host.Inner.w"] == -9.0


class TestMountHostRule:
    """esm-spec §9.6.3: a `match` rule of the mounting component fires on the
    content of the models it mounts, at any depth (Sub, Sub's own mount Deep,
    and Bare, which declares no templates)."""

    case = "mount_host_rule"

    def test_loaded_registry(self):
        assert _loaded(_p(self.case, "fixture.esm")) == _golden(self.case, "loaded_registry.esm")

    def test_flattened_registry(self):
        assert _flat(_p(self.case, "fixture.esm")) == _golden(self.case, "flattened_registry.esm")

    def test_expanded(self):
        from earthsci_ast.serialize import _serialize_esm_file

        got = _serialize_esm_file(load_path(_p(self.case, "fixture.esm")))
        assert got == json.loads(_golden(self.case, "expanded.esm"))

    def test_values(self):
        du = _du(_p(self.case, "fixture.esm"))
        assert du["Host.y"] == -(1.5**3)
        assert du["Host.Sub.c"] == -1.0
        assert du["Host.Sub.d"] == -1.0
        assert du["Host.Sub.e"] == -(0.25 * 2.0**3)
        assert du["Host.Sub.Deep.h"] == -(2 * 0.5**3)
        assert du["Host.Bare.g"] == -(3.0**3)

    def test_leaf_rule_fires_in_its_mount_under_a_host_without_rules(self, tmp_path):
        """The leaf's own rule `twice` fires on Deep's content when the leaf is
        mounted under a component that declares no rule."""
        from earthsci_ast.serialize import _serialize_expression

        doc = {
            "esm": "2.0.0",
            "metadata": {"name": "plain_host"},
            "models": {
                "Top": {
                    "variables": {"q": {"type": "unknown", "units": "1", "default": 1.0}},
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["q"], "wrt": "t"},
                            "rhs": {"op": "-", "args": ["q"]},
                        }
                    ],
                    "subsystems": {"Sub": {"ref": _p(self.case, "leaf.esm")}},
                }
            },
        }
        p = tmp_path / "top.esm"
        p.write_text(json.dumps(doc), encoding="utf-8")
        deep = load_path(str(p)).models["Top"].subsystems["Sub"].subsystems["Deep"]
        assert _serialize_expression(deep.equations[0].rhs) == {
            "op": "-",
            "args": [
                {"op": "+", "args": [{"op": "cub", "args": ["h"]}, {"op": "cub", "args": ["h"]}]}
            ],
        }


class TestFlattenClosesJoinNames:
    """esm-spec §10.7: a body's `join` clauses name component variables it reads
    nowhere else (an overlap gate's envelope factors, an `on` clause's key
    columns); closing makes them parameters like the body's variable leaves."""

    case = "flatten_closes_join_names"

    def test_flattened_registry(self):
        assert _flat(_p(self.case, "fixture.esm")) == _golden(self.case, "flattened_registry.esm")
