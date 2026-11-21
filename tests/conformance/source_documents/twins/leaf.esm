{
  "esm": "2.3.0",
  "metadata": {
    "name": "leaf",
    "description": "First-order decay of x at rate k.",
    "authors": ["EarthSciML"]
  },
  "models": {
    "Decay": {
      "variables": {
        "x": {"type": "unknown", "units": "1", "default": 1.0},
        "k": {"type": "parameter", "units": "1/s", "default": 0.5}
      },
      "equations": [
        {
          "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
          "rhs": {"op": "-", "args": [{"op": "*", "args": ["k", "x"]}]}
        }
      ]
    }
  }
}
