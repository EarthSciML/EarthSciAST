"""Small, closed shaped ESM documents for differential testing."""

from itertools import product

from hypothesis import strategies as st

KINDS = ("faq", "gather", "transpose", "reshape", "concat", "broadcast", "makearray")
INDEXED_TRANSFORMS = {"reshape", "concat"}
NUMBERS = st.integers(-8, 8)
EXTENTS = st.integers(1, 4)


def node(op, *args, **fields):
    return {"op": op, "args": list(args), **fields}


def document(model, test_id, kind, axes, definitions, result, output_axes):
    cells = list(product(*(range(1, axes[axis] + 1) for axis in output_axes)))
    if kind in INDEXED_TRANSFORMS:
        assertions = []
        for number, cell in enumerate(cells, 1):
            name = f"cell_{number}"
            definitions[name] = ([], node("index", result, *cell))
            assertions.append({"variable": name, "time": 0, "expected": 0})
    else:
        definitions["result"] = (output_axes, result)
        assertions = [
            {
                "variable": "result",
                "time": 0,
                "expected": 0,
                "coords": dict(zip(output_axes, cell, strict=True)),
            }
            for cell in cells
        ]
    variables = {
        name: {"type": "unknown", "units": "1", "description": name}
        | ({"shape": shape} if shape else {})
        for name, (shape, _) in definitions.items()
    }
    return {
        "esm": "2.4.0",
        "metadata": {
            "name": "ShapedProbe",
            "description": f"Generated {kind} differential fixture",
        },
        "index_sets": {axis: {"kind": "interval", "size": size} for axis, size in axes.items()},
        "models": {
            model: {
                "variables": variables,
                "equations": [{"lhs": name, "rhs": rhs} for name, (_, rhs) in definitions.items()],
                "tests": [
                    {
                        "id": test_id,
                        "time_span": {"start": 0, "end": 1},
                        "assertions": assertions,
                    }
                ],
            }
        },
    }


@st.composite
def fixture(draw, model, test_id, kind):
    extents = st.integers(2, 4) if kind in INDEXED_TRANSFORMS else EXTENTS
    rows = draw(extents)
    columns = draw(extents)
    axes = {"rows": rows, "columns": columns}
    definitions = {}

    def values(count):
        return draw(st.lists(NUMBERS, min_size=count, max_size=count))

    if kind in {"faq", "transpose"}:
        matrix = [values(columns) for _ in range(rows)]
        definitions["source"] = (["rows", "columns"], node("const", value=matrix))
    if kind in {"gather", "concat", "broadcast"}:
        definitions["source"] = (["rows"], node("const", value=values(rows)))

    if kind == "faq":
        output_axes = ["rows"]
        term = node("index", "source", "i", "j")
        rhs = node(
            "faq",
            output_idx=["i"],
            ranges={"i": {"from": "rows"}, "j": {"from": "columns"}},
            expr=term,
            filter=node(">", term, draw(NUMBERS)),
        )
    elif kind == "gather":
        output_axes = ["columns"]
        indices = draw(st.lists(st.integers(1, rows), min_size=columns, max_size=columns))
        definitions["indices"] = (["columns"], node("const", value=indices))
        rhs = node(
            "faq",
            output_idx=["i"],
            ranges={"i": {"from": "columns"}},
            expr=node("index", "source", node("index", "indices", "i")),
        )
    elif kind == "transpose":
        output_axes = ["columns", "rows"]
        rhs = node("transpose", "source")
    elif kind == "reshape":
        output_axes = ["rows", "columns"]
        axes["elements"] = rows * columns
        definitions["source"] = (["elements"], node("const", value=values(rows * columns)))
        rhs = node("reshape", "source", shape=[rows, columns])
    elif kind == "concat":
        output_axes = ["combined"]
        axes["combined"] = rows + columns
        definitions["tail"] = (["columns"], node("const", value=values(columns)))
        rhs = node("concat", "source", "tail", axis=0)
    elif kind == "broadcast":
        output_axes = ["rows"]
        rhs = node("broadcast", "source", draw(NUMBERS), fn="+")
    else:
        output_axes = ["rows"]
        cut = draw(st.integers(1, rows))
        rhs = node("makearray", regions=[[[1, rows]], [[cut, rows]]], values=values(2))

    return document(model, test_id, kind, axes, definitions, rhs, output_axes)
