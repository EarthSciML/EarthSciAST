"""Generic, GDD-driven spatial (method-of-lines) discretization — the Python
"PDE-op scan" deferred by :mod:`earthsci_toolkit.discretize`, mirroring the
Julia Path-A pipeline (ESD ``build_ode_problem`` → ``EarthSciSerialization.discretize``).

Design principle (no per-rule code): a **Grid Discretization Descriptor** maps
each spatial operator to a catalog rule —

    {"discretizations": {"grad": {<rule>}, "d2": {<rule>}, ...},
     "grids": {<domain>: {"spatial": {<dim>: {"grid_spacing": ...}}}}}

The pass walks every equation (state PDE *and* observed, e.g.
``psi_x = grad(psi, x)``) and, for each spatial-operator node, applies the
*GDD-selected* rule via :func:`earthsci_toolkit.rule_engine.rewrite`. Selection
is data, not code: adding a stencil to the catalog and naming it in a GDD is
sufficient — no edit here. There is no operator special-casing (no ``grad_norm``
/ Godunov branch); a level-set ``|∇ψ|`` discretizes because its component factors
into ``grad`` observeds, and whatever ``grad`` rule the GDD selects (centered,
``upwind_1st``, …) is applied to each.

Scope of this module: Cartesian uniform grids; ``grad`` / ``d2`` (atomic) and
``laplacian`` (expanded to per-dimension ``d2``).

Boundary conditions are lowered **declaratively**, at parity with the Julia
reference (``EarthSciSerialization.jl/src/discretize.jl``): each model BC is
wrapped as a synthetic ``bc(variable, …)`` op (``kind``→``fn``, ``side``→``dim``,
Robin coefficients as trailing args) and run through the **shared rule engine**
(:func:`earthsci_toolkit.rule_engine.rewrite`) against the ESD
``{dirichlet,neumann,robin}_bc.json`` ghost rules — sourced from the document's
own ``rules`` (same input Julia consumes) with the canonical finite-difference
ghosts bundled as defaults. The rewritten ghost AST is spliced into ``makearray``
boundary regions (``_apply_makearray_bcs`` / ``_reindex_ghost`` /
``_instantiate_bc_cell_ghost``), mirroring Julia's ``_apply_makearray_bcs!``. All
kinds dirichlet / neumann / zero_gradient / robin / interface / periodic flow
through this one generic path (2-D corners fall out as multiply-bounded cells);
there is **no per-kind imperative BC physics** in this module. Non-uniform /
curvilinear grids remain follow-ups (the Julia binding covers them).
"""

from __future__ import annotations

import copy
import itertools
import json
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from dataclasses import replace

from .rule_engine import (
    parse_rule, rewrite, _parse_expr, RuleContext, _SIDE_TO_AXIS_IDX,
)
from .canonicalize import canonicalize
from .esm_types import ExprNode


class SpatialDiscretizeError(Exception):
    """Raised when a PDE component cannot be discretized under the given GDD."""


def flattened_to_esm(flat: Any, domains: Dict[str, Any],
                     name: str = "Flattened",
                     boundary_conditions: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Adapt a :class:`FlattenedSystem` (the output of ``earthsci_toolkit.flatten``)
    into a single-model ``.esm`` dict that :func:`spatial_discretize` consumes.

    This is the join between coupling resolution and discretization: ``flatten``
    resolves ``param_to_var`` and other coupling (e.g. a 0-D Rothermel spread
    rate substituted into the level-set's ``R_0``); this adapter exposes the
    resolved equation set on the PDE domain so the spatial pass can lower it.
    ``domains`` is the coupled file's ``domains`` block (re-used verbatim).
    ``boundary_conditions`` carries the PDE model's BCs (``flatten`` does not
    preserve them); without them the spatial pass falls back to Dirichlet
    defaults and mis-sizes the grid.
    """
    # Loader fields (data-loader-fed observed arrays, e.g. "ERA5.pl.u") need
    # special handling: flatten records them in BOTH observed_variables (no
    # defining equation) and loader_fields. Emitting them as plain observeds
    # produces schema-invalid `observed`-without-expression vars AND drops the
    # loader semantics, so a discretized system can no longer be loader-driven.
    # Instead re-mount each loader as an inline data-loader subsystem on the
    # output model and rewrite its references "<owner>.<subkey>.<var>" ->
    # "<owner>_<subkey>.<var>" (a local subsystem ref); re-flattening the emitted
    # esm then re-creates the LoaderField descriptors so simulate()'s provider
    # path can fill them.
    from .serialize import _serialize_data_loader

    loader_fields = list(getattr(flat, "loader_fields", []) or [])
    loader_names = {lf.name for lf in loader_fields}
    loader_rename: Dict[str, str] = {}
    loader_groups: Dict[str, Tuple[Any, set]] = {}
    for lf in loader_fields:
        subkey = f"{lf.owner}.{lf.subkey}".replace(".", "_")
        # Reference the loader by the name re-flatten will give it once mounted
        # as subsystem `subkey` on this single model `name`: "<name>.<subkey>.<var>".
        # flatten does not re-namespace symbols inside the lowered makearray, so
        # the equation reference must already carry the model prefix to match the
        # re-created LoaderField (else simulate raises "Unresolved symbol").
        loader_rename[lf.name] = f"{name}.{subkey}.{lf.var}"
        loader_groups.setdefault(subkey, (lf.loader, set()))[1].add(lf.var)
    loader_subsystems: Dict[str, Any] = {}
    for subkey, (loader_obj, used_vars) in loader_groups.items():
        dl = _serialize_data_loader(loader_obj)
        # keep only the variables actually consumed (avoids re-creating unused
        # loader fields the provider would needlessly try to execute)
        dl["variables"] = {v: spec for v, spec in dl.get("variables", {}).items()
                           if v in used_vars}
        loader_subsystems[subkey] = dl

    # Carry each loader field's per-variable regrid spec onto the re-created
    # model's `regrid` block (keyed by loader var). Re-flatten re-attaches it via
    # ``model.regrid.get(var)``; without it the discretized loaders lose their
    # regrid method and bind at NATIVE resolution (a LANDFIRE GeoTIFF is millions
    # of cells, ERA5 is 17x13) → shape mismatch against the model grid. This is
    # the regrid analog of carrying the loader fields through discretization.
    loader_regrid: Dict[str, Any] = {}
    for lf in loader_fields:
        spec = getattr(lf, "regrid", None)
        if spec is None or getattr(spec, "method", None) is None:
            continue
        entry: Dict[str, Any] = {"method": spec.method}
        if getattr(spec, "missing_value", None) is not None:
            entry["missing_value"] = spec.missing_value
        if getattr(spec, "description", None):
            entry["description"] = spec.description
        loader_regrid[lf.var] = entry

    # flatten() dot-namespaces names (e.g. "LevelSet.psi"); a dot in an array
    # state name breaks simulate()'s element expansion, so sanitize "." -> "_"
    # consistently across variable declarations and equation references. Loader
    # names are excluded here — they keep their dotted "<subkey>.<var>" form
    # (handled by loader_rename) so re-flatten re-mounts them as loader fields.
    rename = {n: n.replace(".", "_")
              for n in (*flat.state_variables, *flat.observed_variables, *flat.parameters)
              if n not in loader_names}
    eq_rename = {**rename, **loader_rename}

    def _rename(node):
        return _map_expr(node, lambda x: eq_rename.get(x, x) if isinstance(x, str) else x)

    # The `domains` block is reused verbatim below, but its expression-form
    # initial_conditions are written with component-LOCAL variable names (e.g.
    # ``psi``), while flatten namespaced the states (``LevelSetFireSpread.psi``)
    # and this adapter underscore-renames them (``LevelSetFireSpread_psi``).
    # Without remapping, a domain-level expression IC can no longer resolve to
    # its state and simulate() raises "expression initial condition names unknown
    # variable". Map each local (and full) name to its renamed flat name and
    # rewrite the domain ICs to match. Spatial dimension names (x, y, lev) are
    # not in the rename map, so coordinate references in IC expressions are left
    # untouched.
    local_to_renamed: Dict[str, str] = {}
    for full, new in rename.items():
        local_to_renamed.setdefault(full.rsplit(".", 1)[-1], new)
        local_to_renamed[full] = new

    def _rename_local(node):
        return _map_expr(node, lambda x: local_to_renamed.get(x, x) if isinstance(x, str) else x)

    if local_to_renamed:
        domains = copy.deepcopy(domains)
        for dom in domains.values():
            ic = dom.get("initial_conditions") if isinstance(dom, dict) else None
            if isinstance(ic, dict) and isinstance(ic.get("values"), dict):
                ic["values"] = {local_to_renamed.get(k, k): _rename_local(v)
                                for k, v in ic["values"].items()}

    variables: Dict[str, Any] = {}
    for n, v in flat.state_variables.items():
        variables[rename[n]] = {"type": "state", "units": v.units or "1"}
    for n, v in flat.observed_variables.items():
        if n in loader_names:
            continue  # re-mounted as a loader subsystem below, not an observed
        variables[rename[n]] = {"type": "observed", "units": v.units or "1"}
    for n, v in flat.parameters.items():
        variables[rename[n]] = {"type": "parameter", "units": v.units or "1",
                                "default": v.default if v.default is not None else 0.0}
    equations = [{"lhs": _rename(_to_json(e.lhs)), "rhs": _rename(_to_json(e.rhs))}
                 for e in flat.equations]
    model: Dict[str, Any] = {"domain": next(iter(domains)), "system_kind": "pde",
                             "variables": variables, "equations": equations}
    if boundary_conditions:
        model["boundary_conditions"] = boundary_conditions
    if loader_subsystems:
        model["subsystems"] = loader_subsystems
    if loader_regrid:
        model["regrid"] = loader_regrid
    return {
        "esm": "0.5.0", "metadata": {"name": name}, "domains": domains,
        "models": {name: model},
    }


# --- GDD rule resolution (the generic selection mechanism) -------------------
def _resolve_rule(op: str, entry: Any) -> Any:
    """Turn a GDD ``discretizations[op]`` entry into a parsed Rule.

    Accepts an inline rule object (``{applies_to|pattern, replacement, ...}``),
    a single-rule wrapper ``{"discretizations": {name: rule}}``, or a
    ``{"ref": path}`` pointing at an ESD catalog JSON file.
    """
    if isinstance(entry, dict) and "ref" in entry:
        data = json.loads(Path(entry["ref"]).read_text())
        (name, spec), = data["discretizations"].items()
        spec = dict(spec)
    elif isinstance(entry, dict) and "discretizations" in entry:
        (name, spec), = entry["discretizations"].items()
        spec = dict(spec)
    elif isinstance(entry, dict):
        spec, name = dict(entry), op
    else:
        raise SpatialDiscretizeError(f"GDD entry for {op!r} is not a rule")
    if "applies_to" in spec and "pattern" not in spec:
        spec["pattern"] = spec.pop("applies_to")
    return parse_rule(spec, name=name)


def _gdd_rules(gdd: Dict[str, Any]) -> Dict[str, Any]:
    return {op: _resolve_rule(op, entry)
            for op, entry in (gdd.get("discretizations") or {}).items()}


# --- AST plumbing (shared, content-free) -------------------------------------
_CHILD_KEYS = ("args", "values")


def _map_expr(node: Any, fn) -> Any:
    if isinstance(node, dict):
        new = dict(node)
        for k in _CHILD_KEYS:
            if isinstance(new.get(k), list):
                new[k] = [_map_expr(a, fn) for a in new[k]]
        if new.get("expr") is not None:
            new["expr"] = _map_expr(new["expr"], fn)
        return fn(new)
    if isinstance(node, list):
        return [_map_expr(a, fn) for a in node]
    return fn(node)


def _to_json(e: Any) -> Any:
    if isinstance(e, ExprNode):
        d: Dict[str, Any] = {"op": e.op}
        if e.args is not None:
            d["args"] = [_to_json(a) for a in e.args]
        # scalar / list / dict metadata fields carried verbatim
        for f in ("wrt", "dim", "fn", "output_idx", "reduce", "ranges", "regions",
                  "shape", "perm", "axis", "name", "value", "var", "semiring",
                  "distinct", "join", "id", "manifold", "handler_id", "table", "output"):
            v = getattr(e, f, None)
            if v is not None:
                d[f] = v
        # expression-valued fields recurse
        for f in ("expr", "lower", "upper", "filter", "key"):
            v = getattr(e, f, None)
            if v is not None:
                d[f] = _to_json(v)
        if e.values is not None:
            d["values"] = [_to_json(x) for x in e.values]
        if getattr(e, "table_axes", None) is not None:
            d["table_axes"] = {k: _to_json(v) for k, v in e.table_axes.items()}
        return d
    return e


def _subst_symbol(node: Any, name: str, value: Any) -> Any:
    return _map_expr(node, lambda n: value if n == name else n)


def _restore_neg(node: Any) -> Any:
    """Rewrite ``canonicalize``'s internal unary ``neg`` back to the wire op
    ``-`` so the discretized document validates against the schema."""
    return _map_expr(node, lambda n: {"op": "-", "args": n["args"]}
                     if isinstance(n, dict) and n.get("op") == "neg" else n)


def _canon_for_match(node: Any) -> Any:
    """Canonical form used for composite-rule pattern matching.

    Normalizes integer-valued floats to ints (so ``^2.0`` and ``^2`` match) and
    canonicalizes (RFC §5.4 — sorts commutative ``+``/``*`` operands), so a
    composite rule (e.g. the Godunov ``sqrt(grad²+grad²)`` norm) matches the real
    component regardless of exponent representation or operand order. Applied to
    both the expression and the rule pattern, so structural matching aligns.
    """
    nums = _map_expr(node, lambda n: int(n)
                     if isinstance(n, float) and float(n).is_integer() else n)
    return _to_json(canonicalize(_parse_expr(nums)))


def _lift_index_to_nd(body: Any, state: str, dim: str, dims: List[str]) -> Any:
    if len(dims) == 1:
        return body
    pos = dims.index(dim)

    def f(n):
        if (isinstance(n, dict) and n.get("op") == "index"
                and n.get("args") and n["args"][0] == state and len(n["args"]) == 2):
            k = n["args"][1]
            return {"op": "index", "args": [state] + [(k if i == pos else d)
                                                       for i, d in enumerate(dims)]}
        return n
    return _map_expr(body, f)


def _expand_laplacian(expr: Any, dims: List[str]) -> Any:
    def f(n):
        if isinstance(n, dict) and n.get("op") == "laplacian":
            u = n["args"][0]
            terms = [{"op": "d2", "args": [u], "dim": d} for d in dims]
            return terms[0] if len(terms) == 1 else {"op": "+", "args": terms}
        return n
    return _map_expr(expr, f)


_ATOMIC_OPS = ("grad", "d2")


def _apply_gdd_rules(expr: Any, rules: Dict[str, Any], dims: List[str],
                     dx_by_dim: Dict[str, float]) -> Any:
    """Lower spatial operators using the GDD-selected rules.

    Composite rules (GDD keys other than the atomic ``grad`` / ``d2``, e.g. a
    ``grad_norm`` Godunov rule whose ``applies_to`` matches ``sqrt(grad²+grad²)``)
    are applied to the whole expression first via the rule engine — they fire
    wherever their multi-node pattern matches and emit a ready N-D pointwise body
    (uniform-grid ``dx``). Atomic per-dimension rules then lower any remaining
    ``grad`` / ``d2`` nodes (extract the 1-D stencil body and lift it to N-D).
    """
    composite = [r for op, r in rules.items()
                 if op not in _ATOMIC_OPS and op != "laplacian"]
    if composite:
        # canonicalize expr + patterns so 2 vs 2.0 and operand order don't block
        # the multi-node match against the real component form.
        expr = _canon_for_match(expr)
        composite = [replace(r, pattern=_parse_expr(_canon_for_match(_to_json(r.pattern))))
                     for r in composite]
        expr = _to_json(rewrite(_parse_expr(expr), composite))
        # canonicalize emits its internal `neg` for unary minus; restore the
        # wire op `-` so the discretized document validates.
        expr = _restore_neg(expr)
        dxs = set(dx_by_dim.values())
        if len(dxs) > 1:
            raise SpatialDiscretizeError(
                "composite (norm-level) stencil rules assume a uniform grid "
                f"spacing; got {sorted(dxs)}")
        expr = _subst_symbol(expr, "dx", float(next(iter(dxs))))

    atomic = {op: rules[op] for op in _ATOMIC_OPS if op in rules}

    def f(n):
        if not (isinstance(n, dict) and n.get("op") in atomic):
            return n
        op = n["op"]
        operand = n["args"][0]
        if not isinstance(operand, str):
            raise SpatialDiscretizeError(
                f"{op} operand must be a bare field (got {operand!r}); inline a "
                "named observed instead")
        dim = n.get("dim")
        if dim not in dx_by_dim:
            raise SpatialDiscretizeError(f"{op} over unknown spatial dim {dim!r}")
        lowered = rewrite(_parse_expr(n), [atomic[op]])
        if lowered.expr is None:
            raise SpatialDiscretizeError(f"rule for {op!r} did not lower to a body")
        body = _subst_symbol(_to_json(lowered.expr), "dx", float(dx_by_dim[dim]))
        return _lift_index_to_nd(body, operand, dim, dims)
    return _map_expr(expr, f)


# --- boundary conditions -> declarative makearray ghost regions --------------
# Faithful port of the Julia reference (EarthSciSerialization.jl/src/discretize.jl):
# _discretize_bc! (synthetic `bc` wrapper -> shared rule engine -> ghost AST),
# _apply_makearray_bcs! / _reindex_ghost / _instantiate_bc_cell_ghost (splice the
# ghost into makearray boundary regions). No per-kind imperative BC physics lives
# here — the ghost is whatever the ESD `*_bc.json` rules rewrite the `bc` op to.

# v0.1 domain-level BC `type` aliases -> v0.2 `kind`.
_BC_ALIAS = {"zero_gradient": "neumann", "constant": "dirichlet"}
# Sides whose axis index counts from the high (max) end.
_BC_SIDE_MAX = {"xmax", "ymax", "zmax", "east", "north", "top"}
# Robin coefficient fields, appended to the `bc` wrapper in this fixed order so a
# robin rule binds them positionally (`args: [$u, $a, $b, $g]`), matching Julia.
_ROBIN_COEFFS = ("robin_alpha", "robin_beta", "robin_gamma")

# Canonical ESD finite-difference BC ghost rules — the same rule ASTs the Julia
# reference inlines into `esm["rules"]` (mirror ESD's finite_difference/
# {dirichlet,neumann,robin}_bc.json). The ghost is authored in the rule-local
# 0-based frame: `index($u, 0)` = first interior cell; `$h` from
# `bind_side_spacing` (= 1/N). These are declarative rule data, NOT a per-kind
# code table — the shared rule engine interprets them generically. A document's
# own `rules` take precedence (interface and other custom ghosts live there).
_BUNDLED_BC_RULES: List[Dict[str, Any]] = [
    {"name": "dirichlet_bc",
     "pattern": {"op": "bc", "kind": "dirichlet", "side": "$side",
                 "args": ["$u", "$value"]},
     "replacement": {"op": "-", "args": [
         {"op": "*", "args": [2, "$value"]},
         {"op": "index", "args": ["$u", 0]}]}},
    {"name": "neumann_bc",
     "pattern": {"op": "bc", "kind": "neumann", "side": "$side",
                 "args": ["$u", "$value"]},
     "where": [
         {"guard": "var_has_grid", "pvar": "$u", "grid": "$g"},
         {"guard": "bind_side_spacing", "pvar": "$h", "side": "$side", "grid": "$g"}],
     "replacement": {"op": "+", "args": [
         {"op": "index", "args": ["$u", 0]},
         {"op": "*", "args": ["$h", "$value"]}]}},
    {"name": "robin_bc",
     "pattern": {"op": "bc", "kind": "robin", "side": "$side",
                 "args": ["$u", "$a", "$b", "$g"]},
     "where": [
         {"guard": "var_has_grid", "pvar": "$u", "grid": "$gr"},
         {"guard": "bind_side_spacing", "pvar": "$h", "side": "$side", "grid": "$gr"}],
     "replacement": {"op": "/", "args": [
         {"op": "+", "args": [
             {"op": "*", "args": [{"op": "*", "args": [2, "$h"]}, "$g"]},
             {"op": "*", "args": [
                 {"op": "-", "args": [{"op": "*", "args": [2, "$b"]},
                                     {"op": "*", "args": ["$a", "$h"]}]},
                 {"op": "index", "args": ["$u", 0]}]}]},
         {"op": "+", "args": [{"op": "*", "args": ["$a", "$h"]},
                             {"op": "*", "args": [2, "$b"]}]}]}},
]


def _bc_rules(esm: Dict[str, Any]) -> List[Any]:
    """Parse the BC ghost rules consumed by :func:`_discretize_bc`.

    Sources, in match order: every ``bc``-pattern rule the document declares in
    its own top-level ``rules`` (the same input Julia consumes — e.g. interface
    rules), then the bundled canonical finite-difference ghosts. First match
    wins, so a document rule overrides a bundled default of the same kind/side.
    """
    out: List[Any] = []
    for spec in esm.get("rules") or []:
        pat = spec.get("pattern") or spec.get("applies_to") if isinstance(spec, dict) else None
        if isinstance(pat, dict) and pat.get("op") == "bc":
            s = dict(spec)
            if "applies_to" in s and "pattern" not in s:
                s["pattern"] = s.pop("applies_to")
            out.append(parse_rule(s, name=str(s.get("name", "bc_rule"))))
    for spec in _BUNDLED_BC_RULES:
        out.append(parse_rule(dict(spec), name=str(spec["name"])))
    return out


def _periodic_dims(domain: Dict[str, Any], dims: List[str]) -> set:
    spatial = domain.get("spatial") or {}
    return {d for d in dims if (spatial.get(d) or {}).get("periodic")}


def _bc_rule_ctx(grid_name: str, dims: List[str], dim_sizes: Dict[str, int],
                 periodic: set, model: Dict[str, Any]) -> RuleContext:
    """Build the rule-engine context the BC ghost rules need: grid metadata for
    ``bind_side_spacing`` / ``bind_side_dim_size`` (1/N and N keyed off the side's
    axis index), and per-variable ``grid`` / ``shape`` for ``var_has_grid``."""
    grids = {grid_name: {"spatial_dims": list(dims),
                         "dim_sizes": dict(dim_sizes),
                         "periodic_dims": list(periodic)}}
    variables: Dict[str, Dict[str, Any]] = {}
    for n, v in (model.get("variables") or {}).items():
        meta: Dict[str, Any] = {}
        if v.get("type") == "state":
            meta["grid"] = grid_name
            meta["shape"] = list(dims)
        variables[n] = meta
    return RuleContext(grids=grids, variables=variables)


def _axis_side_name(axis: int, is_max: bool) -> str:
    """Axis-position side string (`xmin`/`xmax`/`ymin`/…) for the side's axis
    index, matching the rule engine's ``_SIDE_TO_AXIS_IDX`` guard convention."""
    return "xyz"[axis] + ("max" if is_max else "min")


def _resolve_bc_side(side: str, dims: List[str]) -> Optional[Tuple[str, bool]]:
    """Resolve a BC ``side`` string to ``(dim_name, is_max)`` — axis-position
    convention first (``xmin``/``ymax``/compass aliases via ``_SIDE_TO_AXIS_IDX``,
    matching ``bind_side_spacing``), then the ``<dim>min``/``<dim>max`` fallback."""
    axis = _SIDE_TO_AXIS_IDX.get(side)
    if axis is not None and axis < len(dims):
        return dims[axis], side in _BC_SIDE_MAX
    for d in dims:
        if side == d + "min":
            return d, False
        if side == d + "max":
            return d, True
    return None


def _collect_bcs(model: Dict[str, Any], domain: Dict[str, Any],
                 dims: List[str], state_names: List[str]) -> List[Dict[str, Any]]:
    """Normalize the model's v0.2 ``boundary_conditions`` map and any v0.1
    domain-level list into one list of BC dicts (``variable``/``kind``/``side``/
    ``value``/``coupled_variable``/Robin coeffs). v0.2 entries keep their map key
    in ``_name`` so the lowered ghost can be written back for golden parity; the
    nameless v0.1 list applies each entry to every state variable, both ends."""
    out: List[Dict[str, Any]] = []
    for name, bc in (model.get("boundary_conditions") or {}).items():
        kind = _BC_ALIAS.get(bc.get("kind"), bc.get("kind"))
        out.append({"_name": name, "variable": bc.get("variable"), "kind": kind,
                    "side": bc.get("side"), "value": bc.get("value"),
                    "coupled_variable": bc.get("coupled_variable"),
                    **{c: bc.get(c) for c in _ROBIN_COEFFS}})
    for bc in domain.get("boundary_conditions", []) or []:
        kind = _BC_ALIAS.get(bc.get("type"), bc.get("type", "dirichlet"))
        value = bc.get("value")
        for d in bc.get("dimensions", []):
            if d not in dims:
                continue
            axis = dims.index(d)
            for is_max in (False, True):
                side = _axis_side_name(axis, is_max)
                for var in state_names:
                    out.append({"_name": None, "variable": var, "kind": kind,
                                "side": side, "value": value,
                                "coupled_variable": None})
    return out


def _discretize_bc(bc: Dict[str, Any], rules: List[Any], ctx: RuleContext,
                   max_passes: int = 32) -> Optional[Any]:
    """Rewrite one BC into its ghost AST via the shared rule engine — the Python
    twin of Julia ``_discretize_bc!``.

    Builds the synthetic ``bc(variable[, coupled][, value][, robin α,β,γ])`` op
    (``kind``→``fn``, ``side``→``dim`` are promoted by the rule-engine parser),
    runs the rule engine, and returns the canonicalized ghost (rule-local 0-based
    frame). Returns ``None`` if no rule fired (the node is still a ``bc`` op)."""
    variable, kind = bc.get("variable"), bc.get("kind")
    if variable is None or kind is None:
        return None
    wrapper: Dict[str, Any] = {"op": "bc", "kind": kind, "args": [variable]}
    if bc.get("side") is not None:
        wrapper["side"] = bc["side"]
    if bc.get("coupled_variable") is not None:
        wrapper["args"].append(bc["coupled_variable"])
    if bc.get("value") is not None:
        wrapper["args"].append(bc["value"])
    for coeff in _ROBIN_COEFFS:
        if bc.get(coeff) is not None:
            wrapper["args"].append(bc[coeff])
    rewritten = rewrite(_parse_expr(wrapper), rules, ctx, max_passes=max_passes)
    if isinstance(rewritten, ExprNode) and rewritten.op == "bc":
        return None
    return _restore_neg(_to_json(canonicalize(rewritten)))


def _fold_index_arg(a: Any, fixed: Dict[str, int]) -> Optional[int]:
    """Fold an index-argument expression to a concrete int given fixed index
    values; ``None`` when symbols remain (mirror Julia ``_fold_index_arg``)."""
    if isinstance(a, bool):
        return None
    if isinstance(a, int):
        return a
    if isinstance(a, float):
        return int(a) if a.is_integer() else None
    if isinstance(a, str):
        return fixed.get(a)
    if not isinstance(a, dict) or a.get("op") not in ("+", "-"):
        return None
    args = a.get("args") or []
    if len(args) != 2:
        return None
    x, y = _fold_index_arg(args[0], fixed), _fold_index_arg(args[1], fixed)
    if x is None or y is None:
        return None
    return x + y if a["op"] == "+" else x - y


def _reindex_ghost(node: Any, var: str, pos: int, is_max: bool, n: int,
                   other_idx: Dict[int, int], rank: int) -> Any:
    """Re-index a BC-rule ghost AST from the rule's local 0-based frame into the
    absolute grid frame (mirror Julia ``_reindex_ghost``).

    Each ``index($u, L)`` read (L 0-based, cells inward from the boundary face)
    maps to the absolute grid index along the BC axis — min side ``1 + L``, max
    side ``n - L`` — while the variable's other axes inherit the concrete indices
    of the out-of-range read being replaced (``other_idx``). 1-based output."""
    if not isinstance(node, dict):
        return node
    if node.get("op") == "index":
        args = node.get("args") or []
        if args and isinstance(args[0], str) and args[0] == var:
            ell = _fold_index_arg(args[1], {}) if len(args) >= 2 else 0
            if ell is None:
                ell = 0
            full: List[Any] = [var]
            for p in range(rank):
                if p == pos:
                    full.append(n - ell if is_max else 1 + ell)
                else:
                    full.append(other_idx.get(p, 1))
            return {"op": "index", "args": full}
    out: Dict[str, Any] = {}
    for k, v in node.items():
        out[k] = ([_reindex_ghost(a, var, pos, is_max, n, other_idx, rank) for a in v]
                  if k == "args" and isinstance(v, list) else v)
    return out


def _instantiate_bc_cell_ghost(node: Any, fixed: Dict[str, int],
                               variables: Dict[str, Dict[str, Any]],
                               dim_sizes: Dict[str, int], periodic: set,
                               bc_ghost_map: Dict[Tuple[str, str, str], Any]) -> Any:
    """Instantiate a stencil body at literal cell indices, splicing the
    declarative BC-rule ghost at bounded out-of-range reads (mirror Julia
    ``_instantiate_bc_cell_ghost``).

    Index variables resolve via ``fixed``; a bounded out-of-range read of ``v`` on
    side ``s`` is replaced by ``bc_ghost_map[(v, dim, s)]`` re-indexed into the
    grid frame, then re-instantiated so corner reads (out-of-range on ≥2 axes)
    compose their per-axis ghosts. Periodic reads wrap modulo the dim size;
    undeclared out-of-range reads keep the zero-ghost convention (concrete index
    passes through)."""
    if not isinstance(node, dict):
        return node
    if node.get("op") == "index":
        args = node.get("args") or []
        if args and isinstance(args[0], str):
            vname = args[0]
            vmeta = variables.get(vname)
            vshape = vmeta.get("shape") if vmeta else None
            if isinstance(vshape, list) and len(vshape) == len(args) - 1:
                rank = len(vshape)
                folded = [_fold_index_arg(a, fixed) for a in args[1:]]
                for p in range(rank):
                    e = folded[p]
                    if e is None:
                        continue
                    dn = vshape[p]
                    n = int(dim_sizes.get(dn, 0))
                    if not (n > 0 and dn not in periodic and (e < 1 or e > n)):
                        continue
                    is_max = e > n
                    ghost = bc_ghost_map.get((vname, dn, "max" if is_max else "min"))
                    if ghost is None:
                        continue
                    other_idx = {q: folded[q] for q in range(rank)
                                 if q != p and folded[q] is not None}
                    spliced = _reindex_ghost(copy.deepcopy(ghost), vname, p, is_max,
                                             n, other_idx, rank)
                    return _instantiate_bc_cell_ghost(spliced, fixed, variables,
                                                      dim_sizes, periodic, bc_ghost_map)
                new_args: List[Any] = [vname]
                for p, a in enumerate(args[1:]):
                    e = folded[p]
                    if e is None:
                        new_args.append(a)
                        continue
                    dn = vshape[p]
                    n = int(dim_sizes.get(dn, 0))
                    if n > 0 and dn in periodic:
                        e = (e - 1) % n + 1
                    new_args.append(e)
                return {"op": "index", "args": new_args}
    out: Dict[str, Any] = {}
    for k, v in node.items():
        out[k] = ([_instantiate_bc_cell_ghost(a, fixed, variables, dim_sizes,
                                              periodic, bc_ghost_map) for a in v]
                  if k == "args" and isinstance(v, list) else v)
    return out


def _grid_sizes(domain, dims) -> Dict[str, Tuple[int, float]]:
    """Grid size (cell count, spacing) per dim — the FULL grid (no Dirichlet
    cell-dropping). Boundary cells stay state cells; their RHS uses the rewritten
    BC ghost (e.g. the Dirichlet reflected ghost ``2·value − u[boundary]``), at
    parity with Julia's makearray lowering."""
    out: Dict[str, Tuple[int, float]] = {}
    spatial = domain.get("spatial") or {}
    for name in dims:
        spec = spatial[name]
        n_points = int(round((spec["max"] - spec["min"]) / spec["grid_spacing"])) + 1
        out[name] = (n_points, float(spec["grid_spacing"]))
    return out


def _affine_offset(sub: Any, dim: str) -> Optional[int]:
    """If ``sub`` is an affine index ``dim`` / ``dim ± k`` (in the canonical
    ``{op:"+", args:[dim, k]}`` form or its ``-``/operand-swapped variants),
    return the integer offset ``k`` (0 for a bare ``dim``); else ``None``."""
    if sub == dim:
        return 0
    if isinstance(sub, dict) and sub.get("op") in ("+", "-"):
        args = sub.get("args") or []
        if len(args) == 2:
            a, b = args
            if sub["op"] == "+":
                if a == dim and isinstance(b, (int, float)) and not isinstance(b, bool):
                    return int(b)
                if b == dim and isinstance(a, (int, float)) and not isinstance(a, bool):
                    return int(a)
            elif sub["op"] == "-" and a == dim and isinstance(b, (int, float)) \
                    and not isinstance(b, bool):
                return -int(b)
    return None


def _stencil_reach(body: Any, dims: List[str]) -> Dict[str, int]:
    """Largest absolute stencil offset per spatial dim across every grid-shaped
    index read in ``body`` (any variable, not just the LHS state) — the ghost
    halo width each boundary needs (1 for a centred / Godunov stencil, 2 for
    WENO5). Mirrors Julia ``_scan_stencil_reach!``."""
    reach = {d: 0 for d in dims}

    def f(n):
        if (isinstance(n, dict) and n.get("op") == "index"
                and n.get("args") and isinstance(n["args"][0], str)):
            subs = n["args"][1:]
            if len(subs) == len(dims):
                for pos, d in enumerate(dims):
                    k = _affine_offset(subs[pos], d)
                    if k is not None:
                        reach[d] = max(reach[d], abs(k))
        return n
    _map_expr(body, f)
    return reach


def _apply_makearray_bcs(interior: Any, state: str, dims: List[str],
                         sizes: Dict[str, Tuple[int, float]], periodic: set,
                         bc_ghost_map: Dict[Tuple[str, str, str], Any],
                         variables: Dict[str, Dict[str, Any]]
                         ) -> Tuple[List[Any], List[Any]]:
    """Lower the interior stencil body into ``(regions, values)`` for a
    ``makearray``, splicing the declarative BC ghosts (Python twin of Julia
    ``_apply_makearray_bcs!``).

    Region 0 is the interior box ``[lo, hi]`` — shrunk on each bounded side by
    the stencil reach (a non-periodic side carrying a BC ghost, or either side of
    a periodic axis). Every cell outside that box becomes a single-cell region
    whose body is the interior re-instantiated at that cell with out-of-range
    reads ghost-spliced; 2-D corners fall out as cells bounded on ≥2 axes. Region
    0 stays disjoint from the boundary cells (not Julia's overlapping full box) so
    the vectorized evaluator never eagerly evaluates an out-of-range interior
    read — numerically identical, since boundary cells override region 0 anyway."""
    nd = len(dims)
    sizes_n = [sizes[d][0] for d in dims]
    dim_sizes = {d: sizes[d][0] for d in dims}
    reach = _stencil_reach(interior, dims)

    lo = [1] * nd
    hi = list(sizes_n)
    bounded = [False] * nd
    for d in range(nd):
        dn = dims[d]
        r = reach.get(dn, 0)
        if r == 0:
            continue
        if dn in periodic:
            lo[d], hi[d], bounded[d] = 1 + r, sizes_n[d] - r, True
        else:
            for is_max in (False, True):
                if (state, dn, "max" if is_max else "min") not in bc_ghost_map:
                    continue
                if is_max:
                    hi[d] = sizes_n[d] - r
                else:
                    lo[d] = 1 + r
                bounded[d] = True

    # No bounded side -> a single full-box region (makearray identity).
    if not any(bounded):
        return [[[1, sizes_n[d]] for d in range(nd)]], [copy.deepcopy(interior)]

    for d in range(nd):
        # A periodic axis with lo>hi just means every cell wraps; only a bounded
        # non-periodic axis whose two sides overlap is a genuine too-small grid.
        if dims[d] in periodic:
            continue
        if lo[d] > hi[d]:
            raise SpatialDiscretizeError(
                f"dimension {dims[d]!r} (size {sizes_n[d]}) is too small for the "
                f"stencil reach {reach.get(dims[d], 0)} with boundary conditions "
                "on both sides")

    regions: List[Any] = []
    values: List[Any] = []
    have_interior = all(lo[d] <= hi[d] for d in range(nd))
    if have_interior:
        regions.append([[lo[d], hi[d]] for d in range(nd)])
        values.append(copy.deepcopy(interior))
    for cell in itertools.product(*[range(1, sizes_n[d] + 1) for d in range(nd)]):
        if have_interior and all(lo[d] <= cell[d] <= hi[d] for d in range(nd)):
            continue
        fixed = {dims[d]: cell[d] for d in range(nd)}
        body_cell = _instantiate_bc_cell_ghost(copy.deepcopy(interior), fixed,
                                               variables, dim_sizes, periodic,
                                               bc_ghost_map)
        regions.append([[cell[d], cell[d]] for d in range(nd)])
        values.append(body_cell)
    return regions, values


def _observed_exprs(model: Dict[str, Any]) -> Dict[str, Any]:
    """Collect inline-able algebraic definitions (name -> expression).

    Covers the variable-level ``expression`` form (e.g. the level-set's
    ``psi_x = grad(psi, x)``) and **any** algebraic equation whose LHS is a bare
    variable name — regardless of the variable's declared ``type``. The latter is
    essential for observed-only components like RothermelFireSpread, whose 27
    algebraic unknowns are typed ``state`` but defined by ``var = expr`` (no time
    derivative); they must be inlined, not left as undefined states.
    """
    obs: Dict[str, Any] = {}
    for name, v in model.get("variables", {}).items():
        if v.get("type") == "observed" and v.get("expression") is not None:
            obs[name] = v["expression"]
    for eq in model.get("equations", []):
        lhs = eq.get("lhs")
        if isinstance(lhs, str):              # algebraic definition: var = expr
            obs[lhs] = eq["rhs"]
    return obs


def _resolve_observed(name, raw, cache, stack):
    if name in cache:
        return cache[name]
    if name in stack:
        raise SpatialDiscretizeError(f"cyclic observed dependency at {name!r}")
    resolved = _inline_observeds(raw[name], raw, cache, stack | {name})
    cache[name] = resolved
    return resolved


def _inline_observeds(expr, raw, cache, stack):
    """Substitute observed-variable names with their (recursively resolved)
    expressions, so spatial operators surface inline for discretization."""
    def f(n):
        if isinstance(n, str) and n in raw:
            return _resolve_observed(n, raw, cache, stack)
        return n
    return _map_expr(expr, f)


def _lhs_state(lhs, state_names) -> Optional[str]:
    if isinstance(lhs, dict) and lhs.get("op") == "D" and lhs.get("args"):
        a = lhs["args"][0]
        if isinstance(a, str) and a in state_names:
            return a
        if isinstance(a, dict) and a.get("op") == "index" and a["args"][0] in state_names:
            return a["args"][0]
    return None


def spatial_discretize(esm: Dict[str, Any], gdd: Dict[str, Any]) -> Dict[str, Any]:
    """Return a spatially-discretized copy of ``esm`` under the GDD.

    Each model with a spatial domain has its GDD-mapped spatial operators lowered
    to ArrayOp stencils (with ghost-region BCs), yielding an ODE system runnable
    by :func:`earthsci_toolkit.simulate`. Rule selection is entirely the GDD's —
    this function contains no stencil coefficients and no operator special-cases.
    """
    rules = _gdd_rules(gdd)
    bc_rules = _bc_rules(esm)
    out = copy.deepcopy(esm)
    # The document's top-level `rules` (BC ghost rules) are a discretization
    # input, consumed above into `bc_rules`; the lowered ODE is self-contained,
    # so drop them from the output (they are not a discretized-ODE schema field).
    out.pop("rules", None)
    domains = out.get("domains", {})
    for model in out.get("models", {}).values():
        dom = model.get("domain")
        if not dom or dom not in domains:
            continue
        domain = domains[dom]
        dims = list((domain.get("spatial") or {}).keys())
        if not dims:
            continue
        sizes = _grid_sizes(domain, dims)
        ranges = {d: [1, sizes[d][0]] for d in dims}
        dx_by_dim = {d: sizes[d][1] for d in dims}
        periodic = _periodic_dims(domain, dims)
        dim_sizes = {d: sizes[d][0] for d in dims}

        state_names = [n for n, v in model.get("variables", {}).items()
                       if v.get("type") == "state"]
        for n in state_names:
            model["variables"][n]["shape"] = list(dims)
        var_meta = {n: {"shape": list(dims)} for n in state_names}

        # Lower each BC to its ghost AST through the shared rule engine (the same
        # ESD `*_bc.json` rules Julia consumes), keyed by (variable, dim, side).
        # The rewritten ghost is also written back onto the model BC `value`
        # (golden parity with the Julia discretize output).
        ctx = _bc_rule_ctx(dom, dims, dim_sizes, periodic, model)
        bc_ghost_map: Dict[Tuple[str, str, str], Any] = {}
        for bc in _collect_bcs(model, domain, dims, state_names):
            ghost = _discretize_bc(bc, bc_rules, ctx)
            if ghost is None:
                continue
            resolved = _resolve_bc_side(str(bc.get("side", "")), dims)
            if resolved is None:
                continue
            dn, is_max = resolved
            bc_ghost_map[(bc["variable"], dn, "max" if is_max else "min")] = ghost
            if bc.get("_name") is not None:
                model["boundary_conditions"][bc["_name"]]["value"] = ghost

        # Observed spatial sub-expressions (e.g. psi_x = grad(psi,x)) are inlined
        # into each state PDE's RHS so their operators discretize in place; the
        # observed variables are then dropped from the discretized model.
        obs_raw = _observed_exprs(model)
        obs_cache: Dict[str, Any] = {}

        new_eqs = []
        for eq in model.get("equations", []):
            state = _lhs_state(eq["lhs"], state_names)
            if state is None:
                continue  # observed/algebraic defn — folded in by inlining
            inlined = _inline_observeds(eq["rhs"], obs_raw, obs_cache, set())
            rhs = _apply_gdd_rules(_expand_laplacian(inlined, dims), rules, dims, dx_by_dim)
            regions, values = _apply_makearray_bcs(rhs, state, dims, sizes, periodic,
                                                   bc_ghost_map, var_meta)
            new_eqs.append({
                "lhs": {"op": "arrayop", "args": [], "output_idx": list(dims),
                        "expr": {"op": "D", "args": [{"op": "index", "args": [state] + list(dims)}],
                                 "wrt": "t"}, "ranges": ranges},
                "rhs": {"op": "arrayop", "args": [], "output_idx": list(dims),
                        "expr": {"op": "index", "args": [{"op": "makearray", "args": [],
                                 "regions": regions, "values": values}] + list(dims)},
                        "ranges": ranges},
            })
        model["equations"] = new_eqs
        model["variables"] = {n: v for n, v in model["variables"].items()
                              if n not in obs_raw}
        model["system_kind"] = "ode"
        model.pop("domain", None)
    return out
