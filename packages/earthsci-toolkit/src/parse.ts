/**
 * ESM Format JSON Parsing
 *
 * Provides functionality to load and validate ESM files from JSON strings or objects.
 * Separates concerns: JSON parsing → schema validation → type coercion.
 */

import Ajv, { ErrorObject, ValidateFunction } from 'ajv'
import addFormats from 'ajv-formats'
import type { EsmFile, Expression, CouplingEntry } from './types.js'
import { validateUnits } from './units.js'
import { isNumericLiteral, losslessJsonParse } from './numeric-literal.js'
import { lowerEnums } from './lower_enums.js'
import {
  lowerExpressionTemplates,
  rejectExpressionTemplatesPreV04,
} from './lower_expression_templates.js'

/**
 * Schema validation error with JSON Pointer path
 */
export interface SchemaError {
  /** JSON Pointer path to the error location */
  path: string
  /** Human-readable error message */
  message: string
  /** AJV validation keyword that failed */
  keyword: string
}

/**
 * Parse error - thrown when JSON parsing fails
 */
export class ParseError extends Error {
  constructor(message: string, public originalError?: Error) {
    super(message)
    this.name = 'ParseError'
  }
}

/**
 * Schema validation error - thrown when schema validation fails
 */
export class SchemaValidationError extends Error {
  constructor(message: string, public errors: SchemaError[]) {
    super(message)
    this.name = 'SchemaValidationError'
  }
}

/**
 * Grid-generator validation error — thrown for the post-schema checks in
 * RFC §6.5 (loader references must resolve; 'builtin' names must be from
 * the canonical closed set). Uses `code` to identify the specific failure
 * class (E_UNKNOWN_LOADER, E_UNKNOWN_BUILTIN).
 */
export class GridValidationError extends Error {
  constructor(message: string, public code: 'E_UNKNOWN_LOADER' | 'E_UNKNOWN_BUILTIN') {
    super(message)
    this.name = 'GridValidationError'
  }
}

/**
 * Closed set of canonical grid builtins (RFC §6.4.1). Adding a new name
 * here is a minor version bump.
 */
const KNOWN_GRID_BUILTINS = new Set<string>([])

// Embedded ESM schema - browser-compatible (no file system access required)
const schema = {
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://earthsciml.org/schemas/esm/0.6.0/esm.schema.json",
  "title": "ESM Format",
  "description": "EarthSciML Serialization Format (v0.6.0) \u2014 a language-agnostic JSON format for Earth system model components, their composition, and runtime configuration. v0.6.0 adds the `integral` built-in AST op for spatial partial integrals in partial integro-differential equations (PIDEs): an `integral` node carries `var` (integration dimension name), `lower` (lower-bound Expression), `upper` (upper-bound Expression), and `args[0]` (integrand); the upper bound may be the spatial variable itself for cumulative/partial integrals, or a constant for whole-domain integrals. Lowers to MethodOfLines.jl `Integral(x in DomainSets.ClosedInterval(lower, upper))`. v0.5.0 widens the `plots.y` field to accept either a single PlotAxis or an array of PlotAxis objects: the array form is an inline multi-series shorthand for `line`/`scatter` plots that projects each axis entry onto the `series` list (first entry becomes the canonical y-axis; each entry's `label`, or its `variable` when `label` is absent, becomes the series name). v0.4.0 adds first-class sampled function tables: a top-level `function_tables` block carrying named axes plus per-output literal data, and a new `table_lookup` AST op that names a table, supplies a per-axis input expression map, and selects an output. Tables are syntactic sugar that bindings lower to the existing `interp.linear` / `interp.bilinear` / `index` semantics \u2014 same numerical result, with the bulk data lifted out of repeated inline `const` arrays (see docs/rfcs/sampled-tables.md). v0.4.0 also adds component-scoped in-file `expression_templates` blocks (declared inside a single model or reaction_system) plus a new `apply_expression_template` AST op that references a template by name with per-parameter bindings. Templates are pure syntactic substitution \u2014 no recursion, no template-calls-template, no metaprogramming \u2014 and are expanded at load time so downstream consumers see only normal Expression ASTs (see docs/rfcs/ast-expression-templates.md). v0.3.0 closed the function-registry extension point (see docs/rfcs/closed-function-registry.md): the top-level `operators` and `registered_functions` blocks are removed, the `call` AST op is removed, and a new top-level `enums` block plus `fn` and `enum` AST ops are added. The `fn` op invokes a spec-defined closed function (currently the `datetime.*` calendar family plus `interp.searchsorted`, `interp.linear`, and `interp.bilinear`); `enum` resolves a file-local symbol to a positive integer used by the existing `index` op. Files declaring `operators` or `registered_functions` are no longer valid under this schema and must be migrated to AST equations + closed-function calls + discretization schemes (RFC \u00a76).",
  "type": "object",
  "required": [
    "esm",
    "metadata"
  ],
  "additionalProperties": false,
  "anyOf": [
    {
      "required": [
        "models"
      ]
    },
    {
      "required": [
        "reaction_systems"
      ]
    }
  ],
  "properties": {
    "esm": {
      "type": "string",
      "description": "Format version string (semver).",
      "pattern": "^\\d+\\.\\d+\\.\\d+$"
    },
    "metadata": {
      "$ref": "#/$defs/Metadata"
    },
    "models": {
      "type": "object",
      "description": "ODE-based model components, keyed by unique identifier.",
      "additionalProperties": {
        "$ref": "#/$defs/Model"
      }
    },
    "reaction_systems": {
      "type": "object",
      "description": "Reaction network components, keyed by unique identifier.",
      "additionalProperties": {
        "$ref": "#/$defs/ReactionSystem"
      }
    },
    "data_loaders": {
      "type": "object",
      "description": "External data source registrations (by reference).",
      "additionalProperties": {
        "$ref": "#/$defs/DataLoader"
      }
    },
    "enums": {
      "type": "object",
      "description": "File-local symbol-to-positive-integer mappings used by the 'enum' AST op to make categorical lookups cross-binding-portable. Each entry is an enum name; its value is an object mapping symbolic names (strings) to positive integers. Two .esm files may declare an enum of the same name with different mappings; enums are file-local and never merged across files. See esm-spec.md \u00a79.3.",
      "additionalProperties": {
        "$ref": "#/$defs/EnumDeclaration"
      }
    },
    "coupling": {
      "type": "array",
      "description": "Composition and coupling rules.",
      "items": {
        "$ref": "#/$defs/CouplingEntry"
      }
    },
    "domains": {
      "type": "object",
      "description": "Named spatial/temporal domain specifications.",
      "additionalProperties": {
        "$ref": "#/$defs/Domain"
      }
    },
    "interfaces": {
      "type": "object",
      "description": "Geometric connections between domains of different dimensionality.",
      "additionalProperties": {
        "$ref": "#/$defs/Interface"
      }
    },
    "discretizations": {
      "type": "object",
      "description": "Named stencil templates (discretization schemes) that map PDE operators to concrete AST transforms over a grid. Each entry is either a standard stencil-template Discretization (\u00a77.1), a CrossMetricStencilRule composite (\u00a77.6) that combines per-axis stencils and metric components for covariant operators on curvilinear grids, or a MultiOutputStencilRule (\u00a77.9) that emits multiple named output fields from one stencil application.",
      "additionalProperties": {
        "oneOf": [
          {
            "$ref": "#/$defs/Discretization"
          },
          {
            "$ref": "#/$defs/CrossMetricStencilRule"
          },
          {
            "$ref": "#/$defs/MultiOutputStencilRule"
          }
        ]
      }
    },
    "grids": {
      "type": "object",
      "description": "Named discretization grids (v0.2.0). Each entry declares a cartesian/unstructured topology with dimensions, staggering locations, metric arrays, and (for unstructured) connectivity tables. See docs/rfcs/discretization.md \u00a76.",
      "additionalProperties": {
        "$ref": "#/$defs/Grid"
      }
    },
    "staggering_rules": {
      "type": "object",
      "description": "Named staggering conventions that declare where quantities live on a grid. The unstructured_c_grid kind (RFC \u00a77.4) captures MPAS-style C-grid placement \u2014 scalars at Voronoi cell centers, normal velocities at edge midpoints, vorticity at triangle vertices \u2014 and is the prerequisite declaration for the \u00a77.3 worked-example discretizations (mpas_divergence_flux_form, mpas_gradient_edge_difference). Each entry references a grids.<g> entry by name.",
      "additionalProperties": {
        "$ref": "#/$defs/StaggeringRule"
      }
    },
    "function_tables": {
      "type": "object",
      "description": "Component-scoped sampled function tables (v0.4.0). Each entry declares ordered named axes plus a literal nested-array data block, optionally tagged with output names; the `table_lookup` AST op references a table by id, supplies a per-axis input-coordinate expression map, and selects which output to return. Tables are syntactic sugar over `interp.linear` / `interp.bilinear` / `index`: a `table_lookup` MUST be bit-equivalent to the equivalent inline-const lookup. See esm-spec.md \u00a79.5 and docs/rfcs/sampled-tables.md.",
      "additionalProperties": {
        "$ref": "#/$defs/FunctionTable"
      }
    }
  },
  "$defs": {
    "Metadata": {
      "type": "object",
      "description": "Authorship, provenance, and description.",
      "required": [
        "name"
      ],
      "additionalProperties": false,
      "properties": {
        "name": {
          "type": "string",
          "description": "Short identifier for the model configuration."
        },
        "description": {
          "type": "string"
        },
        "authors": {
          "type": "array",
          "items": {
            "type": "string"
          }
        },
        "license": {
          "type": "string"
        },
        "created": {
          "type": "string",
          "format": "date-time",
          "description": "ISO 8601 creation timestamp."
        },
        "modified": {
          "type": "string",
          "format": "date-time",
          "description": "ISO 8601 last-modified timestamp."
        },
        "tags": {
          "type": "array",
          "items": {
            "type": "string"
          }
        },
        "references": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/Reference"
          }
        }
      }
    },
    "Reference": {
      "type": "object",
      "description": "Academic citation or data source reference.",
      "additionalProperties": false,
      "properties": {
        "doi": {
          "type": "string"
        },
        "citation": {
          "type": "string"
        },
        "url": {
          "type": "string",
          "format": "uri"
        },
        "notes": {
          "type": "string"
        }
      }
    },
    "Expression": {
      "description": "Mathematical expression: a number literal, a variable/parameter reference string, or an operator node.",
      "oneOf": [
        {
          "type": "number"
        },
        {
          "type": "string"
        },
        {
          "$ref": "#/$defs/ExpressionNode"
        }
      ]
    },
    "ExpressionNode": {
      "type": "object",
      "description": "An operation in the expression AST.",
      "required": [
        "op",
        "args"
      ],
      "properties": {
        "op": {
          "type": "string",
          "description": "Operator name.",
          "enum": [
            "+",
            "-",
            "*",
            "/",
            "^",
            "D",
            "grad",
            "div",
            "laplacian",
            "integral",
            "exp",
            "log",
            "log10",
            "sqrt",
            "abs",
            "sin",
            "cos",
            "tan",
            "asin",
            "acos",
            "atan",
            "atan2",
            "min",
            "max",
            "floor",
            "ceil",
            "ifelse",
            ">",
            "<",
            ">=",
            "<=",
            "==",
            "!=",
            "and",
            "or",
            "not",
            "Pre",
            "sign",
            "arrayop",
            "makearray",
            "index",
            "broadcast",
            "reshape",
            "transpose",
            "concat",
            "fn",
            "enum",
            "const",
            "bc",
            "table_lookup",
            "apply_expression_template"
          ]
        },
        "args": {
          "type": "array",
          "description": "Operand list. For most ops these are sub-expressions. Array ops use args for the input array operands (arrayop, broadcast, index, reshape, transpose, concat). makearray has no natural args and uses an empty array.",
          "items": {
            "$ref": "#/$defs/Expression"
          },
          "minItems": 0
        },
        "wrt": {
          "type": "string",
          "description": "Differentiation variable for D operator (e.g., \"t\")."
        },
        "dim": {
          "type": "string",
          "description": "Spatial dimension for grad operator (e.g., \"x\", \"y\", \"z\")."
        },
        "var": {
          "type": "string",
          "description": "Integration variable for the integral operator: the name of the spatial dimension being integrated over (e.g., \"x\")."
        },
        "lower": {
          "$ref": "#/$defs/Expression",
          "description": "Lower integration bound for the integral operator. Any Expression: a numeric literal, a parameter reference, or an AST subtree. For a whole-domain integral both lower and upper are constants."
        },
        "upper": {
          "$ref": "#/$defs/Expression",
          "description": "Upper integration bound for the integral operator. Any Expression: a numeric literal, a parameter reference, the integration variable name (string) for a cumulative/partial integral, or an AST subtree."
        },
        "output_idx": {
          "type": "array",
          "description": "For arrayop: the result's index signature. Each entry is either a string (a symbolic index variable like \"i\", \"j\") or the integer 1 (a literal singleton dimension for reshape/broadcast). Mirrors SymbolicUtils.ArrayOp.output_idx.",
          "items": {
            "oneOf": [
              {
                "type": "string"
              },
              {
                "type": "integer",
                "const": 1
              }
            ]
          }
        },
        "expr": {
          "$ref": "#/$defs/Expression",
          "description": "For arrayop: the scalar body evaluated at each index point. May reference index symbols declared in output_idx as well as additional (contracted) index symbols. Mirrors SymbolicUtils.ArrayOp.expr."
        },
        "reduce": {
          "type": "string",
          "description": "For arrayop: the reduction operator applied to any index symbol that appears in expr but not in output_idx. Default is \"+\".",
          "enum": [
            "+",
            "*",
            "max",
            "min"
          ],
          "default": "+"
        },
        "ranges": {
          "type": "object",
          "description": "For arrayop: optional map from index symbol name to the range it iterates over. Each value is either a 2-element array [start, stop] (unit step) or a 3-element array [start, step, stop]. Indices not present are inferred from the domain / operand shapes at runtime. Mirrors SymbolicUtils.ArrayOp.ranges.",
          "additionalProperties": {
            "type": "array",
            "items": {
              "type": "integer"
            },
            "minItems": 2,
            "maxItems": 3
          }
        },
        "regions": {
          "type": "array",
          "description": "For makearray: list of sub-region boxes of the output array. Each region is an array of [start, stop] pairs, one per output dimension. The nth region is filled with the nth entry of values. Overlapping regions are permitted; later regions overwrite earlier ones. Mirrors SymbolicUtils.ArrayMaker.regions.",
          "items": {
            "type": "array",
            "items": {
              "type": "array",
              "items": {
                "type": "integer"
              },
              "minItems": 2,
              "maxItems": 2
            },
            "minItems": 1
          }
        },
        "values": {
          "type": "array",
          "description": "For makearray: list of expressions, one per entry in regions. Each value may be a scalar expression (broadcast across the region) or an array-valued expression whose shape matches the region (excluding singleton dimensions). Mirrors SymbolicUtils.ArrayMaker.values.",
          "items": {
            "$ref": "#/$defs/Expression"
          }
        },
        "shape": {
          "type": "array",
          "description": "For reshape: the target shape. Each entry is either an integer (a concrete length) or a string (a symbolic dimension reference).",
          "items": {
            "oneOf": [
              {
                "type": "integer"
              },
              {
                "type": "string"
              }
            ]
          },
          "minItems": 1
        },
        "perm": {
          "type": "array",
          "description": "For transpose: optional axis permutation. A list of 0-based axis indices giving the new order. If omitted, the matrix-transpose convention is used (reverse axes).",
          "items": {
            "type": "integer",
            "minimum": 0
          }
        },
        "axis": {
          "type": "integer",
          "description": "For concat: the 0-based axis along which to concatenate the operand arrays. All operands must have identical shape on every other axis.",
          "minimum": 0
        },
        "fn": {
          "type": "string",
          "description": "For broadcast: the name of the scalar operator to apply element-wise to the operands in args. Must be an ExpressionNode op name drawn from the scalar subset (arithmetic, elementary functions, comparisons, etc.)."
        },
        "name": {
          "type": "string",
          "description": "For fn: the dotted module path of a function in the closed function registry (esm-spec.md \u00a79.2). The set of valid names is fixed by the spec version; bindings MUST reject unknown names with diagnostic 'unknown_closed_function'. v0.3.0 set: datetime.year, datetime.month, datetime.day, datetime.hour, datetime.minute, datetime.second, datetime.day_of_year, datetime.julian_day, datetime.is_leap_year, interp.searchsorted, interp.linear, interp.bilinear. For apply_expression_template: the id of an `expression_templates` entry declared in the same component (esm-spec.md \u00a79.6 / docs/rfcs/ast-expression-templates.md). Bindings MUST reject references to undeclared template names at file-load time with diagnostic 'apply_expression_template_unknown_template'."
        },
        "value": {
          "description": "For const: the inline literal value carried by this expression node. Any JSON number, integer, or nested array thereof. `args` MUST be empty for a const node."
        },
        "kind": {
          "type": "string",
          "description": "For the 'bc' pattern-match op: the BC kind to match (one of 'constant', 'dirichlet', 'neumann', 'robin', 'zero_gradient', 'periodic', 'flux_contrib', 'interface'). See RFC \u00a79.2.",
          "enum": [
            "constant",
            "dirichlet",
            "neumann",
            "robin",
            "zero_gradient",
            "periodic",
            "flux_contrib",
            "interface"
          ]
        },
        "side": {
          "type": "string",
          "description": "For the 'bc' pattern-match op: the BC side to match (e.g., 'xmin', 'xmax', 'ymin', 'mesh_boundary'). See RFC \u00a79.2."
        },
        "table": {
          "type": "string",
          "description": "For table_lookup: the id of the function_tables entry to evaluate. Bindings MUST reject references to undeclared tables at file-load time with diagnostic 'table_lookup_unknown_table'."
        },
        "axes": {
          "type": "object",
          "description": "For table_lookup: a map from axis name (matching one of the referenced table's `axes[].name` entries) to the scalar input expression supplying that coordinate at evaluation time. Every axis declared on the table MUST appear as a key; extra keys are rejected with 'table_lookup_axis_name_mismatch'. `args` MUST be empty for a table_lookup node \u2014 the per-axis expressions live here.",
          "additionalProperties": {
            "$ref": "#/$defs/Expression"
          }
        },
        "output": {
          "description": "For table_lookup: which output of a multi-output table to return. Either a non-negative integer (0-based index into the leading data dimension) or a string (an entry in the table's `outputs` array). Single-output tables MAY omit this field (defaults to 0). Out-of-range or unknown-name selectors are rejected with 'table_lookup_output_out_of_range'.",
          "oneOf": [
            {
              "type": "integer",
              "minimum": 0
            },
            {
              "type": "string"
            }
          ]
        },
        "bindings": {
          "type": "object",
          "description": "For apply_expression_template: a map from each parameter name declared by the referenced template to the Expression bound to that parameter. Every entry of the template's `params` MUST appear as a key; extra keys are rejected at load time with diagnostic 'apply_expression_template_bindings_mismatch'. Values may be numeric literals, variable name references (strings), or arbitrary Expression ASTs (full subtrees). `args` MUST be empty for an apply_expression_template node \u2014 the parameter values live here.",
          "additionalProperties": {
            "$ref": "#/$defs/Expression"
          }
        }
      },
      "additionalProperties": false,
      "allOf": [
        {
          "if": {
            "properties": {
              "op": {
                "const": "arrayop"
              }
            },
            "required": [
              "op"
            ]
          },
          "then": {
            "required": [
              "output_idx",
              "expr"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "op": {
                "const": "makearray"
              }
            },
            "required": [
              "op"
            ]
          },
          "then": {
            "required": [
              "regions",
              "values"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "op": {
                "const": "broadcast"
              }
            },
            "required": [
              "op"
            ]
          },
          "then": {
            "required": [
              "fn"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "op": {
                "const": "reshape"
              }
            },
            "required": [
              "op"
            ]
          },
          "then": {
            "required": [
              "shape"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "op": {
                "const": "concat"
              }
            },
            "required": [
              "op"
            ]
          },
          "then": {
            "required": [
              "axis"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "op": {
                "const": "fn"
              }
            },
            "required": [
              "op"
            ]
          },
          "then": {
            "required": [
              "name"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "op": {
                "const": "const"
              }
            },
            "required": [
              "op"
            ]
          },
          "then": {
            "required": [
              "value"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "op": {
                "const": "enum"
              }
            },
            "required": [
              "op"
            ]
          },
          "then": {
            "properties": {
              "args": {
                "type": "array",
                "minItems": 2,
                "maxItems": 2,
                "items": {
                  "type": "string"
                }
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "op": {
                "const": "bc"
              }
            },
            "required": [
              "op"
            ]
          },
          "then": {
            "required": [
              "kind",
              "side"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "op": {
                "const": "table_lookup"
              }
            },
            "required": [
              "op"
            ]
          },
          "then": {
            "required": [
              "table",
              "axes"
            ],
            "properties": {
              "args": {
                "type": "array",
                "maxItems": 0
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "op": {
                "const": "apply_expression_template"
              }
            },
            "required": [
              "op"
            ]
          },
          "then": {
            "required": [
              "name",
              "bindings"
            ],
            "properties": {
              "args": {
                "type": "array",
                "maxItems": 0
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "op": {
                "const": "integral"
              }
            },
            "required": [
              "op"
            ]
          },
          "then": {
            "required": [
              "var",
              "lower",
              "upper"
            ],
            "properties": {
              "args": {
                "type": "array",
                "minItems": 1,
                "maxItems": 1
              }
            }
          }
        }
      ]
    },
    "Equation": {
      "type": "object",
      "description": "An equation: lhs = rhs (or lhs ~ rhs in MTK notation).",
      "required": [
        "lhs",
        "rhs"
      ],
      "additionalProperties": false,
      "properties": {
        "lhs": {
          "$ref": "#/$defs/Expression"
        },
        "rhs": {
          "$ref": "#/$defs/Expression"
        },
        "_comment": {
          "type": "string"
        }
      }
    },
    "AffectEquation": {
      "type": "object",
      "description": "An affect equation in an event: lhs is the target variable (string), rhs is an expression.",
      "required": [
        "lhs",
        "rhs"
      ],
      "additionalProperties": false,
      "properties": {
        "lhs": {
          "type": "string",
          "description": "Target variable name (value after the event)."
        },
        "rhs": {
          "$ref": "#/$defs/Expression",
          "description": "Expression for the new value. Use Pre(var) to reference pre-event values."
        }
      }
    },
    "ContinuousEvent": {
      "type": "object",
      "description": "Fires when a condition expression crosses zero (root-finding). Maps to MTK SymbolicContinuousCallback.",
      "required": [
        "conditions",
        "affects"
      ],
      "additionalProperties": false,
      "properties": {
        "name": {
          "type": "string",
          "description": "Human-readable identifier."
        },
        "conditions": {
          "type": "array",
          "description": "Expressions that trigger the event when they cross zero.",
          "items": {
            "$ref": "#/$defs/Expression"
          },
          "minItems": 1
        },
        "affects": {
          "type": "array",
          "description": "Affect equations applied on positive-going zero crossings (or both directions if affect_neg is absent). Empty array for pure detection.",
          "items": {
            "$ref": "#/$defs/AffectEquation"
          }
        },
        "affect_neg": {
          "description": "Separate affects for negative-going zero crossings. If null or absent, affects is used for both directions.",
          "oneOf": [
            {
              "type": "null"
            },
            {
              "type": "array",
              "items": {
                "$ref": "#/$defs/AffectEquation"
              }
            }
          ]
        },
        "root_find": {
          "type": "string",
          "description": "Root-finding direction.",
          "enum": [
            "left",
            "right",
            "all"
          ],
          "default": "left"
        },
        "reinitialize": {
          "type": "boolean",
          "description": "Whether to reinitialize the system after the event.",
          "default": false
        },
        "description": {
          "type": "string"
        }
      }
    },
    "DiscreteEventTrigger": {
      "description": "Trigger specification for a discrete event.",
      "oneOf": [
        {
          "type": "object",
          "description": "Fires when the boolean expression is true at the end of a timestep.",
          "required": [
            "type",
            "expression"
          ],
          "additionalProperties": false,
          "properties": {
            "type": {
              "const": "condition"
            },
            "expression": {
              "$ref": "#/$defs/Expression"
            }
          }
        },
        {
          "type": "object",
          "description": "Fires every interval time units.",
          "required": [
            "type",
            "interval"
          ],
          "additionalProperties": false,
          "properties": {
            "type": {
              "const": "periodic"
            },
            "interval": {
              "type": "number",
              "exclusiveMinimum": 0,
              "description": "Interval in simulation time units."
            },
            "initial_offset": {
              "type": "number",
              "description": "Offset from t=0 for the first firing.",
              "default": 0
            }
          }
        },
        {
          "type": "object",
          "description": "Fires at each specified time.",
          "required": [
            "type",
            "times"
          ],
          "additionalProperties": false,
          "properties": {
            "type": {
              "const": "preset_times"
            },
            "times": {
              "type": "array",
              "items": {
                "type": "number"
              },
              "minItems": 1,
              "description": "Array of simulation times at which to fire."
            }
          }
        }
      ]
    },
    "FunctionalAffect": {
      "type": "object",
      "description": "A registered functional affect handler for complex event behavior that cannot be expressed symbolically.",
      "required": [
        "handler_id",
        "read_vars",
        "read_params"
      ],
      "additionalProperties": false,
      "properties": {
        "handler_id": {
          "type": "string",
          "description": "Registered identifier for the affect implementation."
        },
        "read_vars": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "State variables accessed by the handler."
        },
        "read_params": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "Parameters accessed by the handler."
        },
        "modified_params": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "Parameters modified by the handler (implicitly discrete parameters)."
        },
        "config": {
          "type": "object",
          "description": "Handler-specific configuration.",
          "additionalProperties": true
        }
      }
    },
    "DiscreteEvent": {
      "type": "object",
      "description": "Fires when a boolean condition is true at end of a timestep, or at preset/periodic times. Maps to MTK SymbolicDiscreteCallback.",
      "required": [
        "trigger"
      ],
      "additionalProperties": false,
      "properties": {
        "name": {
          "type": "string",
          "description": "Human-readable identifier."
        },
        "trigger": {
          "$ref": "#/$defs/DiscreteEventTrigger"
        },
        "affects": {
          "type": "array",
          "description": "Affect equations. Required unless functional_affect is used.",
          "items": {
            "$ref": "#/$defs/AffectEquation"
          }
        },
        "functional_affect": {
          "$ref": "#/$defs/FunctionalAffect",
          "description": "Registered functional affect handler (alternative to symbolic affects)."
        },
        "discrete_parameters": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "Parameters modified by this event. Required when affects modify parameters rather than state variables."
        },
        "reinitialize": {
          "type": "boolean",
          "description": "Whether to reinitialize the system after the event."
        },
        "description": {
          "type": "string"
        }
      },
      "oneOf": [
        {
          "required": [
            "affects"
          ]
        },
        {
          "required": [
            "functional_affect"
          ]
        }
      ]
    },
    "ModelVariable": {
      "type": "object",
      "description": "A variable in an ODE/SDE model.",
      "required": [
        "type"
      ],
      "additionalProperties": false,
      "properties": {
        "type": {
          "type": "string",
          "enum": [
            "state",
            "parameter",
            "observed",
            "brownian"
          ],
          "description": "state = time-dependent unknown; parameter = externally set constant; observed = derived quantity; brownian = stochastic noise process (Wiener) that drives an SDE \u2014 the presence of any brownian variable promotes the enclosing model from an ODE system to an SDE system."
        },
        "units": {
          "type": "string"
        },
        "default": {
          "type": "number"
        },
        "default_units": {
          "type": "string",
          "description": "Units of the default value, if different from the declared units field. When present, validators flag a unit_inconsistency error if these do not match the declared units (including dimensionally incompatible cases like K vs kg, and same-dimension mismatches like K vs degC). Default is the same as `units`."
        },
        "description": {
          "type": "string"
        },
        "expression": {
          "$ref": "#/$defs/Expression",
          "description": "Defining expression for observed variables."
        },
        "shape": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "Arrayed-variable shape: ordered list of dimension names (drawn from the enclosing model's domain.spatial). Omitted or null indicates a scalar. Introduced in spec 0.2 (discretization RFC \u00a710.2)."
        },
        "location": {
          "type": "string",
          "description": "Staggered-grid location tag (e.g., \"cell_center\", \"edge_normal\", \"x_face\", \"vertex\"). Omitted indicates no explicit staggering; the spatialization step defaults to \"cell_center\" when the variable's model has a grid (discretization RFC \u00a710.2, \u00a711 step 2)."
        },
        "noise_kind": {
          "type": "string",
          "enum": [
            "wiener"
          ],
          "default": "wiener",
          "description": "Brownian-only: kind of stochastic process. Currently only \"wiener\" (zero-mean unit-variance Gaussian increments) is supported; reserved for future extension to \"colored\", \"correlated\", etc."
        },
        "correlation_group": {
          "type": "string",
          "description": "Brownian-only: optional opaque tag used to group correlated noise sources. Brownian variables sharing a group label are interpreted by the runtime as drawn from a joint multivariate normal whose correlation matrix is supplied externally. Brownian variables without a group label are independent. The spec does not currently encode the correlation matrix itself; that is left to a future extension."
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "type": {
                "const": "observed"
              }
            },
            "required": [
              "type"
            ]
          },
          "then": {
            "required": [
              "expression"
            ]
          }
        },
        {
          "if": {
            "not": {
              "properties": {
                "type": {
                  "const": "brownian"
                }
              },
              "required": [
                "type"
              ]
            }
          },
          "then": {
            "not": {
              "anyOf": [
                {
                  "required": [
                    "noise_kind"
                  ]
                },
                {
                  "required": [
                    "correlation_group"
                  ]
                }
              ]
            }
          }
        }
      ]
    },
    "Model": {
      "type": "object",
      "description": "An ODE system \u2014 a fully specified set of time-dependent equations.",
      "required": [
        "variables",
        "equations"
      ],
      "additionalProperties": false,
      "properties": {
        "domain": {
          "description": "Name of a domain from the domains section. Omit or set to null for 0D (non-spatial) models.",
          "oneOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ]
        },
        "coupletype": {
          "description": "Coupling type name. Informational label identifying this system's role in coupling.",
          "oneOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ]
        },
        "reference": {
          "$ref": "#/$defs/Reference"
        },
        "variables": {
          "type": "object",
          "description": "All variables, keyed by name.",
          "additionalProperties": {
            "$ref": "#/$defs/ModelVariable"
          }
        },
        "equations": {
          "type": "array",
          "description": "Array of {lhs, rhs} equation objects.",
          "items": {
            "$ref": "#/$defs/Equation"
          }
        },
        "initialization_equations": {
          "type": "array",
          "description": "Equations that hold only at t=0 (not dynamically). Used by models whose initialization requires solving an auxiliary system before time-stepping begins (e.g. aerosol equilibrium, plume rise). Each entry is a {lhs, rhs} equation evaluated/solved at t=0.",
          "items": {
            "$ref": "#/$defs/Equation"
          }
        },
        "guesses": {
          "type": "object",
          "description": "Initial-guess seeds for nonlinear solvers during initialization, keyed by variable name. Values are Expression graphs (numbers, strings, or ExpressionNode).",
          "additionalProperties": {
            "$ref": "#/$defs/Expression"
          }
        },
        "system_kind": {
          "type": "string",
          "description": "Discriminates the MTK system type this model maps to. Defaults to 'ode' (time-stepping). 'nonlinear' for algebraic-only systems (no time derivative; e.g. aerosol equilibrium, Mogi). 'sde' when brownian variables are present. 'pde' for models with a spatial domain plus differential operators (often implied by the domain field; set explicitly to disambiguate).",
          "enum": [
            "ode",
            "nonlinear",
            "sde",
            "pde"
          ]
        },
        "discrete_events": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/DiscreteEvent"
          }
        },
        "continuous_events": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/ContinuousEvent"
          }
        },
        "subsystems": {
          "type": "object",
          "description": "Named child models (subsystems), keyed by unique identifier. Enables hierarchical model composition. Variables in subsystems are referenced via dot notation: \"ParentModel.ChildModel.var\". Each subsystem can be defined inline or included by reference via a local file path or URL.",
          "additionalProperties": {
            "oneOf": [
              {
                "$ref": "#/$defs/Model"
              },
              {
                "$ref": "#/$defs/SubsystemRef"
              }
            ]
          }
        },
        "tolerance": {
          "$ref": "#/$defs/Tolerance",
          "description": "Model-level default numerical tolerance for tests, used when a test or assertion does not provide its own."
        },
        "tests": {
          "type": "array",
          "description": "Inline validation tests that exercise this model in isolation. Each test specifies initial conditions, parameter overrides, a time span, and scalar assertions at specific (variable, time) points.",
          "items": {
            "$ref": "#/$defs/Test"
          }
        },
        "examples": {
          "type": "array",
          "description": "Inline illustrative examples of how to run this model. Each example specifies initial state, parameters, a time span, an optional parameter sweep, and plot specifications.",
          "items": {
            "$ref": "#/$defs/Example"
          }
        },
        "boundary_conditions": {
          "type": "object",
          "description": "Model-level boundary conditions, keyed by user-supplied id (see docs/rfcs/discretization.md \u00a79). v0.2.0 breaking change: domains.<d>.boundary_conditions was removed in favor of this field; files from v0.1.0 carrying the old field must be migrated via spec.migrate_0_1_to_0_2 (RFC \u00a716.1).",
          "additionalProperties": {
            "$ref": "#/$defs/BoundaryCondition"
          }
        },
        "expression_templates": {
          "type": "object",
          "description": "Component-scoped in-file Expression-AST templates (v0.4.0; docs/rfcs/ast-expression-templates.md). Each entry names a fixed Expression body with parameter substitution slots; `apply_expression_template` AST nodes elsewhere in this component reference the entry by key with per-parameter bindings. Templates are component-local: declarations here are visible only within this model's expression positions. Loaders MUST expand `apply_expression_template` to a fully-substituted Expression AST at load time (Option A round-trip; the canonical AST after parse-then-emit is the expanded form). Templates do NOT call other templates and do NOT recurse.",
          "additionalProperties": {
            "$ref": "#/$defs/ExpressionTemplate"
          }
        }
      }
    },
    "SubsystemRef": {
      "type": "object",
      "description": "A reference to an external ESM file containing a model or reaction system definition. The ref field can be a relative or absolute local file path, or an HTTP/HTTPS URL. Relative paths are resolved relative to the directory of the referencing file.",
      "required": [
        "ref"
      ],
      "additionalProperties": false,
      "properties": {
        "ref": {
          "type": "string",
          "description": "Local file path or URL pointing to an ESM file. The referenced file must contain exactly one top-level model or reaction system, which is used as the subsystem definition."
        }
      }
    },
    "Species": {
      "type": "object",
      "description": "A reactive species in a reaction system.",
      "additionalProperties": false,
      "properties": {
        "units": {
          "type": "string"
        },
        "default": {
          "type": "number"
        },
        "default_units": {
          "type": "string",
          "description": "Units of the default value, if different from the declared units field. See ModelVariable.default_units for semantics."
        },
        "description": {
          "type": "string"
        },
        "constant": {
          "type": "boolean",
          "default": false,
          "description": "When true, the species participates in reactions as a reactant/product but its concentration is held fixed (no ODE integration) \u2014 a reservoir species. Maps to Catalyst's @species [isconstantspecies=true]. Absent or false means an ordinary state species with an ODE."
        }
      }
    },
    "Parameter": {
      "type": "object",
      "description": "A parameter in a reaction system.",
      "additionalProperties": false,
      "properties": {
        "units": {
          "type": "string"
        },
        "default": {
          "type": "number"
        },
        "default_units": {
          "type": "string",
          "description": "Units of the default value, if different from the declared units field. See ModelVariable.default_units for semantics."
        },
        "description": {
          "type": "string"
        }
      }
    },
    "StoichiometryEntry": {
      "type": "object",
      "description": "A species with its stoichiometric coefficient in a reaction. Coefficients MUST be positive and finite (NaN / \u00b1Infinity are rejected at parse time). Fractional values are supported to preserve fidelity with atmospheric-chemistry mechanisms whose products include non-integer yields (e.g. `0.87 CH2O`, `1.86 CH3O2`). Integer values remain valid \u2014 they are a subset of the permitted number range.",
      "required": [
        "species",
        "stoichiometry"
      ],
      "additionalProperties": false,
      "properties": {
        "species": {
          "type": "string"
        },
        "stoichiometry": {
          "type": "number",
          "exclusiveMinimum": 0
        }
      }
    },
    "Reaction": {
      "type": "object",
      "description": "A single reaction in a reaction system.",
      "required": [
        "id",
        "substrates",
        "products",
        "rate"
      ],
      "additionalProperties": false,
      "properties": {
        "id": {
          "type": "string",
          "description": "Unique reaction identifier (e.g., \"R1\")."
        },
        "name": {
          "type": "string"
        },
        "substrates": {
          "description": "Array of {species, stoichiometry} or null for source reactions (\u2205 \u2192 X).",
          "oneOf": [
            {
              "type": "null"
            },
            {
              "type": "array",
              "items": {
                "$ref": "#/$defs/StoichiometryEntry"
              },
              "minItems": 1
            }
          ]
        },
        "products": {
          "description": "Array of {species, stoichiometry} or null for sink reactions (X \u2192 \u2205).",
          "oneOf": [
            {
              "type": "null"
            },
            {
              "type": "array",
              "items": {
                "$ref": "#/$defs/StoichiometryEntry"
              },
              "minItems": 1
            }
          ]
        },
        "rate": {
          "$ref": "#/$defs/Expression",
          "description": "Rate expression: a parameter reference string, number, or expression AST."
        },
        "reference": {
          "$ref": "#/$defs/Reference"
        }
      }
    },
    "ReactionSystem": {
      "type": "object",
      "description": "A reaction network \u2014 declarative representation of chemical or biological reactions.",
      "required": [
        "species",
        "parameters",
        "reactions"
      ],
      "additionalProperties": false,
      "properties": {
        "domain": {
          "description": "Name of a domain from the domains section. Omit or set to null for 0D (non-spatial) systems.",
          "oneOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ]
        },
        "coupletype": {
          "description": "Coupling type name. Informational label identifying this system's role in coupling.",
          "oneOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ]
        },
        "reference": {
          "$ref": "#/$defs/Reference"
        },
        "species": {
          "type": "object",
          "description": "Named reactive species.",
          "additionalProperties": {
            "$ref": "#/$defs/Species"
          }
        },
        "parameters": {
          "type": "object",
          "description": "Named parameters (rate constants, temperature, photolysis rates, etc.).",
          "additionalProperties": {
            "$ref": "#/$defs/Parameter"
          }
        },
        "reactions": {
          "type": "array",
          "description": "Array of reaction definitions.",
          "items": {
            "$ref": "#/$defs/Reaction"
          },
          "minItems": 1
        },
        "constraint_equations": {
          "type": "array",
          "description": "Additional algebraic or ODE constraints.",
          "items": {
            "$ref": "#/$defs/Equation"
          }
        },
        "discrete_events": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/DiscreteEvent"
          }
        },
        "continuous_events": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/ContinuousEvent"
          }
        },
        "subsystems": {
          "type": "object",
          "description": "Named child reaction systems (subsystems), keyed by unique identifier. Enables hierarchical system composition. Variables in subsystems are referenced via dot notation: \"ParentSystem.ChildSystem.species\". Each subsystem can be defined inline or included by reference via a local file path or URL.",
          "additionalProperties": {
            "oneOf": [
              {
                "$ref": "#/$defs/ReactionSystem"
              },
              {
                "$ref": "#/$defs/SubsystemRef"
              }
            ]
          }
        },
        "tolerance": {
          "$ref": "#/$defs/Tolerance",
          "description": "System-level default numerical tolerance for tests, used when a test or assertion does not provide its own."
        },
        "tests": {
          "type": "array",
          "description": "Inline validation tests that exercise this reaction system in isolation. Each test specifies initial conditions, parameter overrides, a time span, and scalar assertions at specific (species/variable, time) points.",
          "items": {
            "$ref": "#/$defs/Test"
          }
        },
        "examples": {
          "type": "array",
          "description": "Inline illustrative examples of how to run this reaction system. Each example specifies initial state, parameters, a time span, an optional parameter sweep, and plot specifications.",
          "items": {
            "$ref": "#/$defs/Example"
          }
        },
        "expression_templates": {
          "type": "object",
          "description": "Component-scoped in-file Expression-AST templates (v0.4.0; docs/rfcs/ast-expression-templates.md). Each entry names a fixed Expression body with parameter substitution slots; `apply_expression_template` AST nodes elsewhere in this component (typically inside `reactions[*].rate`) reference the entry by key with per-parameter bindings. Templates are component-local: declarations here are visible only within this reaction system's expression positions. Loaders MUST expand `apply_expression_template` to a fully-substituted Expression AST at load time (Option A round-trip; the canonical AST after parse-then-emit is the expanded form). Templates do NOT call other templates and do NOT recurse.",
          "additionalProperties": {
            "$ref": "#/$defs/ExpressionTemplate"
          }
        }
      }
    },
    "ExpressionTemplate": {
      "type": "object",
      "description": "A single in-file Expression-AST template (esm-spec \u00a79.6 / docs/rfcs/ast-expression-templates.md). The `body` is a normal Expression AST in which parameter occurrences are written as bare parameter-name strings in any position where a variable reference would appear. At load time `apply_expression_template` nodes are expanded by structural substitution: every parameter occurrence in `body` is replaced by the bound argument's AST in source order. Pure syntactic substitution \u2014 no evaluation, no metaprogramming. Bodies MUST NOT contain `apply_expression_template` nodes themselves (no template-calls-template); bindings reject this with diagnostic 'apply_expression_template_recursive_body'.",
      "required": [
        "params",
        "body"
      ],
      "additionalProperties": false,
      "properties": {
        "params": {
          "type": "array",
          "description": "Ordered list of parameter names. MUST be unique within this template. Each name occurs zero or more times inside `body`; every name MUST also appear as a key in every `apply_expression_template.bindings` referencing this template.",
          "items": {
            "type": "string",
            "minLength": 1
          },
          "minItems": 1
        },
        "body": {
          "$ref": "#/$defs/Expression",
          "description": "The template's Expression AST body. Parameter names appear as bare strings in variable-reference positions and are replaced structurally at expansion time."
        },
        "description": {
          "type": "string"
        }
      }
    },
    "Tolerance": {
      "type": "object",
      "description": "Numerical comparison tolerance. Any of abs/rel may be specified. If both are given, an assertion passes when either bound is satisfied: |actual - expected| <= abs  OR  |actual - expected| / max(|expected|, epsilon) <= rel.",
      "additionalProperties": false,
      "properties": {
        "abs": {
          "type": "number",
          "minimum": 0,
          "description": "Absolute tolerance: |actual - expected| <= abs."
        },
        "rel": {
          "type": "number",
          "minimum": 0,
          "description": "Relative tolerance: |actual - expected| / max(|expected|, epsilon) <= rel."
        }
      }
    },
    "Assertion": {
      "type": "object",
      "description": "A single scalar check against a model variable at a specific (variable, time) point. PDE-aware variants pin a spatial point via `coords`, or reduce the field to a scalar via `reduce` (domain-integral, mean, max, min, error-norm, or convergence-order). `coords` and `reduce` are mutually exclusive; if neither is given the assertion is pointwise and only valid on a 0-D component. Error-norm reductions (L2_error, Linf_error) require `reference`. The `convergence_order` reduction requires `grid_refs` on the enclosing test, `reference`, and `expected_order`; `expected` is not used for convergence assertions.",
      "required": [
        "variable",
        "time"
      ],
      "additionalProperties": false,
      "properties": {
        "variable": {
          "type": "string",
          "description": "Name of the variable or species to check. Use the local name (e.g., \"O3\") or a scoped reference relative to this component (e.g., \"subsystem.X\")."
        },
        "time": {
          "type": "number",
          "description": "Simulation time at which to evaluate the assertion. Must lie within [time_span.start, time_span.end]."
        },
        "expected": {
          "type": "number",
          "description": "Expected scalar value of the variable at the given time."
        },
        "tolerance": {
          "$ref": "#/$defs/Tolerance",
          "description": "Per-assertion tolerance override. If present, this takes precedence over the test-level and model-level defaults."
        },
        "coords": {
          "type": "object",
          "description": "Spatial-point evaluation: map from the enclosing component's domain dimension name (e.g., \"x\", \"lon\") to the numeric coordinate at which to sample the field. All keys MUST be names of dimensions declared in the component's domain.spatial. Mutually exclusive with `reduce`.",
          "additionalProperties": {
            "type": "number"
          },
          "minProperties": 1
        },
        "reduce": {
          "type": "string",
          "description": "Domain reduction: collapse the spatial field to a single scalar before comparison. `integral`/`mean`/`max`/`min` are pure reductions; `L2_error`/`Linf_error` require a `reference` solution and compute ||u_actual - u_reference||_norm; `convergence_order` requires `grid_refs` on the enclosing test, `reference`, and `expected_order`, and asserts the measured log-log convergence slope. Mutually exclusive with `coords`.",
          "enum": [
            "integral",
            "mean",
            "max",
            "min",
            "L2_error",
            "Linf_error",
            "convergence_order"
          ]
        },
        "reference": {
          "description": "Reference (analytic or precomputed) solution required by error-norm reductions. Either an inline Expression evaluated over the component's domain coordinates, or a from_file shape pointing at a precomputed snapshot.",
          "oneOf": [
            {
              "$ref": "#/$defs/Expression"
            },
            {
              "type": "object",
              "required": [
                "type",
                "path"
              ],
              "additionalProperties": false,
              "properties": {
                "type": {
                  "const": "from_file"
                },
                "path": {
                  "type": "string"
                },
                "format": {
                  "type": "string"
                }
              }
            }
          ]
        },
        "expected_order": {
          "type": "number",
          "description": "Required when `reduce` is `convergence_order`. The expected numerical convergence rate (e.g., 2.0 for second-order methods). The assertion passes when the measured rate p_obs >= expected_order * (1 - tolerance.rel)."
        }
      },
      "allOf": [
        {
          "not": {
            "required": [
              "coords",
              "reduce"
            ]
          }
        },
        {
          "if": {
            "not": {
              "properties": {
                "reduce": {
                  "const": "convergence_order"
                }
              },
              "required": [
                "reduce"
              ]
            }
          },
          "then": {
            "required": [
              "expected"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "reduce": {
                "enum": [
                  "L2_error",
                  "Linf_error",
                  "convergence_order"
                ]
              }
            },
            "required": [
              "reduce"
            ]
          },
          "then": {
            "required": [
              "reference"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "reduce": {
                "const": "convergence_order"
              }
            },
            "required": [
              "reduce"
            ]
          },
          "then": {
            "required": [
              "expected_order"
            ],
            "properties": {
              "expected": false
            }
          }
        },
        {
          "if": {
            "properties": {
              "reduce": {
                "enum": [
                  "integral",
                  "mean",
                  "max",
                  "min"
                ]
              }
            },
            "required": [
              "reduce"
            ]
          },
          "then": {
            "not": {
              "required": [
                "reference"
              ]
            }
          }
        }
      ]
    },
    "Test": {
      "type": "object",
      "description": "An inline validation test for the enclosing model or reaction system. Defines the run configuration (initial conditions, parameter overrides, time span) and the scalar assertions that must hold.",
      "required": [
        "id",
        "time_span",
        "assertions"
      ],
      "additionalProperties": false,
      "properties": {
        "id": {
          "type": "string",
          "description": "Identifier unique within this component's tests array."
        },
        "description": {
          "type": "string",
          "description": "Human-readable description of what this test verifies."
        },
        "initial_conditions": {
          "type": "object",
          "description": "Initial-value overrides for state variables, keyed by variable name (local to this component). Values not listed fall back to the variable's declared default.",
          "additionalProperties": {
            "type": "number"
          }
        },
        "parameter_overrides": {
          "type": "object",
          "description": "Parameter overrides, keyed by parameter name (local to this component). Values not listed fall back to the parameter's declared default.",
          "additionalProperties": {
            "type": "number"
          }
        },
        "time_span": {
          "$ref": "#/$defs/TimeSpan"
        },
        "tolerance": {
          "$ref": "#/$defs/Tolerance",
          "description": "Test-level default tolerance applied to all assertions in this test that do not override it."
        },
        "assertions": {
          "type": "array",
          "description": "Scalar (variable, time) checks that define the pass/fail criterion of the test.",
          "items": {
            "$ref": "#/$defs/Assertion"
          },
          "minItems": 1
        },
        "grid_refs": {
          "type": "array",
          "description": "PDE only. Array of {ref} objects pointing to GridDiscretization Descriptor files (see esm-spec.md \u00a74.7.1). Each entry overrides the component's declared spatial grid and discretization for one run. A single-element list runs the test on exactly that grid configuration. Two or more entries enable a resolution sweep for convergence_order assertions.",
          "items": {
            "type": "object",
            "required": [
              "ref"
            ],
            "additionalProperties": false,
            "properties": {
              "ref": {
                "type": "string",
                "description": "URL or path to a GridDiscretization Descriptor (.gdd.json) file."
              }
            }
          },
          "minItems": 1
        }
      }
    },
    "TimeSpan": {
      "type": "object",
      "description": "Simulation time interval expressed in the component's time units.",
      "required": [
        "start",
        "end"
      ],
      "additionalProperties": false,
      "properties": {
        "start": {
          "type": "number"
        },
        "end": {
          "type": "number"
        }
      }
    },
    "SweepRange": {
      "type": "object",
      "description": "Generated range of parameter values.",
      "required": [
        "start",
        "stop",
        "count"
      ],
      "additionalProperties": false,
      "properties": {
        "start": {
          "type": "number"
        },
        "stop": {
          "type": "number"
        },
        "count": {
          "type": "integer",
          "minimum": 2
        },
        "scale": {
          "type": "string",
          "enum": [
            "linear",
            "log"
          ],
          "default": "linear",
          "description": "Spacing: linear = evenly spaced between start and stop; log = logarithmically spaced (start and stop must be strictly positive)."
        }
      }
    },
    "SweepDimension": {
      "type": "object",
      "description": "One axis of a parameter sweep: exactly one of values or range must be given.",
      "required": [
        "parameter"
      ],
      "additionalProperties": false,
      "properties": {
        "parameter": {
          "type": "string",
          "description": "Name of the parameter to vary (local to this component)."
        },
        "values": {
          "type": "array",
          "items": {
            "type": "number"
          },
          "minItems": 1,
          "description": "Enumerated values to use for this axis."
        },
        "range": {
          "$ref": "#/$defs/SweepRange",
          "description": "Generated range; mutually exclusive with values."
        }
      },
      "oneOf": [
        {
          "required": [
            "values"
          ]
        },
        {
          "required": [
            "range"
          ]
        }
      ]
    },
    "ParameterSweep": {
      "type": "object",
      "description": "A parameter sweep specification. Currently only Cartesian product sweeps are supported \u2014 the total run count is the product of each dimension's length.",
      "required": [
        "type",
        "dimensions"
      ],
      "additionalProperties": false,
      "properties": {
        "type": {
          "type": "string",
          "enum": [
            "cartesian"
          ],
          "description": "Sweep combination strategy. Currently only cartesian (full Cartesian product) is supported."
        },
        "dimensions": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/SweepDimension"
          },
          "minItems": 1
        }
      }
    },
    "PlotAxis": {
      "type": "object",
      "description": "Axis specification: any state variable, observed variable, parameter name, or swept parameter may be used.",
      "required": [
        "variable"
      ],
      "additionalProperties": false,
      "properties": {
        "variable": {
          "type": "string",
          "description": "Variable or parameter name (local to this component or scoped within a subsystem)."
        },
        "label": {
          "type": "string",
          "description": "Human-readable axis label. Viewers should fall back to the variable name if omitted."
        }
      }
    },
    "PlotValue": {
      "type": "object",
      "description": "A scalar value derived from a trajectory: used for heatmap z / color channels. Exactly one of at_time or reduce should be specified; if both are given, at_time takes precedence.",
      "required": [
        "variable"
      ],
      "additionalProperties": false,
      "properties": {
        "variable": {
          "type": "string",
          "description": "Variable whose trajectory is reduced to a scalar per run."
        },
        "at_time": {
          "type": "number",
          "description": "Specific simulation time at which to sample the variable."
        },
        "reduce": {
          "type": "string",
          "enum": [
            "max",
            "min",
            "mean",
            "integral",
            "final"
          ],
          "description": "Time-reduction applied to the trajectory: max/min/mean over the run, time integral, or the final value at time_span.end."
        }
      }
    },
    "PlotSeries": {
      "type": "object",
      "description": "A single named series for multi-series line or scatter plots.",
      "required": [
        "name",
        "variable"
      ],
      "additionalProperties": false,
      "properties": {
        "name": {
          "type": "string"
        },
        "variable": {
          "type": "string"
        }
      }
    },
    "Plot": {
      "type": "object",
      "description": "A plot specification associated with an example. Only structural information is recorded \u2014 axes, series selection, and value reductions. Styling (colors, fonts, legends, themes) is the viewer's concern. PDE-aware plot types `field_slice` and `field_snapshot` visualize spatial fields at a fixed time; `x` (and `y` for snapshots) name domain dimensions, the variable value becomes the y / color channel, and any non-plotted spatial dimension MUST be pinned in `pinned_coords`.",
      "required": [
        "id",
        "type",
        "x",
        "y"
      ],
      "additionalProperties": false,
      "properties": {
        "id": {
          "type": "string",
          "description": "Identifier unique within this example's plots array."
        },
        "type": {
          "type": "string",
          "enum": [
            "line",
            "scatter",
            "heatmap",
            "field_slice",
            "field_snapshot"
          ]
        },
        "description": {
          "type": "string"
        },
        "x": {
          "$ref": "#/$defs/PlotAxis"
        },
        "y": {
          "description": "Y-axis specification. May be a single PlotAxis, or an array of PlotAxis for inline multi-series line/scatter plots (alternative to the `series` field for the common case of plotting several variables against a shared x-axis).",
          "oneOf": [
            {
              "$ref": "#/$defs/PlotAxis"
            },
            {
              "type": "array",
              "items": {
                "$ref": "#/$defs/PlotAxis"
              },
              "minItems": 1
            }
          ]
        },
        "value": {
          "$ref": "#/$defs/PlotValue",
          "description": "Required for heatmap; defines the color channel. Ignored for line/scatter. For field_snapshot, the variable plotted as the color channel (use `value.variable`); `at_time` and `reduce` are ignored \u2014 the field is sampled at `at_time` declared on the plot."
        },
        "series": {
          "type": "array",
          "description": "Multiple named series for line or scatter plots. Ignored for heatmap and field plots.",
          "items": {
            "$ref": "#/$defs/PlotSeries"
          }
        },
        "at_time": {
          "type": "number",
          "description": "Required for field_slice and field_snapshot: simulation time at which to extract the spatial field. Must lie within the example's time_span."
        },
        "pinned_coords": {
          "type": "object",
          "description": "Required for field_slice and field_snapshot when the component domain has more spatial dimensions than the plot's spatial axes (1 for field_slice, 2 for field_snapshot). Maps each non-plotted spatial dimension name to the numeric coordinate at which to slice. Keys MUST be names of dimensions in component.domain.spatial that are not used by `x` (or `y` for field_snapshot).",
          "additionalProperties": {
            "type": "number"
          }
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "type": {
                "const": "heatmap"
              }
            },
            "required": [
              "type"
            ]
          },
          "then": {
            "required": [
              "value"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "field_slice"
              }
            },
            "required": [
              "type"
            ]
          },
          "then": {
            "required": [
              "at_time"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "field_snapshot"
              }
            },
            "required": [
              "type"
            ]
          },
          "then": {
            "required": [
              "at_time",
              "value"
            ]
          }
        }
      ]
    },
    "Example": {
      "type": "object",
      "description": "An inline illustrative example of how to run the enclosing component. Defines the run configuration and one or more plots derived from the result.",
      "required": [
        "id",
        "time_span"
      ],
      "additionalProperties": false,
      "properties": {
        "id": {
          "type": "string",
          "description": "Identifier unique within this component's examples array."
        },
        "description": {
          "type": "string",
          "description": "Human-readable description of what this example illustrates."
        },
        "initial_state": {
          "$ref": "#/$defs/InitialConditions",
          "description": "Initial conditions for state variables. Reuses the top-level InitialConditions $def (constant / per_variable / from_file / expression). For PDE components the `expression` variant carries per-variable closed-form initial fields (see esm-spec.md \u00a711.4)."
        },
        "parameters": {
          "type": "object",
          "description": "Parameter overrides, keyed by parameter name (local to this component).",
          "additionalProperties": {
            "type": "number"
          }
        },
        "time_span": {
          "$ref": "#/$defs/TimeSpan"
        },
        "parameter_sweep": {
          "$ref": "#/$defs/ParameterSweep",
          "description": "Optional parameter sweep. When present, the example represents a family of runs (one per Cartesian combination) rather than a single trajectory."
        },
        "plots": {
          "type": "array",
          "description": "Plot specifications derived from this example's run(s).",
          "items": {
            "$ref": "#/$defs/Plot"
          }
        },
        "grid_refs": {
          "type": "array",
          "description": "PDE only. Array of {ref} objects pointing to GridDiscretization Descriptor files (see esm-spec.md \u00a74.7.1). Each entry overrides the component's declared spatial grid and discretization for one run. A single-element list runs the example on exactly that grid configuration. When multiple entries are provided, the example represents a family of runs at different grid configurations; may be combined with parameter_sweep (total runs = Cartesian product).",
          "items": {
            "type": "object",
            "required": [
              "ref"
            ],
            "additionalProperties": false,
            "properties": {
              "ref": {
                "type": "string",
                "description": "URL or path to a GridDiscretization Descriptor (.gdd.json) file."
              }
            }
          },
          "minItems": 1
        }
      }
    },
    "DataLoaderSource": {
      "type": "object",
      "description": "File discovery configuration. Describes how to locate data files at runtime via URL templates with date/variable substitutions.",
      "required": [
        "url_template"
      ],
      "additionalProperties": false,
      "properties": {
        "url_template": {
          "type": "string",
          "description": "Jinja-style URL template with substitutions. Supported: {date:<strftime>} (e.g. {date:%Y%m%d}), {var}, {sector}, {species}. Custom substitutions are allowed and the runtime must accept and pass them through."
        },
        "mirrors": {
          "type": "array",
          "description": "Ordered fallback URL templates. Runtime tries each in order, first is primary. Follows the same substitution grammar as url_template.",
          "items": {
            "type": "string"
          }
        }
      }
    },
    "DataLoaderTemporal": {
      "type": "object",
      "description": "Temporal coverage and record layout for a data source.",
      "additionalProperties": false,
      "properties": {
        "start": {
          "type": "string",
          "format": "date-time",
          "description": "ISO 8601 datetime \u2014 first timestamp available from this source."
        },
        "end": {
          "type": "string",
          "format": "date-time",
          "description": "ISO 8601 datetime \u2014 last timestamp available from this source."
        },
        "file_period": {
          "type": "string",
          "description": "ISO 8601 duration describing how much time one file covers (e.g., \"P1D\", \"P1M\", \"PT3H\")."
        },
        "frequency": {
          "type": "string",
          "description": "ISO 8601 duration describing spacing between samples within a file."
        },
        "records_per_file": {
          "oneOf": [
            {
              "type": "integer",
              "minimum": 1
            },
            {
              "type": "string",
              "enum": [
                "auto"
              ]
            }
          ],
          "description": "Number of time records per file. \"auto\" means read from file at runtime."
        },
        "time_variable": {
          "type": "string",
          "description": "Name of the time coordinate variable in the file. Used when records_per_file is absent or \"auto\". If both static declarations (records_per_file + frequency) and time_variable are present, the static declaration wins and time_variable is a fallback."
        }
      }
    },
    "DataLoaderStaggering": {
      "type": "object",
      "description": "Per-dimension grid staggering (centered or edge-aligned).",
      "additionalProperties": {
        "type": "string",
        "enum": [
          "center",
          "edge"
        ]
      }
    },
    "DataLoaderSpatial": {
      "type": "object",
      "description": "Spatial grid description for a data source.",
      "required": [
        "crs",
        "grid_type"
      ],
      "additionalProperties": false,
      "properties": {
        "crs": {
          "type": "string",
          "description": "Coordinate reference system as a PROJ string or EPSG code."
        },
        "grid_type": {
          "type": "string",
          "enum": [
            "latlon",
            "lambert_conformal",
            "mercator",
            "polar_stereographic",
            "rotated_pole",
            "unstructured"
          ],
          "description": "Structural grid family. Use \"unstructured\" for mesh/point datasets."
        },
        "staggering": {
          "$ref": "#/$defs/DataLoaderStaggering"
        },
        "resolution": {
          "type": "object",
          "description": "Per-dimension resolution in native CRS units. Optional; some datasets only know this at runtime.",
          "additionalProperties": {
            "type": "number"
          }
        },
        "extent": {
          "type": "object",
          "description": "Per-dimension [min, max] extent in native CRS units. Optional; runtime can infer from files.",
          "additionalProperties": {
            "type": "array",
            "items": {
              "type": "number"
            },
            "minItems": 2,
            "maxItems": 2
          }
        }
      }
    },
    "DataLoaderVariable": {
      "type": "object",
      "description": "A variable exposed by a data loader, mapped from a source-file variable.",
      "required": [
        "file_variable",
        "units"
      ],
      "additionalProperties": false,
      "properties": {
        "file_variable": {
          "type": "string",
          "description": "Name of the variable inside the source file. May differ from the schema-level variable name."
        },
        "units": {
          "type": "string",
          "description": "Units of the variable as exposed to the schema."
        },
        "unit_conversion": {
          "oneOf": [
            {
              "type": "number"
            },
            {
              "$ref": "#/$defs/Expression"
            }
          ],
          "description": "Optional multiplicative factor or Expression AST applied to convert source-file values to the declared units."
        },
        "description": {
          "type": "string"
        },
        "reference": {
          "$ref": "#/$defs/Reference"
        }
      }
    },
    "DataLoaderRegridding": {
      "type": "object",
      "description": "Structural regridding configuration. Algorithm-specific tuning parameters are runtime-side and not in the schema.",
      "additionalProperties": false,
      "properties": {
        "fill_value": {
          "type": "number",
          "description": "Value to assign to cells with no source data."
        },
        "extrapolation": {
          "type": "string",
          "enum": [
            "clamp",
            "nan",
            "periodic"
          ],
          "description": "Behavior when regridding targets fall outside the source extent. Defaults to \"clamp\"."
        }
      }
    },
    "DataLoaderMesh": {
      "type": "object",
      "description": "Mesh-loader descriptor (discretization RFC \u00a78.A). Declares which loader fields are integer-typed connectivity tables vs float-typed metric arrays and the topological family the loader serves. Only meaningful when the enclosing DataLoader has kind='mesh'.",
      "required": [
        "topology",
        "connectivity_fields",
        "metric_fields"
      ],
      "additionalProperties": false,
      "properties": {
        "topology": {
          "type": "string",
          "enum": [
            "mpas_voronoi",
            "fesom_triangular",
            "icon_triangular"
          ],
          "description": "Closed topology enum. 'mpas_voronoi' is the v0.2.0 MVP; 'fesom_triangular' and 'icon_triangular' are reserved. Adding a new value is a minor version bump (RFC \u00a78.A.1)."
        },
        "connectivity_fields": {
          "type": "array",
          "description": "Integer-typed fields the loader exposes, which are referenceable from grids.<g>.connectivity.<name>.field (e.g. 'cellsOnEdge', 'edgesOnCell', 'verticesOnEdge', 'nEdgesOnCell').",
          "items": {
            "type": "string"
          },
          "minItems": 1
        },
        "metric_fields": {
          "type": "array",
          "description": "Float-typed fields the loader exposes, which are referenceable from grids.<g>.metric_arrays.<name>.generator.field (e.g. 'dcEdge', 'dvEdge', 'areaCell').",
          "items": {
            "type": "string"
          },
          "minItems": 1
        },
        "dimension_sizes": {
          "type": "object",
          "description": "Map of dimension name \u2192 integer extent or the literal string 'from_file'. Values feed grid-level parameters marked value='from_loader' (RFC \u00a76.6).",
          "additionalProperties": {
            "oneOf": [
              {
                "type": "integer",
                "minimum": 0
              },
              {
                "type": "string",
                "enum": [
                  "from_file"
                ]
              }
            ]
          }
        }
      }
    },
    "DataLoaderDeterminism": {
      "type": "object",
      "description": "Reproducibility contract a mesh (or grid) loader advertises to bindings (discretization RFC \u00a78.A and \u00a714 item 4). A binding that cannot honor the declared endian / float_format / integer_width MUST reject the file at load rather than silently reinterpreting bytes.",
      "additionalProperties": false,
      "properties": {
        "endian": {
          "type": "string",
          "enum": [
            "little",
            "big"
          ],
          "description": "Byte order of on-wire numeric fields."
        },
        "float_format": {
          "type": "string",
          "enum": [
            "ieee754_single",
            "ieee754_double"
          ],
          "description": "Floating-point format of metric fields."
        },
        "integer_width": {
          "type": "integer",
          "enum": [
            32,
            64
          ],
          "description": "Integer width (in bits) of connectivity fields."
        }
      }
    },
    "DataLoader": {
      "type": "object",
      "description": "A generic, runtime-agnostic description of an external data source. Carries enough structural information to locate files, map timestamps to files, describe spatial/variable semantics, and regrid \u2014 rather than pointing at a runtime handler. Authentication and algorithm-specific tuning are runtime-only and not part of the schema.",
      "required": [
        "kind",
        "source",
        "variables"
      ],
      "additionalProperties": false,
      "properties": {
        "kind": {
          "type": "string",
          "enum": [
            "grid",
            "points",
            "static",
            "mesh"
          ],
          "description": "Structural kind of the dataset. 'grid' / 'points' / 'static' are the classical kinds; 'mesh' (discretization RFC \u00a78.A) declares a mesh loader that publishes integer connectivity tables and float metric arrays under mesh.connectivity_fields / mesh.metric_fields. Scientific role (emissions, meteorology, elevation, ...) is not schema-validated and belongs in metadata.tags."
        },
        "source": {
          "$ref": "#/$defs/DataLoaderSource"
        },
        "temporal": {
          "$ref": "#/$defs/DataLoaderTemporal"
        },
        "spatial": {
          "$ref": "#/$defs/DataLoaderSpatial"
        },
        "mesh": {
          "$ref": "#/$defs/DataLoaderMesh"
        },
        "determinism": {
          "$ref": "#/$defs/DataLoaderDeterminism"
        },
        "variables": {
          "type": "object",
          "description": "Variables exposed by this loader, keyed by schema-level variable name.",
          "minProperties": 1,
          "additionalProperties": {
            "$ref": "#/$defs/DataLoaderVariable"
          }
        },
        "regridding": {
          "$ref": "#/$defs/DataLoaderRegridding"
        },
        "reference": {
          "$ref": "#/$defs/Reference"
        },
        "metadata": {
          "type": "object",
          "description": "Free-form metadata about the data source. The \"tags\" field (array of strings) is conventional for expressing scientific role (e.g. \"emissions\", \"reanalysis\") and is not schema-validated.",
          "additionalProperties": true,
          "properties": {
            "tags": {
              "type": "array",
              "items": {
                "type": "string"
              }
            }
          }
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "kind": {
                "const": "mesh"
              }
            },
            "required": [
              "kind"
            ]
          },
          "then": {
            "required": [
              "mesh"
            ]
          }
        }
      ]
    },
    "EnumDeclaration": {
      "type": "object",
      "description": "A file-local enum mapping symbolic names to positive integers (esm-spec.md \u00a79.3). Within a single enum, integer values MUST be unique. Across enums, values MAY collide (each enum is its own namespace). Bindings resolve enum-op nodes at load time before evaluating expressions.",
      "minProperties": 1,
      "additionalProperties": {
        "type": "integer",
        "minimum": 1
      }
    },
    "TranslateTarget": {
      "description": "Translation target: a simple variable reference string or an object with var and factor.",
      "oneOf": [
        {
          "type": "string"
        },
        {
          "type": "object",
          "required": [
            "var"
          ],
          "additionalProperties": false,
          "properties": {
            "var": {
              "type": "string"
            },
            "factor": {
              "type": "number"
            }
          }
        }
      ]
    },
    "ConnectorEquation": {
      "type": "object",
      "description": "A single equation in a ConnectorSystem linking two coupled systems.",
      "required": [
        "from",
        "to",
        "transform"
      ],
      "additionalProperties": false,
      "properties": {
        "from": {
          "type": "string",
          "description": "Source variable (scoped reference)."
        },
        "to": {
          "type": "string",
          "description": "Target variable (scoped reference)."
        },
        "transform": {
          "type": "string",
          "enum": [
            "additive",
            "multiplicative",
            "replacement"
          ],
          "description": "How the expression modifies the target."
        },
        "expression": {
          "$ref": "#/$defs/Expression",
          "description": "The coupling expression."
        }
      }
    },
    "CouplingEntry": {
      "description": "A single coupling rule connecting models, reaction systems, or data loaders.",
      "oneOf": [
        {
          "$ref": "#/$defs/CouplingOperatorCompose"
        },
        {
          "$ref": "#/$defs/CouplingCouple"
        },
        {
          "$ref": "#/$defs/CouplingVariableMap"
        },
        {
          "$ref": "#/$defs/CouplingCallback"
        },
        {
          "$ref": "#/$defs/CouplingEvent"
        }
      ]
    },
    "CouplingOperatorCompose": {
      "type": "object",
      "description": "Match LHS time derivatives and add RHS terms together.",
      "required": [
        "type",
        "systems"
      ],
      "additionalProperties": false,
      "properties": {
        "type": {
          "const": "operator_compose"
        },
        "systems": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "minItems": 2,
          "maxItems": 2,
          "description": "The two systems to compose."
        },
        "translate": {
          "type": "object",
          "description": "Variable mappings when LHS variables don't have matching names.",
          "additionalProperties": {
            "$ref": "#/$defs/TranslateTarget"
          }
        },
        "interface": {
          "type": "string",
          "description": "Name of an interface from the interfaces section for cross-domain coupling."
        },
        "lifting": {
          "type": "string",
          "enum": [
            "pointwise",
            "broadcast",
            "mean",
            "integral"
          ],
          "description": "Strategy for mapping between 0D and spatial systems."
        },
        "description": {
          "type": "string"
        }
      }
    },
    "CouplingCouple": {
      "type": "object",
      "description": "Bi-directional coupling via explicit ConnectorSystem equations.",
      "required": [
        "type",
        "systems",
        "connector"
      ],
      "additionalProperties": false,
      "properties": {
        "type": {
          "const": "couple"
        },
        "systems": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "minItems": 2,
          "maxItems": 2
        },
        "connector": {
          "type": "object",
          "required": [
            "equations"
          ],
          "additionalProperties": false,
          "properties": {
            "equations": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/ConnectorEquation"
              },
              "minItems": 1
            }
          }
        },
        "interface": {
          "type": "string",
          "description": "Name of an interface from the interfaces section for cross-domain coupling."
        },
        "lifting": {
          "type": "string",
          "enum": [
            "pointwise",
            "broadcast",
            "mean",
            "integral"
          ],
          "description": "Strategy for mapping between 0D and spatial systems."
        },
        "description": {
          "type": "string"
        }
      }
    },
    "CouplingVariableMap": {
      "type": "object",
      "description": "Replace a parameter in one system with a variable from another.",
      "required": [
        "type",
        "from",
        "to",
        "transform"
      ],
      "additionalProperties": false,
      "properties": {
        "type": {
          "const": "variable_map"
        },
        "from": {
          "type": "string",
          "description": "Source variable (scoped reference, e.g., \"GEOSFP.T\")."
        },
        "to": {
          "type": "string",
          "description": "Target parameter (scoped reference, e.g., \"SuperFast.T\")."
        },
        "transform": {
          "type": "string",
          "enum": [
            "param_to_var",
            "identity",
            "additive",
            "multiplicative",
            "conversion_factor"
          ],
          "description": "How the mapping is applied."
        },
        "factor": {
          "type": "number",
          "description": "Conversion factor (for conversion_factor transform)."
        },
        "interface": {
          "type": "string",
          "description": "Name of an interface from the interfaces section for cross-domain coupling."
        },
        "lifting": {
          "type": "string",
          "enum": [
            "pointwise",
            "broadcast",
            "mean",
            "integral"
          ],
          "description": "Strategy for mapping between 0D and spatial systems."
        },
        "description": {
          "type": "string"
        }
      }
    },
    "CouplingCallback": {
      "type": "object",
      "description": "Register a callback for simulation events.",
      "required": [
        "type",
        "callback_id"
      ],
      "additionalProperties": false,
      "properties": {
        "type": {
          "const": "callback"
        },
        "callback_id": {
          "type": "string",
          "description": "Registered identifier for the callback."
        },
        "config": {
          "type": "object",
          "additionalProperties": true
        },
        "description": {
          "type": "string"
        }
      }
    },
    "CouplingEvent": {
      "type": "object",
      "description": "Cross-system event involving variables from multiple coupled systems.",
      "required": [
        "type",
        "event_type"
      ],
      "additionalProperties": false,
      "properties": {
        "type": {
          "const": "event"
        },
        "event_type": {
          "type": "string",
          "enum": [
            "continuous",
            "discrete"
          ],
          "description": "Whether this is a continuous or discrete event."
        },
        "name": {
          "type": "string",
          "description": "Human-readable identifier."
        },
        "conditions": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/Expression"
          },
          "description": "Condition expressions (zero-crossing for continuous, boolean for discrete)."
        },
        "trigger": {
          "$ref": "#/$defs/DiscreteEventTrigger",
          "description": "Trigger specification (for discrete events)."
        },
        "affects": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/AffectEquation"
          },
          "description": "Affect equations. Required unless functional_affect is used."
        },
        "functional_affect": {
          "$ref": "#/$defs/FunctionalAffect",
          "description": "Registered functional affect handler (alternative to symbolic affects)."
        },
        "affect_neg": {
          "oneOf": [
            {
              "type": "null"
            },
            {
              "type": "array",
              "items": {
                "$ref": "#/$defs/AffectEquation"
              }
            }
          ]
        },
        "discrete_parameters": {
          "type": "array",
          "items": {
            "type": "string"
          }
        },
        "root_find": {
          "type": "string",
          "enum": [
            "left",
            "right",
            "all"
          ]
        },
        "reinitialize": {
          "type": "boolean"
        },
        "description": {
          "type": "string"
        }
      },
      "oneOf": [
        {
          "required": [
            "affects"
          ]
        },
        {
          "required": [
            "functional_affect"
          ]
        }
      ],
      "allOf": [
        {
          "if": {
            "properties": {
              "event_type": {
                "const": "continuous"
              }
            }
          },
          "then": {
            "required": [
              "conditions"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "event_type": {
                "const": "discrete"
              }
            }
          },
          "then": {
            "required": [
              "trigger"
            ]
          }
        }
      ]
    },
    "SpatialDimension": {
      "type": "object",
      "description": "Specification of a single spatial dimension.",
      "required": [
        "min",
        "max"
      ],
      "additionalProperties": false,
      "properties": {
        "min": {
          "type": "number"
        },
        "max": {
          "type": "number"
        },
        "units": {
          "type": "string"
        },
        "grid_spacing": {
          "type": "number",
          "exclusiveMinimum": 0
        }
      }
    },
    "CoordinateTransform": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "id": {
          "type": "string"
        },
        "description": {
          "type": "string"
        },
        "dimensions": {
          "type": "array",
          "items": {
            "type": "string"
          }
        }
      }
    },
    "InitialConditions": {
      "description": "Initial conditions for state variables. Four shapes: `constant` (uniform scalar), `per_variable` (uniform per variable), `from_file` (load a precomputed field), and `expression` (per-variable Expressions over the component's domain coordinates \u2014 a serializable closed-form initial field for PDE components).",
      "oneOf": [
        {
          "type": "object",
          "required": [
            "type",
            "value"
          ],
          "additionalProperties": false,
          "properties": {
            "type": {
              "const": "constant"
            },
            "value": {
              "type": "number"
            }
          }
        },
        {
          "type": "object",
          "required": [
            "type",
            "values"
          ],
          "additionalProperties": false,
          "properties": {
            "type": {
              "const": "per_variable"
            },
            "values": {
              "type": "object",
              "additionalProperties": {
                "type": "number"
              }
            }
          }
        },
        {
          "type": "object",
          "required": [
            "type",
            "path"
          ],
          "additionalProperties": false,
          "properties": {
            "type": {
              "const": "from_file"
            },
            "path": {
              "type": "string"
            },
            "format": {
              "type": "string"
            }
          }
        },
        {
          "type": "object",
          "required": [
            "type",
            "values"
          ],
          "additionalProperties": false,
          "properties": {
            "type": {
              "const": "expression"
            },
            "values": {
              "type": "object",
              "description": "Map from variable name to an Expression that yields the variable's initial field. Free symbols in the Expression MUST be names of the component domain's spatial dimensions (e.g., \"x\", \"y\"). The runtime evaluates the Expression at every grid point to produce u(x, 0). Only meaningful on PDE (\u22651-D spatial) components.",
              "additionalProperties": {
                "$ref": "#/$defs/Expression"
              },
              "minProperties": 1
            }
          }
        }
      ]
    },
    "DeprecatedDomainBoundaryCondition": {
      "type": "object",
      "description": "DEPRECATED v0.1.0 domain-level boundary condition entry. Retained for the v0.2.0 transitional window only (RFC \u00a710.1). Loaders emit E_DEPRECATED_DOMAIN_BC when encountering it; use Model.boundary_conditions (keyed map of BoundaryCondition entries) instead.",
      "deprecated": true,
      "required": [
        "type",
        "dimensions"
      ],
      "additionalProperties": false,
      "properties": {
        "type": {
          "type": "string",
          "enum": [
            "constant",
            "zero_gradient",
            "periodic",
            "dirichlet",
            "neumann",
            "robin"
          ]
        },
        "dimensions": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "minItems": 1
        },
        "value": {
          "type": "number"
        },
        "function": {
          "type": "string"
        },
        "robin_alpha": {
          "type": "number"
        },
        "robin_beta": {
          "type": "number"
        },
        "robin_gamma": {
          "type": "number"
        }
      }
    },
    "BoundaryCondition": {
      "type": "object",
      "description": "Model-level boundary condition entry (v0.2.0). Constrains one model variable on one boundary side. See docs/rfcs/discretization.md \u00a79.2 for full semantics. This object lives under models.<M>.boundary_conditions keyed by user-supplied id; it replaces the v0.1.0 domains.<d>.boundary_conditions list.",
      "required": [
        "variable",
        "side",
        "kind"
      ],
      "additionalProperties": false,
      "properties": {
        "variable": {
          "type": "string",
          "description": "Name of the model variable the BC constrains. Must resolve to a variable declared in the enclosing model's variables map (or a dot-qualified subsystem variable)."
        },
        "side": {
          "type": "string",
          "description": "Boundary side the BC applies to. Closed-vocabulary axis sides ('xmin', 'xmax', 'ymin', 'ymax', 'zmin', 'zmax', 'tmin', 'tmax') or generic unstructured boundary markers ('mesh_boundary'). Authors MAY introduce additional named sides (e.g., 'north', 'surface') provided the grid they reference declares them."
        },
        "kind": {
          "type": "string",
          "enum": [
            "constant",
            "dirichlet",
            "neumann",
            "robin",
            "zero_gradient",
            "periodic",
            "flux_contrib",
            "interface"
          ],
          "description": "BC kind. constant/dirichlet = fixed value; zero_gradient/neumann = \u2202u/\u2202n-based; robin = \u03b1u + \u03b2\u2202u/\u2202n = \u03b3; periodic = pair-side wraparound (declare once per periodic pair on either min or max side); flux_contrib = a component-contributed flux summand that the rewrite engine aggregates with other flux_contrib entries for the same (variable, side) pair before applying the enclosing neumann/robin template; interface = value-continuity coupling between two model variables at a shared boundary point (u(x*) = v(x*)), ghost-cell resolved using coupled_variable."
        },
        "value": {
          "description": "BC value: numeric literal, variable/parameter reference string, or expression AST. Required for kind='constant' and kind='dirichlet'; semantics for other kinds per RFC \u00a79.2.",
          "oneOf": [
            {
              "type": "number"
            },
            {
              "type": "string"
            },
            {
              "$ref": "#/$defs/ExpressionNode"
            }
          ]
        },
        "robin_alpha": {
          "description": "Robin BC coefficient \u03b1 for the u term in \u03b1u + \u03b2\u2202u/\u2202n = \u03b3.",
          "oneOf": [
            {
              "type": "number"
            },
            {
              "type": "string"
            },
            {
              "$ref": "#/$defs/ExpressionNode"
            }
          ]
        },
        "robin_beta": {
          "description": "Robin BC coefficient \u03b2 for the \u2202u/\u2202n term in \u03b1u + \u03b2\u2202u/\u2202n = \u03b3.",
          "oneOf": [
            {
              "type": "number"
            },
            {
              "type": "string"
            },
            {
              "$ref": "#/$defs/ExpressionNode"
            }
          ]
        },
        "robin_gamma": {
          "description": "Robin BC RHS value \u03b3 in \u03b1u + \u03b2\u2202u/\u2202n = \u03b3.",
          "oneOf": [
            {
              "type": "number"
            },
            {
              "type": "string"
            },
            {
              "$ref": "#/$defs/ExpressionNode"
            }
          ]
        },
        "coupled_variable": {
          "type": "string",
          "description": "For kind='interface': the name of the model variable at the other side of the shared boundary point. Ghost reads of this variable's boundary are resolved as index accesses into `coupled_variable`. Required when kind='interface'; ignored for all other kinds. Both variables must occupy the same grid dimension."
        },
        "flux_match": {
          "type": "boolean",
          "description": "For kind='interface': if true, enforce normal-flux continuity (\u2202u/\u2202n = \u2202v/\u2202n) in addition to value continuity at the interface. Default false. Currently only value continuity is handled by the arrayop-lift ghost-cell path; flux_match=true emits E_BC_UNSUPPORTED until a one-sided-difference stencil rule is registered.",
          "default": false
        },
        "face_coords": {
          "type": "array",
          "description": "Reduced face-coordinate index names used when `value` contains an `index` op into a loader-provided time-varying field (\u00a79.2 / \u00a78.A.3). E.g., for side='zmin' on a 3D grid, face_coords: ['i', 'j']. Omit when `value` does not index into a time-varying loader field.",
          "items": {
            "type": "string"
          }
        },
        "contributed_by": {
          "type": "object",
          "description": "Optional component-contribution marker identifying the model component (deposition, emissions, surface-flux scheme) providing this flux. The rewrite engine sums all flux_contrib entries for the same (variable, side) pair into a single aggregated flux, then applies the enclosing kind's BC template. See RFC \u00a79.3.",
          "additionalProperties": false,
          "required": [
            "component"
          ],
          "properties": {
            "component": {
              "type": "string",
              "description": "Name of the contributing component."
            },
            "flux_sign": {
              "type": "string",
              "enum": [
                "+",
                "-"
              ],
              "description": "Sign of the contribution in the aggregated flux sum. Default '+'.",
              "default": "+"
            }
          }
        },
        "description": {
          "type": "string",
          "description": "Human-readable description of the BC."
        }
      }
    },
    "Domain": {
      "type": "object",
      "description": "Spatiotemporal domain specification (DomainInfo).",
      "additionalProperties": false,
      "properties": {
        "independent_variable": {
          "type": "string",
          "description": "Name of the independent (time) variable.",
          "default": "t"
        },
        "temporal": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "start": {
              "type": "string",
              "format": "date-time"
            },
            "end": {
              "type": "string",
              "format": "date-time"
            },
            "reference_time": {
              "type": "string",
              "format": "date-time"
            }
          }
        },
        "spatial": {
          "type": "object",
          "description": "Spatial dimensions, keyed by name (e.g., lon, lat, lev).",
          "additionalProperties": {
            "$ref": "#/$defs/SpatialDimension"
          }
        },
        "coordinate_transforms": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/CoordinateTransform"
          }
        },
        "spatial_ref": {
          "type": "string",
          "description": "Coordinate reference system (e.g., \"WGS84\")."
        },
        "initial_conditions": {
          "$ref": "#/$defs/InitialConditions"
        },
        "boundary_conditions": {
          "type": "array",
          "description": "DEPRECATED (v0.2.0, RFC \u00a710.1): domain-level boundary_conditions is superseded by model-level boundary_conditions (models.<M>.boundary_conditions). Retained in the schema only as a transitional compatibility shim; loaders MUST emit E_DEPRECATED_DOMAIN_BC when this field is present. A follow-up release will remove this field entirely.",
          "deprecated": true,
          "items": {
            "$ref": "#/$defs/DeprecatedDomainBoundaryCondition"
          }
        },
        "element_type": {
          "type": "string",
          "enum": [
            "Float32",
            "Float64"
          ],
          "description": "Floating point precision.",
          "default": "Float64"
        },
        "array_type": {
          "type": "string",
          "description": "Array backend (e.g., \"Array\", \"CuArray\").",
          "default": "Array"
        }
      }
    },
    "InterfaceConstraint": {
      "type": "object",
      "description": "Constraint on a non-shared dimension at the interface.",
      "required": [
        "value"
      ],
      "additionalProperties": false,
      "properties": {
        "value": {
          "description": "Where the dimension is constrained: 'min', 'max', 'boundary', or a numeric coordinate.",
          "oneOf": [
            {
              "type": "string",
              "enum": [
                "min",
                "max",
                "boundary"
              ]
            },
            {
              "type": "number"
            }
          ]
        },
        "description": {
          "type": "string"
        }
      }
    },
    "GridMetricGenerator": {
      "type": "object",
      "description": "Generator for a grid metric array. Exactly one kind per \u00a76.5: 'expression' (analytic, computed at discretization time from grid parameters), 'loader' (pulled from a named data_loaders entry), or 'builtin' (from a closed set of canonical tables \u2014 the set is currently empty; adding a new builtin is a minor version bump per \u00a76.4.1).",
      "required": [
        "kind"
      ],
      "additionalProperties": false,
      "properties": {
        "kind": {
          "type": "string",
          "enum": [
            "expression",
            "loader",
            "builtin"
          ]
        },
        "expr": {
          "description": "For kind='expression': an ESM expression. All free variables must be grid parameters or dimension indices.",
          "oneOf": [
            {
              "type": "number"
            },
            {
              "type": "string"
            },
            {
              "$ref": "#/$defs/ExpressionNode"
            }
          ]
        },
        "loader": {
          "type": "string",
          "description": "For kind='loader': name of a data_loaders entry that produces the array."
        },
        "field": {
          "type": "string",
          "description": "For kind='loader': named field within the referenced loader's output."
        },
        "name": {
          "type": "string",
          "description": "For kind='builtin': canonical name from the closed set defined in \u00a76.4 (the set is currently empty). Unknown names MUST be rejected with E_UNKNOWN_BUILTIN."
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "kind": {
                "const": "expression"
              }
            },
            "required": [
              "kind"
            ]
          },
          "then": {
            "required": [
              "expr"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "kind": {
                "const": "loader"
              }
            },
            "required": [
              "kind"
            ]
          },
          "then": {
            "required": [
              "loader",
              "field"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "kind": {
                "const": "builtin"
              }
            },
            "required": [
              "kind"
            ]
          },
          "then": {
            "required": [
              "name"
            ]
          }
        }
      ]
    },
    "GridMetricArray": {
      "type": "object",
      "description": "A named metric array declared on a grid (e.g., dx, dcEdge, areaCell). See \u00a76.5.",
      "required": [
        "rank",
        "generator"
      ],
      "additionalProperties": false,
      "properties": {
        "rank": {
          "type": "integer",
          "minimum": 0,
          "description": "Tensor rank of the array: 0 = scalar (uniform spacing), 1 = 1D along a single dim, 2+ = multidimensional."
        },
        "dim": {
          "type": "string",
          "description": "For rank=1: the dimension the array is indexed by (one of the grid's dimensions)."
        },
        "dims": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "For rank\u22652: ordered list of dimensions the array is indexed by."
        },
        "shape": {
          "type": "array",
          "description": "Optional declared shape (parameter names or integer literals per dimension). Used by connectivity tables; redundant with dim/dims for metric arrays."
        },
        "generator": {
          "$ref": "#/$defs/GridMetricGenerator"
        }
      }
    },
    "GridConnectivity": {
      "type": "object",
      "description": "Unstructured-grid connectivity table (e.g., cellsOnEdge, edgesOnCell). Integer-indexed lookup produced by a mesh loader. See \u00a76.3.",
      "required": [
        "shape",
        "rank"
      ],
      "additionalProperties": false,
      "properties": {
        "shape": {
          "type": "array",
          "description": "Ordered list of dimension sizes (parameter names or integer literals). E.g., ['nEdges', 2] for cellsOnEdge."
        },
        "rank": {
          "type": "integer",
          "minimum": 1
        },
        "loader": {
          "type": "string",
          "description": "Name of a data_loaders entry that supplies this table."
        },
        "field": {
          "type": "string",
          "description": "Named field within the referenced loader's output."
        },
        "generator": {
          "$ref": "#/$defs/GridMetricGenerator",
          "description": "Alternative to loader/field: for generator-backed connectivity."
        }
      }
    },
    "GridExtent": {
      "type": "object",
      "description": "Per-dimension extent for cartesian grids. `n` is either an integer literal or a parameter reference naming the dimension count; `spacing` is 'uniform' or 'nonuniform' for cartesian (determines whether metric arrays are scalar or rank-1).",
      "required": [
        "n"
      ],
      "additionalProperties": false,
      "properties": {
        "n": {
          "oneOf": [
            {
              "type": "integer",
              "minimum": 1
            },
            {
              "type": "string"
            }
          ]
        },
        "spacing": {
          "type": "string",
          "enum": [
            "uniform",
            "nonuniform"
          ]
        }
      }
    },
    "Grid": {
      "type": "object",
      "description": "A named discretization grid. The `family` selects one of two topologies (cartesian / unstructured) per docs/rfcs/discretization.md \u00a76.1-\u00a76.4. Each grid also carries optional staggering locations, metric array declarations, and its own parameter block reusing the ordinary ESM Parameter schema.",
      "required": [
        "family",
        "dimensions"
      ],
      "additionalProperties": false,
      "properties": {
        "family": {
          "type": "string",
          "enum": [
            "cartesian",
            "unstructured"
          ]
        },
        "description": {
          "type": "string"
        },
        "dimensions": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "minItems": 1,
          "description": "Ordered list of logical dimension names."
        },
        "locations": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "Declared stagger locations used by variables on this grid (see \u00a711)."
        },
        "metric_arrays": {
          "type": "object",
          "additionalProperties": {
            "$ref": "#/$defs/GridMetricArray"
          }
        },
        "parameters": {
          "type": "object",
          "description": "Grid-level parameters. Reuses the ordinary ESM Parameter schema. Parameters with value='from_loader' are resolved at load time from a referenced data_loaders entry (\u00a76.6).",
          "additionalProperties": {
            "$ref": "#/$defs/Parameter"
          }
        },
        "domain": {
          "type": "string",
          "description": "Optional name of the domains entry this grid refines. If a domain declares grid_spacing for the same dimension, the grid's extents.<dim>.spacing wins (\u00a76.1)."
        },
        "extents": {
          "type": "object",
          "description": "Per-dimension extents. Required for 'cartesian'; not used by 'unstructured'.",
          "additionalProperties": {
            "$ref": "#/$defs/GridExtent"
          }
        },
        "connectivity": {
          "type": "object",
          "description": "Unstructured-family connectivity tables. Keys are table names (e.g., cellsOnEdge). Required for 'unstructured'; forbidden otherwise.",
          "additionalProperties": {
            "$ref": "#/$defs/GridConnectivity"
          }
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "family": {
                "const": "cartesian"
              }
            },
            "required": [
              "family"
            ]
          },
          "then": {
            "required": [
              "extents"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "family": {
                "const": "unstructured"
              }
            },
            "required": [
              "family"
            ]
          },
          "then": {
            "required": [
              "connectivity"
            ]
          }
        }
      ]
    },
    "Interface": {
      "type": "object",
      "description": "Geometric connection between two domains of potentially different dimensionality.",
      "required": [
        "domains",
        "dimension_mapping"
      ],
      "additionalProperties": false,
      "properties": {
        "description": {
          "type": "string"
        },
        "domains": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "minItems": 2,
          "maxItems": 2,
          "description": "The two domains connected by this interface."
        },
        "dimension_mapping": {
          "type": "object",
          "description": "Specifies shared dimensions and constraints.",
          "additionalProperties": false,
          "properties": {
            "shared": {
              "type": "object",
              "description": "Mapping of corresponding dimensions across domains, keyed by 'domain.dimension'.",
              "additionalProperties": {
                "type": "string"
              }
            },
            "constraints": {
              "type": "object",
              "description": "Non-shared dimensions fixed at the interface, keyed by 'domain.dimension'.",
              "additionalProperties": {
                "$ref": "#/$defs/InterfaceConstraint"
              }
            }
          }
        },
        "regridding": {
          "type": "object",
          "description": "Regridding strategy when shared dimensions differ in resolution.",
          "additionalProperties": false,
          "properties": {
            "method": {
              "type": "string",
              "enum": [
                "bilinear",
                "conservative",
                "nearest",
                "patch"
              ],
              "description": "Interpolation method for regridding."
            },
            "description": {
              "type": "string"
            }
          }
        }
      }
    },
    "PatternNode": {
      "description": "A shallow AST pattern (discretization RFC \u00a75.2, \u00a77.1). Values may be number literals, pattern variables ($name) or concrete strings, or object-form expression patterns. depth-1 constraint is not enforced by the schema \u2014 it is checked by the rule engine per \u00a77.2.1.",
      "oneOf": [
        {
          "type": "number"
        },
        {
          "type": "string"
        },
        {
          "type": "boolean"
        },
        {
          "type": "null"
        },
        {
          "type": "object",
          "additionalProperties": true
        },
        {
          "type": "array",
          "items": {
            "$ref": "#/$defs/PatternNode"
          }
        }
      ]
    },
    "RuleGuard": {
      "type": "object",
      "description": "A rule-selection-time guard constraining a pattern-variable binding. Drawn from the \u00a75.2.4 closed vocabulary; unknown guard names MUST be rejected at parse time.",
      "required": [
        "guard"
      ],
      "additionalProperties": true,
      "properties": {
        "guard": {
          "type": "string",
          "description": "Guard name (one of the \u00a75.2.4 closed set: 'dim_is_spatial_dim_of', 'var_location_is', 'var_has_grid', 'dim_is_periodic', 'dim_is_nonuniform', 'var_shape_rank', 'var_is_spatial_dim_of' legacy alias).",
          "enum": [
            "dim_is_spatial_dim_of",
            "var_is_spatial_dim_of",
            "var_location_is",
            "var_has_grid",
            "dim_is_periodic",
            "dim_is_nonuniform",
            "var_shape_rank"
          ]
        },
        "pvar": {
          "type": "string",
          "description": "Pattern variable the guard constrains (prefixed '$')."
        }
      }
    },
    "RuleRegion": {
      "description": "Spatial scope of a rule (discretization RFC \u00a77.2). When absent the rule applies everywhere the pattern matches. When a string, it is an informational/advisory tag with no runtime effect (legacy form from v0.2 \u00a75.2). When an object, it is a normative scoping predicate evaluated per query point; the rule applies ONLY at points satisfying the predicate, and falls through to the next matching rule otherwise.",
      "oneOf": [
        {
          "type": "string",
          "description": "Legacy advisory tag. No runtime effect \u2014 authors may group rules by region in editors but the rule engine does not consult it."
        },
        {
          "type": "object",
          "required": [
            "kind"
          ],
          "additionalProperties": false,
          "properties": {
            "kind": {
              "type": "string",
              "enum": [
                "boundary",
                "mask_field",
                "index_range"
              ],
              "description": "Scope variant tag."
            },
            "side": {
              "type": "string",
              "description": "For kind='boundary': the boundary side (e.g. 'xmin', 'xmax', 'west', 'east', 'south', 'north', 'top', 'bottom'). Site-specific sides (seams) are permitted when declared by the grid.",
              "enum": [
                "xmin",
                "xmax",
                "ymin",
                "ymax",
                "zmin",
                "zmax",
                "tmin",
                "tmax",
                "west",
                "east",
                "south",
                "north",
                "top",
                "bottom",
                "mesh_boundary"
              ]
            },
            "field": {
              "type": "string",
              "description": "For kind='mask_field': name of a data_loaders entry OR a boolean-typed model variable whose per-point value gates rule application (truthy \u21d2 rule applies)."
            },
            "axis": {
              "type": "string",
              "description": "For kind='index_range': canonical grid-family index name (cartesian: 'i', 'j', 'k', 'l', 'm'; unstructured: 'c', 'e', 'v' or a reduction 'k_bound' name)."
            },
            "lo": {
              "type": "integer",
              "description": "For kind='index_range': inclusive lower bound on the axis index."
            },
            "hi": {
              "type": "integer",
              "description": "For kind='index_range': inclusive upper bound on the axis index."
            }
          },
          "allOf": [
            {
              "if": {
                "properties": {
                  "kind": {
                    "const": "boundary"
                  }
                },
                "required": [
                  "kind"
                ]
              },
              "then": {
                "required": [
                  "side"
                ]
              }
            },
            {
              "if": {
                "properties": {
                  "kind": {
                    "const": "mask_field"
                  }
                },
                "required": [
                  "kind"
                ]
              },
              "then": {
                "required": [
                  "field"
                ]
              }
            },
            {
              "if": {
                "properties": {
                  "kind": {
                    "const": "index_range"
                  }
                },
                "required": [
                  "kind"
                ]
              },
              "then": {
                "required": [
                  "axis",
                  "lo",
                  "hi"
                ]
              }
            }
          ]
        }
      ]
    },
    "Rule": {
      "type": "object",
      "description": "A single rewrite rule (discretization RFC \u00a75.2). Matches an AST pattern with pattern variables, optionally guarded, and replaces the match with an inline AST ('replacement') or a named scheme ('use'). Region-of-applicability and per-point predicates are optional.",
      "required": [
        "pattern"
      ],
      "additionalProperties": false,
      "properties": {
        "name": {
          "type": "string",
          "description": "Rule identifier. When rules are authored as an object keyed by name, the name is the key; when rules are authored as an array, 'name' is a required field of each entry."
        },
        "pattern": {
          "$ref": "#/$defs/PatternNode",
          "description": "Match pattern \u2014 an AST with '$'-prefixed pattern variables (\u00a75.2). Depth and shape are enforced by the rule engine, not the schema."
        },
        "where": {
          "description": "Rule-selection-time predicate. Accepts either (a) an ARRAY of \u00a75.2.4 guard objects constraining pattern-variable bindings before the rule fires, or (b) an OBJECT expression-AST predicate evaluated per query point (\u00a77.2; reuses \u00a74 expression ops \u2014 e.g. {\"op\":\"==\",\"args\":[\"i\",0]}) whose value is coerced to bool. When an expression predicate is supplied, the rule applies ONLY at points where it evaluates true; the engine falls through to the next matching rule otherwise. Bindings that do not implement the per-point evaluator treat an object 'where' as a load-time parse success plus a runtime no-op that disables the rule (conservative fall-through).",
          "oneOf": [
            {
              "type": "array",
              "items": {
                "$ref": "#/$defs/RuleGuard"
              }
            },
            {
              "$ref": "#/$defs/ExpressionNode"
            }
          ]
        },
        "region": {
          "$ref": "#/$defs/RuleRegion"
        },
        "replacement": {
          "$ref": "#/$defs/PatternNode",
          "description": "Inline replacement AST over the same pattern variables. Mutually exclusive with 'use'."
        },
        "use": {
          "type": "string",
          "description": "Name of a scheme from 'discretizations.<name>' to invoke for expansion (\u00a77.2.1). Mutually exclusive with 'replacement'."
        },
        "produces": {
          "type": "array",
          "description": "Optional side-equation emission entries (\u00a79.4). A rule with 'produces' alone (no 'replacement'/'use') is legal.",
          "items": {
            "type": "object",
            "additionalProperties": true
          }
        },
        "boundary_policy": {
          "$ref": "#/$defs/BoundaryPolicy"
        },
        "ghost_width": {
          "$ref": "#/$defs/GhostWidth"
        },
        "bindings": {
          "type": "object",
          "description": "Declares the symbolic identifiers (other than pattern variables and canonical grid indices i/j/k/...) that the rule's replacement AST may reference, together with the rate at which each binding's value changes at runtime (RFC \u00a75.2.8). This is metadata: loaders preserve it across roundtrips but the rule engine does not consult it during pattern matching or expansion. Time-varying bindings (per_step, per_cell) document a contract between the rule author and the host runtime that supplies values during simulation. Static bindings are equivalent to model parameters and may be evaluated at load time. Keys are bare identifier names (e.g. 'dt', 'dx', 'velocity', 'cos_lat'); '$'-prefixed pattern-variable names are NOT permitted here (declare those via the pattern itself).",
          "additionalProperties": {
            "$ref": "#/$defs/RuleBinding"
          }
        },
        "description": {
          "type": "string"
        }
      },
      "oneOf": [
        {
          "required": [
            "replacement"
          ]
        },
        {
          "required": [
            "use"
          ]
        },
        {
          "required": [
            "produces"
          ]
        }
      ]
    },
    "BoundaryPolicy": {
      "description": "Behavior of a rule at the domain edges of any grid the pattern resolves on (RFC \u00a75.2.8 / \u00a77). Omission is equivalent to 'periodic' for backwards compatibility with v0.2/v0.3 rules that implicitly assumed wrap-around indexing. Two authorial forms are accepted: (1) a STRING from the closed set ['periodic','ghosted','neumann_zero','extrapolate','reflecting','one_sided_extrapolation','prescribed'] \u2014 a uniform policy across all axes whose ghost values, when needed, are governed by the rule's 'ghost_width'; (2) an OBJECT with a 'by_axis' map declaring per-axis policy entries (each entry is a BoundaryPolicySpec \u2014 a {kind, ...} object). The per-axis form is required for rules that need different policies on different axes (e.g. periodic in latitude, reflecting in vertical). Bindings preserve this field across parse/serialize roundtrips; semantic enforcement (ghost-cell synthesis, edge fall-through) is per-binding and may be a no-op while the rest of the discretization pipeline matures.",
      "oneOf": [
        {
          "type": "string",
          "enum": [
            "periodic",
            "ghosted",
            "neumann_zero",
            "extrapolate",
            "reflecting",
            "one_sided_extrapolation",
            "prescribed"
          ]
        },
        {
          "type": "object",
          "required": [
            "by_axis"
          ],
          "additionalProperties": false,
          "properties": {
            "by_axis": {
              "type": "object",
              "description": "Per-axis policy. Keys are axis names from the rule's grid (e.g. 'xi','eta','x','y','z','lat','lon','lev'); values are BoundaryPolicySpec objects.",
              "additionalProperties": {
                "$ref": "#/$defs/BoundaryPolicySpec"
              }
            },
            "description": {
              "type": "string"
            }
          }
        }
      ]
    },
    "BoundaryPolicySpec": {
      "type": "object",
      "description": "A single per-axis boundary policy (RFC \u00a75.2.8 / \u00a77). The 'kind' tag selects from the closed set described in BoundaryPolicy; per-kind sibling fields carry the policy's parameters.",
      "required": [
        "kind"
      ],
      "additionalProperties": false,
      "properties": {
        "kind": {
          "type": "string",
          "enum": [
            "periodic",
            "reflecting",
            "one_sided_extrapolation",
            "prescribed",
            "ghosted",
            "neumann_zero",
            "extrapolate"
          ],
          "description": "Closed-set tag. 'periodic' wraps around. 'reflecting' mirrors across the edge. 'one_sided_extrapolation' fills ghost values from interior using the 'degree' parameter. 'prescribed' declares the caller supplies ghost values; the runtime treats the input as already-extended. 'ghosted' is retained as a v0.3.x alias for 'prescribed' (caller-supplied ghost cells via an upstream BC pass). 'neumann_zero' is retained as a v0.3.x alias for 'reflecting' (mirror BC, zero flux). 'extrapolate' is retained as a v0.3.x alias for 'one_sided_extrapolation' (defaulting to linear when 'degree' is omitted)."
        },
        "degree": {
          "description": "one_sided_extrapolation / extrapolate: extrapolation order. 0 = constant (zeroth-order), 1 = linear (default if omitted), 2 = quadratic, 3 = cubic. Higher orders are rejected by the schema.",
          "type": "integer",
          "minimum": 0,
          "maximum": 3
        },
        "description": {
          "type": "string",
          "description": "Free-form authorial note explaining the policy choice."
        }
      }
    },
    "GhostWidth": {
      "description": "Required ghost-cell padding per axis for a rule (RFC \u00a75.2.8 / \u00a77). The runtime preparing inputs to a rule SHALL extend each axis's input array by at least 'ghost_width[axis]' cells on each side, using the rule's declared 'boundary_policy' for that axis to fill the extension. Two authorial forms are accepted: (1) a non-negative INTEGER \u2014 uniform width applied to every axis the rule's stencil reaches; (2) an OBJECT with 'by_axis' giving per-axis non-negative integers. Omission is equivalent to 0 (rule reads only in-bounds indices). Bindings preserve this field across parse/serialize roundtrips; semantic enforcement is per-binding and may be a no-op while the rest of the discretization pipeline matures.",
      "oneOf": [
        {
          "type": "integer",
          "minimum": 0
        },
        {
          "type": "object",
          "required": [
            "by_axis"
          ],
          "additionalProperties": false,
          "properties": {
            "by_axis": {
              "type": "object",
              "description": "Per-axis ghost width. Keys are axis names from the rule's grid; values are non-negative integers.",
              "additionalProperties": {
                "type": "integer",
                "minimum": 0
              }
            },
            "description": {
              "type": "string"
            }
          }
        }
      ]
    },
    "RuleBinding": {
      "type": "object",
      "description": "A single binding declaration for a rule (RFC \u00a75.2.8). Carries the binding's update cadence ('static', 'per_step', 'per_cell') and an optional default-value expression. The schema does not require 'default' \u2014 a binding with no default declares a runtime-supplied value with no compile-time fallback.",
      "required": [
        "kind"
      ],
      "additionalProperties": false,
      "properties": {
        "kind": {
          "type": "string",
          "enum": [
            "static",
            "per_step",
            "per_cell"
          ],
          "description": "Update cadence. 'static' = constant for the whole simulation (e.g. Earth radius R, fixed grid spacing dlon). 'per_step' = may change once per time-step (e.g. an adaptive dt, an externally-driven max wind speed). 'per_cell' = varies across the grid at runtime (e.g. cell-centered velocity, latitudinally-varying cos_lat); the value is indexed by the canonical grid indices in scope."
        },
        "default": {
          "$ref": "#/$defs/ExpressionNode",
          "description": "Optional default value as an \u00a74 expression. For 'static' bindings this is the value used when the runtime supplies no override. For 'per_step' and 'per_cell' bindings it is an authorial fallback \u2014 bindings MAY ignore it if the runtime always supplies a live value."
        },
        "description": {
          "type": "string",
          "description": "Free-form authorial note about what this binding represents (e.g. 'Courant number, set per-step from max|u|\u00b7dt/dx')."
        }
      }
    },
    "NeighborSelector": {
      "type": "object",
      "description": "Discretization stencil neighbor selector (RFC \u00a74, \u00a77.2). The selector.kind tag discriminates between cartesian, indirect, and reduction selectors. Additional per-kind fields are permitted so that pattern variables such as $x can appear in e.g. axis/offset positions.",
      "required": [
        "kind"
      ],
      "properties": {
        "kind": {
          "type": "string",
          "enum": [
            "cartesian",
            "indirect",
            "reduction"
          ],
          "description": "Selector family; must agree with the enclosing Discretization's grid_family (cartesian\u2194cartesian, unstructured\u2194indirect|reduction)."
        },
        "axis": {
          "description": "cartesian: axis name (string or pattern variable e.g. \"$x\"). Ignored for other kinds."
        },
        "offset": {
          "description": "cartesian: integer offset along the axis. May be a pattern variable or an expression node for symbolic strides."
        },
        "index_expr": {
          "description": "indirect: single index expression producing the neighbor's index in the indexed variable (AST).",
          "$ref": "#/$defs/PatternNode"
        },
        "table": {
          "type": "string",
          "description": "reduction/indirect: name of the connectivity array (e.g. \"edgesOnCell\") providing the neighbor list; referenced inside coeff via index(table, $target, k)."
        },
        "count_expr": {
          "description": "reduction: AST expression producing the per-target neighbor count (e.g. index(nEdgesOnCell, $target)).",
          "$ref": "#/$defs/PatternNode"
        },
        "k_bound": {
          "type": "string",
          "description": "reduction: name of the local iteration index (in scope inside coeff alongside $target); conventionally \"k\"."
        },
        "combine": {
          "type": "string",
          "enum": [
            "+",
            "*",
            "min",
            "max"
          ],
          "description": "reduction: how element contributions combine across the neighbor loop (default \"+\" when omitted)."
        }
      },
      "additionalProperties": false,
      "allOf": [
        {
          "if": {
            "properties": {
              "kind": {
                "const": "cartesian"
              }
            },
            "required": [
              "kind"
            ]
          },
          "then": {
            "required": [
              "axis",
              "offset"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "kind": {
                "const": "reduction"
              }
            },
            "required": [
              "kind"
            ]
          },
          "then": {
            "required": [
              "table",
              "count_expr",
              "k_bound"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "kind": {
                "const": "indirect"
              }
            },
            "required": [
              "kind"
            ]
          },
          "then": {
            "required": [
              "index_expr"
            ]
          }
        }
      ]
    },
    "StencilEntry": {
      "type": "object",
      "description": "One neighbor contribution to a discretization stencil: a selector picking out the neighbor(s) and a coefficient expression.",
      "required": [
        "selector",
        "coeff"
      ],
      "additionalProperties": false,
      "properties": {
        "selector": {
          "$ref": "#/$defs/NeighborSelector"
        },
        "coeff": {
          "description": "Coefficient expression. May reference grid metric arrays (bare strings or index nodes), grid parameters, pattern variables bound by the triggering rule, k_bound if a reduction selector is used, and $target components.",
          "$ref": "#/$defs/PatternNode"
        }
      }
    },
    "GhostVarDecl": {
      "type": "object",
      "description": "Optional ghost-cell variable declaration used by a discretization scheme (e.g. a periodic-BC halo). See RFC \u00a79 for boundary-condition interaction.",
      "required": [
        "name"
      ],
      "additionalProperties": false,
      "properties": {
        "name": {
          "type": "string",
          "description": "Ghost variable name."
        },
        "source": {
          "type": "string",
          "description": "How the ghost is populated: a symbolic hint like \"periodic\", \"copy\", \"reflect\" or a free-form note."
        },
        "description": {
          "type": "string"
        }
      }
    },
    "Discretization": {
      "type": "object",
      "description": "A named discretization scheme. Three kinds are supported: (a) \"stencil\" (default) \u2014 a template mapping a PDE operator class (via applies_to) to a combination (combine) over neighbors with symbolic coefficients (RFC \u00a77.1); (b) \"dimensional_split\" \u2014 a composite scheme that applies a 1D inner scheme along each of several orthogonal axes via Strang/Lie operator splitting (RFC \u00a77.5); (c) \"flux_form_semi_lagrangian\" \u2014 a flux-form semi-Lagrangian (FFSL) advection scheme (Lin & Rood 1996 MWR) that combines a piecewise reconstruction with flux-form remapping over declared advection axes, described in RFC \u00a77.7. A scheme may additionally carry a `grid_dispatch` block (RFC \u00a77.8) instead of an inline body \u2014 a list of {grid_family, body} variants whose body fields (stencil / inner_rule / etc.) replace the inline ones at load time, picked by the active grid's family.",
      "required": [
        "applies_to"
      ],
      "additionalProperties": false,
      "properties": {
        "kind": {
          "type": "string",
          "enum": [
            "stencil",
            "dimensional_split",
            "flux_form_semi_lagrangian"
          ],
          "default": "stencil",
          "description": "Scheme kind discriminator. \"stencil\" (default when omitted) selects the neighbor-combination template described in RFC \u00a77.1; \"dimensional_split\" selects the axis-sweep composite described in RFC \u00a77.5, which requires axes / inner_rule / splitting; \"flux_form_semi_lagrangian\" selects the FFSL advection family described in RFC \u00a77.7, which requires reconstruction / remap / cfl_policy / dimensions (and forbids stencil / axes / inner_rule)."
        },
        "applies_to": {
          "description": "Shallow (depth-1) AST pattern identifying the operator this scheme discretizes. Guard only \u2014 bindings flow from the triggering rule by name (RFC \u00a77.2.1). For dimensional_split schemes this names the N-D operator that the sweep composite stands in for (e.g. a 2D advection op whose inner_rule is a 1D PPM flux divergence).",
          "$ref": "#/$defs/PatternNode"
        },
        "grid_family": {
          "type": "string",
          "enum": [
            "cartesian",
            "unstructured"
          ],
          "description": "Grid family this scheme targets; the stencil's selector.kind must match this family. dimensional_split requires \"cartesian\" (unstructured grids have no intrinsic orthogonal-axis ordering)."
        },
        "combine": {
          "type": "string",
          "enum": [
            "+",
            "*",
            "min",
            "max"
          ],
          "default": "+",
          "description": "stencil: how stencil entries are combined. Not applicable to dimensional_split schemes."
        },
        "stencil": {
          "type": "array",
          "minItems": 1,
          "items": {
            "$ref": "#/$defs/StencilEntry"
          },
          "description": "stencil: array of {selector, coeff} entries. Exactly one entry for a reduction selector; one-or-more for the others (RFC \u00a77.1). Required when kind is \"stencil\" or omitted; must be absent when kind is \"dimensional_split\". Mutually exclusive with stencil_gen."
        },
        "stencil_gen": {
          "type": "object",
          "description": "Declarative stencil-weight generator (RFC \u00a77.1.3). Two modes: (1) spacing=<symbol> (uniform grid) \u2014 runs the Fornberg recurrence in exact rational arithmetic; (2) spacing=\"from_grid\" (non-uniform grid) \u2014 generates symbolic __stgfw_* weight array references computed at ODE-build time. Mutually exclusive with `stencil`. Scope: cartesian grids, first derivative (deriv_order=1), centered stagger.",
          "required": ["method", "deriv_order", "accuracy_order", "stagger", "axis", "spacing"],
          "additionalProperties": false,
          "properties": {
            "method": {
              "type": "string",
              "const": "fornberg",
              "description": "Weight-generation algorithm. Only \"fornberg\" is supported."
            },
            "deriv_order": {
              "type": "integer",
              "minimum": 1,
              "description": "Derivative order (only 1 currently supported)."
            },
            "accuracy_order": {
              "type": "integer",
              "minimum": 2,
              "multipleOf": 2,
              "description": "Truncation error order for centered differences (positive even integer: 2, 4, 6, 8, \u2026)."
            },
            "stagger": {
              "type": "string",
              "enum": ["centered"],
              "description": "Stencil symmetry (only \"centered\" is currently supported)."
            },
            "axis": {
              "type": "string",
              "description": "Cartesian axis along which the stencil is applied."
            },
            "spacing": {
              "type": "string",
              "description": "Spacing mode: a symbol name (e.g. \"dx\") for uniform grids, or the literal \"from_grid\" for non-uniform grids (generates __stgfw_* weight arrays)."
            }
          }
        },
        "axes": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "string"
          },
          "description": "dimensional_split: ordered list of spatial axes (names from the target grid's dimensions) along which the inner scheme is swept. Each axis is visited once per Lie step and twice (symmetrically) per Strang step. See RFC \u00a77.5."
        },
        "inner_rule": {
          "type": "string",
          "description": "dimensional_split: name of a sibling discretization scheme (must be declared under the enclosing file's \"discretizations\" section) that provides the 1D operator applied on each axis. The inner scheme is typically itself kind=\"stencil\" with grid_family=\"cartesian\" and a single cartesian axis in its selector."
        },
        "splitting": {
          "type": "string",
          "enum": [
            "strang",
            "lie",
            "none"
          ],
          "description": "dimensional_split: operator-splitting convention. \"lie\" applies each axis once in sequence (first-order in time). \"strang\" uses a symmetric half-step pattern with axes swept forward at \u0394t/2, the last axis applied at \u0394t, then the remaining axes swept in reverse at \u0394t/2 (second-order in time). \"none\" declares the composite structurally without prescribing a splitting order (e.g. for static metadata or parallel-split runtimes that choose their own order)."
        },
        "order_of_sweeps": {
          "type": "string",
          "enum": [
            "forward",
            "reverse",
            "alternating"
          ],
          "default": "forward",
          "description": "dimensional_split: optional direction pattern governing the per-timestep axis traversal. \"forward\" walks axes in listed order each step; \"reverse\" walks them in reverse; \"alternating\" flips direction on successive timesteps to reduce splitting bias (Strang-typical). Ignored when splitting is \"strang\" (which defines its own symmetric order) or \"none\"."
        },
        "reconstruction": {
          "description": "flux_form_semi_lagrangian (RFC \u00a77.7): the sub-cell reconstruction used to build cell-edge fluxes. Either a string naming a sibling discretizations entry (rule ref), or an inline object declaring a reconstruction scheme \u2014 `order` (e.g. \"PPM\", \"PLM\", \"centered\") plus optional free-form `parameters`. Composes with `limiter` when one is declared.",
          "oneOf": [
            {
              "type": "string",
              "description": "Name of a sibling discretizations entry providing the reconstruction stencil (e.g. PPM from ESD src/operators/reconstruction.jl)."
            },
            {
              "type": "object",
              "required": [
                "order"
              ],
              "additionalProperties": false,
              "properties": {
                "order": {
                  "type": "string",
                  "description": "Reconstruction order / family name (e.g. \"PPM\", \"PLM\", \"centered\", \"WENO5\"). Not an enum \u2014 runtimes may add families; unknown values are the rule engine's responsibility to reject."
                },
                "parameters": {
                  "type": "object",
                  "description": "Free-form key/value parameters for the reconstruction (e.g. monotonicity controls). Schema is intentionally open; consumers validate per-order.",
                  "additionalProperties": true
                }
              }
            }
          ]
        },
        "remap": {
          "type": "object",
          "description": "flux_form_semi_lagrangian (RFC \u00a77.7): flux-form remap semantics \u2014 how reconstructed sub-cell profiles are integrated across cell faces and used to update cell averages.",
          "required": [
            "semantics"
          ],
          "additionalProperties": false,
          "properties": {
            "semantics": {
              "type": "string",
              "enum": [
                "conservative",
                "non_conservative"
              ],
              "description": "Remap family. `conservative` preserves the volume-integrated tracer mass per Lin & Rood (1996) \u00a72. `non_conservative` uses pointwise trajectory remap (Staniforth & C\u00f4t\u00e9 1991)."
            },
            "flux_form": {
              "type": "string",
              "description": "Optional sub-kind identifier (e.g. \"lin_rood_1996\", \"colella_woodward_1984\")."
            },
            "parameters": {
              "type": "object",
              "description": "Free-form parameters for the remap (e.g. sub-cycle count, flux clipping thresholds).",
              "additionalProperties": true
            }
          }
        },
        "limiter": {
          "description": "flux_form_semi_lagrangian (RFC \u00a77.7): optional slope/flux limiter applied during reconstruction to preserve monotonicity. Either a string naming a sibling discretizations entry (rule ref \u2014 e.g. a named monotonic limiter scheme), or an inline object declaring a limiter family.",
          "oneOf": [
            {
              "type": "string",
              "description": "Name of a sibling discretizations entry providing the limiter stencil."
            },
            {
              "type": "object",
              "required": [
                "family"
              ],
              "additionalProperties": false,
              "properties": {
                "family": {
                  "type": "string",
                  "description": "Limiter family name (e.g. \"monotonic\", \"van_leer\", \"positive_definite\")."
                },
                "parameters": {
                  "type": "object",
                  "additionalProperties": true
                }
              }
            }
          ]
        },
        "cfl_policy": {
          "type": "string",
          "enum": [
            "conservative",
            "non_conservative"
          ],
          "description": "flux_form_semi_lagrangian (RFC \u00a77.7): CFL policy governing the reconstruction/remap pairing. `conservative`: mass-conserving flux-form (Lin & Rood 1996); `non_conservative`: pointwise SL trajectory without flux conservation."
        },
        "dimensions": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "string"
          },
          "description": "flux_form_semi_lagrangian (RFC \u00a77.7): axis names along which the rule advects, in application order. The named axes must appear in the enclosing grid's `dimensions`; each axis is swept once per step. Composes with dimensional_split (a dimensional_split scheme's `inner_rule` may reference an FFSL scheme whose `dimensions` is a single axis)."
        },
        "accuracy": {
          "type": "string",
          "description": "Informational: truncation order (e.g. \"O(dx^2)\", or for dimensional_split \"O(dt^2)\" under Strang splitting)."
        },
        "order": {
          "type": "integer",
          "minimum": 1,
          "description": "Optional scalar selector for stencil width / truncation order. Positive integer. For families that admit a parameterized order (e.g. arbitrary-order centered uniform finite differences via Fornberg-recursion weights), this field picks the concrete scheme: centered uniform FD uses positive even integers (2, 4, 6, 8, \u2026); one-sided or upwind schemes use any positive integer. Absence means the rule's default applies (e.g. the hard-coded order=2 of centered_2nd_uniform). The field is consumed by the rule engine / scheme authoring layer \u2014 schema accepts any positive integer; family-specific parity constraints (even for centered) are enforced by the rule implementation, not the schema. See discretization RFC \u00a77.1."
        },
        "requires_locations": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "If set, the operand variable must carry one of these staggered-grid locations."
        },
        "emits_location": {
          "type": "string",
          "description": "Staggered-grid location the scheme emits (e.g. \"cell_center\", \"edge_normal\"). Used to pin $target on unstructured grids (RFC \u00a77.1.1)."
        },
        "target_binding": {
          "type": "string",
          "default": "$target",
          "description": "Reserved name for the target index binding."
        },
        "ghost_vars": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/GhostVarDecl"
          },
          "description": "Optional ghost-cell variable declarations used by the scheme."
        },
        "free_variables": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "Optional list of free pattern-variable names (e.g. [\"$u\", \"$x\"]) that the scheme expects the triggering rule to bind; informational / for validator use."
        },
        "description": {
          "type": "string"
        },
        "reference": {
          "$ref": "#/$defs/Reference"
        },
        "requires": {
          "type": "object",
          "additionalProperties": {
            "type": "string",
            "pattern": "^[^#]+#[^#]+$",
            "description": "Provider reference in the form '<sibling-scheme>#<output-name>'."
          },
          "description": "RFC \u00a77.9 consumer demand map. Maps local names used inside this scheme's stencil/coeff expressions to outputs of sibling MultiOutputStencilRule providers in the form '<sibling-scheme>#<output-name>'."
        },
        "grid_dispatch": {
          "type": "array",
          "minItems": 1,
          "items": {
            "$ref": "#/$defs/DiscretizationVariant"
          },
          "description": "RFC \u00a77.8: family-keyed variant table. When present, the scheme declares one or more grid-family-specific bodies in place of an inline one \u2014 each variant carries its own `grid_family` plus the body fields (stencil / kind / axes / inner_rule / splitting / order_of_sweeps / terms / boundary_fallback / reconstruction / remap / limiter / cfl_policy / dimensions / combine) that would otherwise live on the parent. The loader picks the variant whose `grid_family` matches the active grid family at expansion time and substitutes its body in place of the parent's. Top-level `grid_family` and any inline body field MUST be absent when `grid_dispatch` is present; shared fields (`applies_to`, `accuracy`, `order`, `requires_locations`, `emits_location`, `target_binding`, `ghost_vars`, `free_variables`, `description`, `reference`) remain on the parent and apply to every variant. Each variant's `grid_family` MUST be unique within the array; ordering is not significant. The use case is operators whose form differs across grid topologies without forking the scheme name."
        }
      },
      "allOf": [
        {
          "if": {
            "required": [
              "grid_dispatch"
            ]
          },
          "then": {
            "not": {
              "anyOf": [
                {
                  "required": [
                    "grid_family"
                  ]
                },
                {
                  "required": [
                    "kind"
                  ]
                },
                {
                  "required": [
                    "combine"
                  ]
                },
                {
                  "required": [
                    "stencil"
                  ]
                },
                {
                  "required": [
                    "axes"
                  ]
                },
                {
                  "required": [
                    "inner_rule"
                  ]
                },
                {
                  "required": [
                    "splitting"
                  ]
                },
                {
                  "required": [
                    "order_of_sweeps"
                  ]
                },
                {
                  "required": [
                    "reconstruction"
                  ]
                },
                {
                  "required": [
                    "remap"
                  ]
                },
                {
                  "required": [
                    "limiter"
                  ]
                },
                {
                  "required": [
                    "cfl_policy"
                  ]
                },
                {
                  "required": [
                    "dimensions"
                  ]
                }
              ]
            }
          },
          "else": {
            "required": [
              "grid_family"
            ]
          }
        },
        {
          "if": {
            "properties": {
              "kind": {
                "const": "dimensional_split"
              }
            },
            "required": [
              "kind"
            ]
          },
          "then": {
            "required": [
              "axes",
              "inner_rule",
              "splitting"
            ],
            "not": {
              "anyOf": [
                {
                  "required": [
                    "stencil"
                  ]
                },
                {
                  "required": [
                    "reconstruction"
                  ]
                },
                {
                  "required": [
                    "remap"
                  ]
                },
                {
                  "required": [
                    "limiter"
                  ]
                },
                {
                  "required": [
                    "cfl_policy"
                  ]
                },
                {
                  "required": [
                    "dimensions"
                  ]
                }
              ]
            }
          }
        },
        {
          "if": {
            "properties": {
              "kind": {
                "const": "flux_form_semi_lagrangian"
              }
            },
            "required": [
              "kind"
            ]
          },
          "then": {
            "required": [
              "reconstruction",
              "remap",
              "cfl_policy",
              "dimensions"
            ],
            "not": {
              "anyOf": [
                {
                  "required": [
                    "stencil"
                  ]
                },
                {
                  "required": [
                    "axes"
                  ]
                },
                {
                  "required": [
                    "inner_rule"
                  ]
                },
                {
                  "required": [
                    "splitting"
                  ]
                }
              ]
            }
          }
        },
        {
          "if": {
            "allOf": [
              {
                "not": {
                  "required": [
                    "grid_dispatch"
                  ]
                }
              },
              {
                "anyOf": [
                  {
                    "not": {
                      "required": [
                        "kind"
                      ]
                    }
                  },
                  {
                    "properties": {
                      "kind": {
                        "const": "stencil"
                      }
                    },
                    "required": [
                      "kind"
                    ]
                  }
                ]
              }
            ]
          },
          "then": {
            "oneOf": [
              {"required": ["stencil"]},
              {"required": ["stencil_gen"]}
            ],
            "not": {
              "anyOf": [
                {
                  "required": [
                    "reconstruction"
                  ]
                },
                {
                  "required": [
                    "remap"
                  ]
                },
                {
                  "required": [
                    "limiter"
                  ]
                },
                {
                  "required": [
                    "cfl_policy"
                  ]
                },
                {
                  "required": [
                    "dimensions"
                  ]
                },
                {
                  "required": [
                    "axes"
                  ]
                },
                {
                  "required": [
                    "inner_rule"
                  ]
                },
                {
                  "required": [
                    "splitting"
                  ]
                }
              ]
            }
          }
        }
      ]
    },
    "DiscretizationVariant": {
      "type": "object",
      "description": "RFC \u00a77.8: one entry of a Discretization's `grid_dispatch` block. Declares a per-grid-family body that replaces the parent's inline body when the active grid's family matches `grid_family`. The body fields (`kind`, `combine`, `stencil`, `axes`, `inner_rule`, `splitting`, `order_of_sweeps`, `reconstruction`, `remap`, `limiter`, `cfl_policy`, `dimensions`) follow the same kind-discriminated semantics and mutual-exclusion rules as the parent Discretization. Shared fields (`applies_to`, `accuracy`, `order`, `requires_locations`, `emits_location`, `target_binding`, `ghost_vars`, `free_variables`, `description`, `reference`) live on the parent and are not duplicated here. A variant whose `grid_family` matches no active grid is inert. CrossMetricStencilRule entries (RFC \u00a77.6) are a sibling top-level shape and not eligible for `grid_dispatch`; author per-family CrossMetric rules as separate `discretizations` entries instead.",
      "required": [
        "grid_family"
      ],
      "additionalProperties": false,
      "properties": {
        "grid_family": {
          "type": "string",
          "enum": [
            "cartesian",
            "unstructured"
          ],
          "description": "Grid family this variant targets; selected when the active grid's family equals this value."
        },
        "kind": {
          "type": "string",
          "enum": [
            "stencil",
            "dimensional_split",
            "flux_form_semi_lagrangian"
          ],
          "default": "stencil",
          "description": "Variant kind discriminator; same vocabulary and semantics as the parent Discretization's `kind`."
        },
        "combine": {
          "type": "string",
          "enum": [
            "+",
            "*",
            "min",
            "max"
          ],
          "default": "+",
          "description": "Variant: how stencil entries are combined. See parent Discretization."
        },
        "stencil": {
          "type": "array",
          "minItems": 1,
          "items": {
            "$ref": "#/$defs/StencilEntry"
          },
          "description": "Variant: stencil entries. Required when this variant's kind is \"stencil\" or omitted."
        },
        "axes": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "string"
          },
          "description": "Variant: dimensional_split axes (or cross_metric axes when terms is present)."
        },
        "inner_rule": {
          "type": "string",
          "description": "Variant: dimensional_split inner scheme name."
        },
        "splitting": {
          "type": "string",
          "enum": [
            "strang",
            "lie",
            "none"
          ],
          "description": "Variant: dimensional_split operator-splitting convention."
        },
        "order_of_sweeps": {
          "type": "string",
          "enum": [
            "forward",
            "reverse",
            "alternating"
          ],
          "default": "forward",
          "description": "Variant: dimensional_split per-step traversal direction."
        },
        "reconstruction": {
          "description": "Variant: FFSL sub-cell reconstruction (string ref or inline {order, parameters}).",
          "oneOf": [
            {
              "type": "string"
            },
            {
              "type": "object",
              "required": [
                "order"
              ],
              "additionalProperties": false,
              "properties": {
                "order": {
                  "type": "string"
                },
                "parameters": {
                  "type": "object",
                  "additionalProperties": true
                }
              }
            }
          ]
        },
        "remap": {
          "type": "object",
          "required": [
            "semantics"
          ],
          "additionalProperties": false,
          "description": "Variant: FFSL flux-form remap semantics.",
          "properties": {
            "semantics": {
              "type": "string",
              "enum": [
                "conservative",
                "non_conservative"
              ]
            },
            "flux_form": {
              "type": "string"
            },
            "parameters": {
              "type": "object",
              "additionalProperties": true
            }
          }
        },
        "limiter": {
          "description": "Variant: FFSL limiter (string ref or inline {family, parameters}).",
          "oneOf": [
            {
              "type": "string"
            },
            {
              "type": "object",
              "required": [
                "family"
              ],
              "additionalProperties": false,
              "properties": {
                "family": {
                  "type": "string"
                },
                "parameters": {
                  "type": "object",
                  "additionalProperties": true
                }
              }
            }
          ]
        },
        "cfl_policy": {
          "type": "string",
          "enum": [
            "conservative",
            "non_conservative"
          ],
          "description": "Variant: FFSL CFL policy."
        },
        "dimensions": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "string"
          },
          "description": "Variant: FFSL advection axes."
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "kind": {
                "const": "dimensional_split"
              }
            },
            "required": [
              "kind"
            ]
          },
          "then": {
            "required": [
              "axes",
              "inner_rule",
              "splitting"
            ],
            "not": {
              "anyOf": [
                {
                  "required": [
                    "stencil"
                  ]
                },
                {
                  "required": [
                    "reconstruction"
                  ]
                },
                {
                  "required": [
                    "remap"
                  ]
                },
                {
                  "required": [
                    "limiter"
                  ]
                },
                {
                  "required": [
                    "cfl_policy"
                  ]
                },
                {
                  "required": [
                    "dimensions"
                  ]
                }
              ]
            }
          }
        },
        {
          "if": {
            "properties": {
              "kind": {
                "const": "flux_form_semi_lagrangian"
              }
            },
            "required": [
              "kind"
            ]
          },
          "then": {
            "required": [
              "reconstruction",
              "remap",
              "cfl_policy",
              "dimensions"
            ],
            "not": {
              "anyOf": [
                {
                  "required": [
                    "stencil"
                  ]
                },
                {
                  "required": [
                    "axes"
                  ]
                },
                {
                  "required": [
                    "inner_rule"
                  ]
                },
                {
                  "required": [
                    "splitting"
                  ]
                }
              ]
            }
          }
        },
        {
          "if": {
            "anyOf": [
              {
                "not": {
                  "required": [
                    "kind"
                  ]
                }
              },
              {
                "properties": {
                  "kind": {
                    "const": "stencil"
                  }
                },
                "required": [
                  "kind"
                ]
              }
            ]
          },
          "then": {
            "required": [
              "stencil"
            ],
            "not": {
              "anyOf": [
                {
                  "required": [
                    "reconstruction"
                  ]
                },
                {
                  "required": [
                    "remap"
                  ]
                },
                {
                  "required": [
                    "limiter"
                  ]
                },
                {
                  "required": [
                    "cfl_policy"
                  ]
                },
                {
                  "required": [
                    "dimensions"
                  ]
                },
                {
                  "required": [
                    "axes"
                  ]
                },
                {
                  "required": [
                    "inner_rule"
                  ]
                },
                {
                  "required": [
                    "splitting"
                  ]
                }
              ]
            }
          }
        }
      ]
    },
    "StaggeringRule": {
      "type": "object",
      "description": "A named staggering convention declaring where quantities live on a grid. The `kind` discriminant selects the staggering family. For MPAS Voronoi meshes (kind='unstructured_c_grid'), scalars live at Voronoi cell centers, normal velocities at edge midpoints, and vorticity at triangle vertices \u2014 a topology fundamentally unstructured. The referenced `grid` must be a grids.<g> entry of family 'unstructured'. See discretization RFC \u00a77.4.",
      "required": [
        "kind",
        "grid"
      ],
      "additionalProperties": false,
      "properties": {
        "kind": {
          "type": "string",
          "enum": [
            "unstructured_c_grid"
          ],
          "description": "Staggering family discriminant. v0.2.0 defines one kind: 'unstructured_c_grid' (MPAS Voronoi C-grid). Future kinds (e.g. 'arakawa_c_structured') require a spec bump."
        },
        "grid": {
          "type": "string",
          "description": "Name of a grids.<g> entry that this staggering rule applies to. For kind='unstructured_c_grid', the referenced grid's family must be 'unstructured' and its `locations` list must include the C-grid staples ('cell_center', 'edge_normal', 'vertex')."
        },
        "description": {
          "type": "string"
        },
        "cell_quantity_locations": {
          "type": "object",
          "description": "Mapping of quantity names (variable or metric names) to their staggered locations on the grid. Each value is one of the three C-grid staples. Consumers (e.g. the mpas_divergence_flux_form discretization) read this map to know that, e.g., normal-velocity `u` lives at 'edge_midpoint' so that flux divergence can be emitted at 'cell_center' via the reduction selector over edgesOnCell.",
          "additionalProperties": {
            "type": "string",
            "enum": [
              "cell_center",
              "edge_midpoint",
              "vertex"
            ]
          }
        },
        "edge_normal_convention": {
          "type": "string",
          "enum": [
            "outward_from_first_cell",
            "outward_from_second_cell",
            "right_hand_tangent"
          ],
          "description": "Orientation semantics for edge-normal fluxes. 'outward_from_first_cell' is the MPAS convention: the normal at edge e points from cellsOnEdge[e, 0] (interior) to cellsOnEdge[e, 1] (exterior). 'outward_from_second_cell' is the reverse. 'right_hand_tangent' orients by verticesOnEdge (used by some vorticity schemes)."
        },
        "dual_mesh_ref": {
          "type": "string",
          "description": "Optional name of a grids.<g> entry representing the Delaunay dual of the Voronoi primal grid. MPAS needs the dual mesh for vorticity computations at triangle vertices; leaving this unset is legal when the rule is used only for divergence/gradient schemes that do not touch vorticity."
        },
        "reference": {
          "$ref": "#/$defs/Reference"
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "kind": {
                "const": "unstructured_c_grid"
              }
            },
            "required": [
              "kind"
            ]
          },
          "then": {
            "required": [
              "cell_quantity_locations",
              "edge_normal_convention"
            ]
          }
        }
      ]
    },
    "CrossMetricTerm": {
      "type": "object",
      "description": "One term of a CrossMetricStencilRule composite expansion (RFC \u00a77.4). Semantically, the term contributes `sign * metric_component(target) * axis_stencil(field, axis)` to the composite, where `axis_stencil` names another Discretization whose expansion is substituted point-wise and `metric_component` names a metric array from the grid's metric_arrays block. Terms with identical `axis_stencil` but distinct `metric_component` are how cross-derivative composites (e.g. g_xieta \u00b7 \u2202\u00b2/\u2202\u03be\u2202\u03b7) are assembled.",
      "required": [
        "axis_stencil",
        "metric_component"
      ],
      "additionalProperties": false,
      "properties": {
        "axis_stencil": {
          "type": "string",
          "description": "Name of a per-axis Discretization entry (in the same discretizations block) whose expansion supplies this term's 1D directional derivative. Must resolve to a Discretization whose grid_family is compatible with the composite's grid_family."
        },
        "metric_component": {
          "type": "string",
          "description": "Name of a metric array (entry of the grid's metric_arrays block, e.g. 'J', 'g_xixi', 'g_etaeta', 'g_xieta', 'ginv_xixi'). Resolved point-wise at $target via the grid accessor's metric_eval contract."
        },
        "sign": {
          "type": "integer",
          "enum": [
            -1,
            1
          ],
          "default": 1,
          "description": "Sign applied to this term's contribution; defaults to +1."
        },
        "description": {
          "type": "string"
        }
      }
    },
    "CrossMetricStencilRule": {
      "type": "object",
      "description": "Cross-metric composite stencil rule (RFC \u00a77.4). Expresses operators whose discretization does not fit the single-axis stencil shape \u2014 specifically covariant PDE operators on curvilinear grids where metric-tensor components (J, g_xixi, g_etaeta, g_xieta, ginv_*) weight a sum of per-axis stencil applications. The canonical example is the full covariant Laplacian on a curvilinear grid, which combines \u2202/\u2202\u03be and \u2202/\u2202\u03b7 stencils with metric weights in a 9-point composite.\n\nExpansion semantics: given a rule match at $target, the composite expands to `\u03a3_terms[ sign_t \u00b7 metric_component_t($target) \u00b7 axis_stencil_t(field, axes_t) ]`, where each `axis_stencil_t` is the expansion of the referenced Discretization at $target along its declared axis. The composite's own `combine` field (default '+') determines how terms are combined.",
      "required": [
        "applies_to",
        "grid_family",
        "axes",
        "terms"
      ],
      "additionalProperties": false,
      "properties": {
        "kind": {
          "type": "string",
          "const": "cross_metric",
          "description": "Discriminator for bindings that need to distinguish this rule type from a standard Discretization. Optional (presence of `terms` is sufficient), but recommended for statically-typed bindings."
        },
        "applies_to": {
          "description": "Shallow (depth-1) AST pattern identifying the operator this composite discretizes (e.g. a 2D Laplacian). Guard only \u2014 bindings flow from the triggering rule by name (RFC \u00a77.2.1). Same shape as Discretization.applies_to.",
          "$ref": "#/$defs/PatternNode"
        },
        "grid_family": {
          "type": "string",
          "enum": [
            "cartesian",
            "unstructured"
          ],
          "description": "Grid family this composite targets. In practice cross-metric composites are primarily used on 'cartesian' (as a conformance-friendly degenerate case where off-diagonal metric components vanish)."
        },
        "axes": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "string"
          },
          "description": "Ordered list of coordinate axes the composition spans (e.g. ['xi','eta']). Each axis name must match an axis referenced by one of the composite's terms' axis_stencil. The order is informational (binding-readable) and does not affect expansion."
        },
        "combine": {
          "type": "string",
          "enum": [
            "+",
            "*",
            "min",
            "max"
          ],
          "default": "+",
          "description": "How the composite's terms are combined. Defaults to '+' (the natural choice for a summed tensor expansion)."
        },
        "terms": {
          "type": "array",
          "minItems": 1,
          "items": {
            "$ref": "#/$defs/CrossMetricTerm"
          },
          "description": "Array of CrossMetricTerm entries. Must contain at least one term."
        },
        "boundary_fallback": {
          "type": "string",
          "description": "Name of another Discretization or CrossMetricStencilRule (in the same discretizations block) to apply at edges or corners where the composite's full stencil cannot be evaluated (e.g. corner halos with incomplete metric support). Optional \u2014 when omitted, boundary handling falls through to the model's boundary_conditions."
        },
        "accuracy": {
          "type": "string",
          "description": "Informational: truncation order (e.g. 'O(dx^2)')."
        },
        "requires_locations": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "If set, the operand variable must carry one of these staggered-grid locations (mirrors Discretization.requires_locations)."
        },
        "emits_location": {
          "type": "string",
          "description": "Staggered-grid location the composite emits (mirrors Discretization.emits_location)."
        },
        "target_binding": {
          "type": "string",
          "default": "$target",
          "description": "Reserved name for the target index binding (mirrors Discretization.target_binding)."
        },
        "free_variables": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "Optional list of free pattern-variable names (e.g. ['$u']) that the composite expects the triggering rule to bind; informational / for validator use."
        },
        "description": {
          "type": "string"
        },
        "reference": {
          "$ref": "#/$defs/Reference"
        }
      }
    },
    "MultiOutputStencilRule": {
      "type": "object",
      "description": "Multi-output stencil rule (RFC §7.9). A scheme kind that emits multiple named output fields from one stencil application — the canonical use case is PPM reconstruction, which produces q_left_edge and q_right_edge from a single reconstruct(q, dim=x) operator match.",
      "required": [
        "applies_to",
        "outputs",
        "stencil"
      ],
      "additionalProperties": false,
      "properties": {
        "kind": {
          "type": "string",
          "const": "multi_output_stencil",
          "description": "Discriminator for bindings that need to distinguish this rule type from a standard Discretization or CrossMetricStencilRule."
        },
        "applies_to": {
          "description": "Shallow (depth-1) AST pattern identifying the operator this scheme discretizes.",
          "$ref": "#/$defs/PatternNode"
        },
        "grid_family": {
          "type": "string",
          "enum": [
            "cartesian",
            "unstructured"
          ],
          "description": "Grid family this scheme targets."
        },
        "outputs": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "string",
            "minLength": 1
          },
          "description": "Ordered list of named outputs emitted by this scheme. MUST equal the set of keys in `stencil`."
        },
        "stencil": {
          "type": "object",
          "minProperties": 1,
          "additionalProperties": {
            "type": "array",
            "minItems": 1,
            "items": {
              "$ref": "#/$defs/StencilEntry"
            }
          },
          "description": "Object keyed by output name; each value is a list of §7.1 stencil entries ({selector, coeff})."
        },
        "emits_location": {
          "type": "string",
          "description": "Default staggered-grid location for all emitted output variables (e.g. 'face', 'cell_center')."
        },
        "primary": {
          "oneOf": [
            { "type": "string", "minLength": 1 },
            { "type": "null" }
          ],
          "description": "Name of the output to substitute at the matched expression site. MUST be null or absent for provider-only schemes."
        },
        "accuracy": {
          "type": "string"
        },
        "order": {
          "type": "integer",
          "minimum": 1
        },
        "requires_locations": {
          "type": "array",
          "items": { "type": "string" }
        },
        "target_binding": {
          "type": "string"
        },
        "free_variables": {
          "type": "array",
          "items": { "type": "string" }
        },
        "description": {
          "type": "string"
        },
        "reference": {
          "$ref": "#/$defs/Reference"
        }
      }
    },
    "FunctionTable": {
      "type": "object",
      "description": "A sampled function table (esm-spec.md \u00a79.5). Carries one or more named axes and a literal nested-array data block. The shape of `data` is [len(outputs), len(axes[0].values), len(axes[1].values), ...] when `outputs` is declared; otherwise [len(axes[0].values), ...] (single-output convenience form). `table_lookup` AST nodes evaluate this table by supplying a per-axis input expression and selecting an output. Tables are syntactic sugar over `interp.linear` (1 axis) / `interp.bilinear` (2 axes) / `index` (nearest); the materialized AST a binding produces from a `table_lookup` MUST be bit-equivalent to the equivalent inline-const lookup.",
      "required": [
        "axes",
        "data"
      ],
      "additionalProperties": false,
      "properties": {
        "description": {
          "type": "string"
        },
        "axes": {
          "type": "array",
          "description": "Ordered list of named axes. The order of entries defines the order of inner dimensions in `data` (after the leading output dimension when `outputs` is present). Axis names within a single table MUST be unique.",
          "items": {
            "$ref": "#/$defs/FunctionTableAxis"
          },
          "minItems": 1,
          "maxItems": 2
        },
        "interpolation": {
          "type": "string",
          "description": "Interpolation kind applied by `table_lookup`. 'linear' (1 axis) lowers to `interp.linear`. 'bilinear' (2 axes) lowers to `interp.bilinear`. 'nearest' lowers to `index` after `interp.searchsorted`. The chosen kind MUST be consistent with the number of axes; mismatch is rejected at load time with diagnostic 'table_interpolation_axes_mismatch'.",
          "enum": [
            "linear",
            "bilinear",
            "nearest"
          ],
          "default": "linear"
        },
        "out_of_bounds": {
          "type": "string",
          "description": "Out-of-bounds policy applied to query coordinates that fall outside an axis range. 'clamp' pins to the nearest edge \u2014 this matches the semantics of `interp.linear` and `interp.bilinear` (extrapolate-flat). 'error' MUST raise at evaluation time; bindings emit diagnostic 'table_lookup_out_of_bounds' on first violation. v0.4.0: 'clamp' is the only policy required of all five bindings; 'error' is conformant when the binding implements it.",
          "enum": [
            "clamp",
            "error"
          ],
          "default": "clamp"
        },
        "outputs": {
          "type": "array",
          "description": "Optional ordered list of output names. When present, `table_lookup.output` MAY name an entry of this list (in addition to using a 0-based integer index). Names within a table MUST be unique. The leading dimension of `data` MUST equal the length of `outputs`.",
          "items": {
            "type": "string"
          },
          "minItems": 1
        },
        "data": {
          "description": "Nested-array literal carrying the table's sampled values. Leaves MUST be finite numbers (NaN entries are rejected at load time with 'table_data_nan'). Shape: [len(outputs), len(axes[0].values), ...] when `outputs` is present; [len(axes[0].values), ...] otherwise. Mismatched nesting is rejected with 'table_data_shape_mismatch'."
        },
        "shape": {
          "type": "array",
          "description": "Optional redundant shape assertion. If present, MUST match the actual nesting of `data`; loaders verify and reject mismatches with 'table_data_shape_mismatch'. `data` is the canonical representation; `shape` is a load-time assertion only.",
          "items": {
            "type": "integer",
            "minimum": 1
          },
          "minItems": 1
        },
        "schema_version": {
          "type": "string",
          "description": "Optional pin of the table-schema minor version this entry was authored against. Bindings ignore the value beyond a same-major-version compatibility check; informational for tooling.",
          "pattern": "^\\d+\\.\\d+\\.\\d+$"
        }
      }
    },
    "FunctionTableAxis": {
      "type": "object",
      "description": "A single named axis inside a FunctionTable. The `values` array supplies the sample coordinates along this axis; it MUST be strictly increasing finite floats with at least 2 entries (mirrors the `interp.linear` / `interp.bilinear` axis contract in \u00a79.2).",
      "required": [
        "name",
        "values"
      ],
      "additionalProperties": false,
      "properties": {
        "name": {
          "type": "string",
          "description": "Axis identifier. Used as the key in `table_lookup.axes` to bind the input-coordinate expression."
        },
        "units": {
          "type": "string",
          "description": "Optional advisory units string (e.g. 'Pa', 'K'). v0.4.0 records this for documentation only \u2014 no load-time unit checking is performed against the supplied input expression. Promotion to enforcement is deferred to a future units RFC."
        },
        "values": {
          "type": "array",
          "description": "Strictly-increasing finite floats. Bindings MUST reject non-monotonic axes at load time with diagnostic 'table_axis_non_monotonic' and NaN entries with 'table_axis_nan'.",
          "items": {
            "type": "number"
          },
          "minItems": 2
        }
      }
    }
  }
}

// Compile schema validator once at module load time
let validator: ValidateFunction

try {
  const ajv = new Ajv({
    allErrors: true,
    verbose: true,
    strict: false, // Allow unknown keywords for compatibility
    addUsedSchema: false, // Don't add the schema to cache
    validateSchema: false // Skip schema validation for now
  })
  addFormats(ajv)

  validator = ajv.compile(schema)
} catch (error) {
  throw new Error(`Failed to compile embedded ESM schema: ${error}`)
}

/**
 * Validate data against the ESM schema
 */
export function validateSchema(data: unknown): SchemaError[] {
  // Reject unsupported major versions before AJV validation.
  if (typeof data === 'object' && data !== null) {
    const esm = (data as Record<string, unknown>).esm
    if (typeof esm === 'string') {
      const v = parseSemanticVersion(esm)
      if (v !== null && v.major !== 0) {
        return [{
          path: '/esm',
          message: `Unsupported major version ${v.major}; this validator supports major version 0`,
          keyword: 'major_version_mismatch'
        }]
      }
    }
  }

  const isValid = validator(data)
  if (isValid || !validator.errors) {
    return []
  }

  return validator.errors.map((error: ErrorObject): SchemaError => ({
    path: error.instancePath || '/',
    message: error.message || 'Unknown validation error',
    keyword: error.keyword
  }))
}

/**
 * Parse JSON string safely
 */
function parseJson(input: string): unknown {
  try {
    return JSON.parse(input)
  } catch (error) {
    throw new ParseError(
      `Invalid JSON: ${error instanceof Error ? error.message : 'Unknown error'}`,
      error instanceof Error ? error : undefined
    )
  }
}

/**
 * Parse JSON string preserving integer-vs-float distinction via
 * `losslessJsonParse`. Numeric literals in the result are tagged
 * `NumericLiteral` leaves per RFC §5.4.1.
 */
function parseJsonLossless(input: string): unknown {
  try {
    return losslessJsonParse(input)
  } catch (error) {
    throw new ParseError(
      `Invalid JSON: ${error instanceof Error ? error.message : 'Unknown error'}`,
      error instanceof Error ? error : undefined,
    )
  }
}

/**
 * Recursively replace `NumericLiteral` leaves with their plain-number
 * value. Used to produce a plain view of a lossless-parsed document
 * for Ajv schema validation (the schema declares `type: number`, which
 * does not match tagged objects).
 *
 * Returns a new tree; input is not mutated. Non-literal objects and
 * arrays are shallow-copied only when a descendant is rewritten.
 */
function stripNumericLiterals(value: unknown): unknown {
  if (isNumericLiteral(value)) return value.value
  if (Array.isArray(value)) {
    let changed = false
    const out: unknown[] = new Array(value.length)
    for (let i = 0; i < value.length; i++) {
      const v = stripNumericLiterals(value[i])
      if (v !== value[i]) changed = true
      out[i] = v
    }
    return changed ? out : value
  }
  if (value && typeof value === 'object') {
    const src = value as Record<string, unknown>
    let changed = false
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(src)) {
      const v = stripNumericLiterals(src[key])
      if (v !== src[key]) changed = true
      out[key] = v
    }
    return changed ? out : value
  }
  return value
}

/**
 * Coerce types for better TypeScript compatibility
 * Handles Expression union types and discriminated unions
 */
function coerceTypes(data: any): any {
  if (data === null || data === undefined) {
    return data
  }

  // Canonical-mode tagged leaves are opaque — never descend into them.
  if (isNumericLiteral(data)) {
    return data
  }

  if (Array.isArray(data)) {
    return data.map(coerceTypes)
  }

  if (typeof data === 'object') {
    const result: any = {}

    for (const [key, value] of Object.entries(data)) {
      // Handle Expression types - they can be number, string, or ExpressionNode
      // ExpressionNode has 'op' and 'args' properties
      if (key === 'expression' || key === 'args' || /expr/i.test(key)) {
        result[key] = coerceExpression(value)
      } else {
        result[key] = coerceTypes(value)
      }
    }

    return result
  }

  return data
}

/**
 * Coerce Expression union type (number | string | ExpressionNode).
 * `NumericLiteral` tagged leaves (canonical-mode only) pass through
 * unchanged.
 */
function coerceExpression(value: any): Expression {
  if (typeof value === 'number' || typeof value === 'string') {
    return value
  }

  // NumericLiteral — canonical-mode tagged leaf; pass through.
  if (isNumericLiteral(value)) {
    return value as unknown as Expression
  }

  // If it's an object with 'op' and 'args', treat as ExpressionNode
  if (value && typeof value === 'object' && 'op' in value && 'args' in value) {
    return {
      ...value,
      args: Array.isArray(value.args) ? value.args.map(coerceExpression) : value.args
    }
  }

  return value
}

/**
 * Parse a semantic version string and return its components
 */
function parseSemanticVersion(versionString: string): { major: number; minor: number; patch: number } | null {
  const match = versionString.match(/^(\d+)\.(\d+)\.(\d+)$/)
  if (!match) {
    return null
  }

  return {
    major: parseInt(match[1], 10),
    minor: parseInt(match[2], 10),
    patch: parseInt(match[3], 10)
  }
}

/**
 * Check version compatibility for an ESM file
 */
function checkVersionCompatibility(data: any): void {
  if (typeof data !== 'object' || data === null) {
    return // Let schema validation handle this
  }

  const version = data.esm
  if (typeof version !== 'string') {
    return // Let schema validation handle this
  }

  const versionComponents = parseSemanticVersion(version)
  if (versionComponents === null) {
    return // Let schema validation handle invalid version format
  }

  const { major } = versionComponents
  const CURRENT_MAJOR = 0 // Current supported major version

  // Reject unsupported major versions
  if (major !== CURRENT_MAJOR) {
    throw new ParseError(`Unsupported major version ${major}. This parser supports major version ${CURRENT_MAJOR}.`)
  }
}

/**
 * Version-aware schema validation that handles backward/forward compatibility
 */
function validateSchemaWithVersionCompatibility(data: any): SchemaError[] {
  if (typeof data !== 'object' || data === null) {
    return validateSchema(data)
  }

  const version = data.esm
  if (typeof version !== 'string') {
    return validateSchema(data)
  }

  const versionComponents = parseSemanticVersion(version)
  if (versionComponents === null) {
    // If version parsing fails, use normal validation
    return validateSchema(data)
  }

  const { major, minor, patch } = versionComponents
  const CURRENT_VERSION = { major: 0, minor: 1, patch: 0 }

  // If it's the exact current version, use normal validation
  if (major === CURRENT_VERSION.major && minor === CURRENT_VERSION.minor && patch === CURRENT_VERSION.patch) {
    return validateSchema(data)
  }

  // Same major version: attempt backward/forward compatibility
  if (major === CURRENT_VERSION.major) {
    // Forward compatibility: newer minor version
    if (minor > CURRENT_VERSION.minor) {
      console.warn(`Forward compatibility: Version ${version} is newer than current ${CURRENT_VERSION.major}.${CURRENT_VERSION.minor}.${CURRENT_VERSION.patch}. Some features may not be fully supported.`)

      // Validate with current version substituted to check structural validity
      const tempData = { ...data, esm: '0.1.0' }
      const errors = validateSchema(tempData)

      // Filter out additionalProperties errors (unknown fields from newer versions)
      return errors.filter(error => {
        if (error.keyword === 'additionalProperties') {
          console.warn(`Forward compatibility: Ignoring unknown field at ${error.path}`)
          return false
        }
        return true
      })
    }

    // Backward compatibility or different patch: validate with current version substituted
    const tempData = { ...data, esm: '0.1.0' }
    return validateSchema(tempData)
  }

  // This shouldn't happen due to checkVersionCompatibility, but fallback to normal validation
  return validateSchema(data)
}

/**
 * Remove unknown fields for forward compatibility
 */
function removeUnknownFields(data: any): any {
  if (typeof data !== 'object' || data === null) {
    return data
  }

  const version = data.esm
  if (typeof version !== 'string') {
    return data
  }

  const versionComponents = parseSemanticVersion(version)
  if (versionComponents === null) {
    return data
  }

  const { major, minor } = versionComponents
  const CURRENT_VERSION = { major: 0, minor: 1, patch: 0 }

  // Only clean up for forward compatible versions (newer minor versions in the same major)
  if (major === CURRENT_VERSION.major && minor > CURRENT_VERSION.minor) {
    // Create a copy of the data and remove fields that would cause schema validation errors
    const cleanedData = { ...data }

    // Remove known forward compatibility fields that aren't in the current schema
    const unknownRootFields = ['performance_hints', 'validation_metadata', 'extended_metadata']
    unknownRootFields.forEach(field => {
      if (field in cleanedData) {
        delete cleanedData[field]
      }
    })

    // Recursively clean model and reaction system objects
    if (cleanedData.models) {
      cleanedData.models = cleanModels(cleanedData.models)
    }
    if (cleanedData.reaction_systems) {
      cleanedData.reaction_systems = cleanReactionSystems(cleanedData.reaction_systems)
    }

    return cleanedData
  }

  return data
}

/**
 * Clean unknown fields from models
 */
function cleanModels(models: any): any {
  if (typeof models !== 'object' || models === null) {
    return models
  }

  const cleaned: any = {}
  for (const [key, model] of Object.entries(models)) {
    if (typeof model === 'object' && model !== null) {
      const cleanedModel: any = { ...model }
      // Remove known forward compatibility fields
      const unknownModelFields = ['solver_hints', 'optimization_flags']
      unknownModelFields.forEach(field => {
        if (field in cleanedModel) {
          delete cleanedModel[field]
        }
      })
      cleaned[key] = cleanedModel
    } else {
      cleaned[key] = model
    }
  }
  return cleaned
}

/**
 * Clean unknown fields from reaction systems
 */
function cleanReactionSystems(reactionSystems: any): any {
  if (typeof reactionSystems !== 'object' || reactionSystems === null) {
    return reactionSystems
  }

  const cleaned: any = {}
  for (const [key, system] of Object.entries(reactionSystems)) {
    if (typeof system === 'object' && system !== null) {
      const cleanedSystem: any = { ...system }

      // Clean reactions array
      if (Array.isArray(cleanedSystem.reactions)) {
        cleanedSystem.reactions = cleanedSystem.reactions.map((reaction: any) => {
          if (typeof reaction === 'object' && reaction !== null) {
            const cleanedReaction: any = { ...reaction }
            // Remove known forward compatibility fields from reactions
            const unknownReactionFields = ['kinetics_metadata', 'thermodynamic_data']
            unknownReactionFields.forEach(field => {
              if (field in cleanedReaction) {
                delete cleanedReaction[field]
              }
            })
            return cleanedReaction
          }
          return reaction
        })
      }

      cleaned[key] = cleanedSystem
    } else {
      cleaned[key] = system
    }
  }
  return cleaned
}

/**
 * Post-schema validation for grid metric/connectivity generators (RFC §6.5).
 *
 * For every `GridMetricGenerator` found under `grids.<name>.metric_arrays`
 * or `grids.<name>.connectivity`:
 *   - kind='loader' requires the loader name to exist in top-level
 *     `data_loaders`. Otherwise throws `E_UNKNOWN_LOADER`.
 *   - kind='builtin' requires the `name` to be in the closed
 *     `KNOWN_GRID_BUILTINS` set. Otherwise throws `E_UNKNOWN_BUILTIN`.
 */
function validateGridGenerators(data: any): void {
  if (!data || typeof data !== 'object') return
  const grids = data.grids
  if (!grids || typeof grids !== 'object') return

  const dataLoaders = (data.data_loaders && typeof data.data_loaders === 'object')
    ? data.data_loaders
    : {}

  const checkGenerator = (gen: any, where: string): void => {
    if (!gen || typeof gen !== 'object') return
    if (gen.kind === 'loader') {
      const name = gen.loader
      if (typeof name !== 'string' || !(name in dataLoaders)) {
        throw new GridValidationError(
          `[E_UNKNOWN_LOADER] ${where}: generator references data_loaders.${name} which is not defined.`,
          'E_UNKNOWN_LOADER'
        )
      }
    } else if (gen.kind === 'builtin') {
      const name = gen.name
      if (typeof name !== 'string' || !KNOWN_GRID_BUILTINS.has(name)) {
        throw new GridValidationError(
          `[E_UNKNOWN_BUILTIN] ${where}: '${name}' is not a recognized grid builtin. ` +
            `Known builtins: ${Array.from(KNOWN_GRID_BUILTINS).join(', ')}.`,
          'E_UNKNOWN_BUILTIN'
        )
      }
    }
  }

  for (const [gridName, grid] of Object.entries(grids)) {
    if (!grid || typeof grid !== 'object') continue
    const g = grid as Record<string, any>

    if (g.metric_arrays && typeof g.metric_arrays === 'object') {
      for (const [arrName, arr] of Object.entries(g.metric_arrays)) {
        if (arr && typeof arr === 'object' && 'generator' in (arr as object)) {
          checkGenerator(
            (arr as any).generator,
            `grids.${gridName}.metric_arrays.${arrName}.generator`
          )
        }
      }
    }

    for (const bucket of ['connectivity'] as const) {
      if (g[bucket] && typeof g[bucket] === 'object') {
        for (const [tblName, tbl] of Object.entries(g[bucket])) {
          if (!tbl || typeof tbl !== 'object') continue
          const t = tbl as Record<string, any>
          // Connectivity tables may have either a generator or a
          // loader/field pair (unstructured).
          if ('generator' in t) {
            checkGenerator(t.generator, `grids.${gridName}.${bucket}.${tblName}.generator`)
          } else if ('loader' in t) {
            const name = t.loader
            if (typeof name !== 'string' || !(name in dataLoaders)) {
              throw new GridValidationError(
                `[E_UNKNOWN_LOADER] grids.${gridName}.${bucket}.${tblName}: ` +
                  `loader '${name}' is not defined in top-level data_loaders.`,
                'E_UNKNOWN_LOADER'
              )
            }
          }
        }
      }
    }
  }
}

/**
 * Options controlling how `load()` parses and represents an ESM file.
 */
export interface LoadOptions {
  /**
   * When `true`, numeric literals at Expression-bearing positions are
   * decoded to tagged `NumericLiteral` leaves (see
   * {@link losslessJsonParse}) so downstream consumers can preserve the
   * integer-vs-float distinction required by the canonical form
   * (discretization RFC §5.4.1 / §5.4.6). When `false` or absent
   * (default), numeric literals decode to plain JS numbers for
   * backwards compatibility.
   *
   * Canonical mode only takes effect for string inputs; pre-parsed
   * objects are returned as-is (callers that want tagged leaves should
   * run `losslessJsonParse` themselves before passing the object in).
   */
  canonical?: boolean
}

/**
 * Load an ESM file from a JSON string or pre-parsed object
 *
 * @param input - JSON string or pre-parsed JavaScript object
 * @param options - Optional load-time settings (see {@link LoadOptions})
 * @returns Typed EsmFile object
 * @throws {ParseError} When JSON parsing fails or version is incompatible
 * @throws {SchemaValidationError} When schema validation fails
 */
export function load(input: string | object, options?: LoadOptions): EsmFile {
  const canonical = options?.canonical === true

  // Step 1: JSON parsing. In canonical mode, decode tagged numeric
  // literals and keep a separate plain view for Ajv schema validation
  // (the schema declares `type: number`, which does not match tagged
  // `NumericLiteral` objects).
  let data: unknown
  let validationView: unknown
  if (typeof input === 'string') {
    if (canonical) {
      data = parseJsonLossless(input)
      validationView = stripNumericLiterals(data)
    } else {
      data = parseJson(input)
      validationView = data
    }
  } else {
    data = input
    validationView = canonical ? stripNumericLiterals(input) : input
  }

  // Step 2: Version compatibility check (before schema validation)
  checkVersionCompatibility(validationView)

  // Step 2a: v0.3.0 file-boundary rejection of removed v0.2.x extension
  // points (esm-spec §9 / closed function registry RFC). Mirrors the
  // Julia ref `parse.jl` rejection so cross-binding behavior is uniform.
  rejectRemovedV02Blocks(validationView)

  // Step 2b: v0.4.0 expression_templates / apply_expression_template are
  // rejected when the file declares esm < 0.4.0 (RFC §5.4 spec-version gate).
  // Surfaced with a stable diagnostic before schema validation so the user
  // sees the version hint instead of a generic "extra property" error.
  rejectExpressionTemplatesPreV04(validationView)

  // Step 3: Schema validation with version compatibility
  const schemaErrors = validateSchemaWithVersionCompatibility(validationView)
  if (schemaErrors.length > 0) {
    throw new SchemaValidationError(
      `Schema validation failed with ${schemaErrors.length} error(s)`,
      schemaErrors
    )
  }

  // Step 3a: Expand all `apply_expression_template` ops at load time
  // (esm-spec §9.6 / docs/rfcs/ast-expression-templates.md). After this
  // pass, the file's expression trees contain no apply_expression_template
  // nodes and no `expression_templates` blocks — downstream consumers see
  // only normal Expression ASTs (Option A round-trip).
  data = lowerExpressionTemplates(data as object)

  // Step 4: Clean up unknown fields for forward compatibility and type coercion
  const cleanedData = removeUnknownFields(data)
  const typedData = coerceTypes(cleanedData) as EsmFile

  // Step 4a: Emit E_DEPRECATED_DOMAIN_BC for any v0.1.0-style domain-level
  // boundary_conditions (v0.2.0 transitional shim per RFC §10.1 +
  // gt-2fvs mayor decision). A follow-up bead flips this to a hard error.
  if (typedData && typeof typedData === 'object' && 'domains' in typedData) {
    const domains = (typedData as Record<string, unknown>).domains
    if (domains && typeof domains === 'object') {
      for (const [domainName, domain] of Object.entries(domains)) {
        if (
          domain &&
          typeof domain === 'object' &&
          'boundary_conditions' in (domain as Record<string, unknown>)
        ) {
          // eslint-disable-next-line no-console
          console.warn(
            `[E_DEPRECATED_DOMAIN_BC] domains.${domainName}.boundary_conditions ` +
              `is deprecated in ESM v0.2.0; migrate to ` +
              `models.<M>.boundary_conditions (docs/rfcs/discretization.md §9).`
          )
        }
      }
    }
  }

  // Step 4b: Lower `enum` ops to `const` integer nodes against the
  // file-local `enums` block (esm-spec §9.3). After this pass, the
  // codegen runner sees only `const` — `evaluateExpression()` rejects
  // any leftover `enum` op as an unlowered file.
  const loweredData = lowerEnums(typedData)

  // Step 4c: Grid generator validation (RFC §6).
  //   - For kind='loader': the referenced loader name must exist in top-level data_loaders.
  //   - For kind='builtin': name must be one of the closed set of canonical builtins
  //     (currently empty); unknown names are rejected with E_UNKNOWN_BUILTIN per §6.4.1.
  validateGridGenerators(loweredData)

  // Step 5: Dimensional analysis — emit warnings but never fail the load.
  // Mirrors the Julia @warn behavior so TS callers get the same signal
  // without an API break.
  for (const warning of validateUnits(loweredData)) {
    const location = warning.location ? ` [${warning.location}]` : ''
    console.warn(`ESM unit validation${location}: ${warning.message}`)
  }

  return loweredData
}

/**
 * Reject the v0.2.x extension points that v0.3.0 closed (esm-spec §9 /
 * docs/rfcs/closed-function-registry.md):
 *
 *   - top-level `operators` block — replaced by AST equations + named
 *     `discretizations` schemes.
 *   - top-level `registered_functions` block — replaced by the closed
 *     `fn`-op registry (datetime + interp.searchsorted).
 *   - any expression-tree `call` op — replaced by `fn`.
 *
 * Throws `SchemaValidationError` with one entry per offending location
 * so the caller surfaces all of them at once. Operates on the
 * pre-coercion view (plain JS objects) so it sees `op: "call"` exactly
 * as the file declared it.
 */
function rejectRemovedV02Blocks(view: unknown): void {
  if (!view || typeof view !== 'object') return
  const errors: SchemaError[] = []
  const root = view as Record<string, unknown>

  if ('operators' in root) {
    errors.push({
      path: '/operators',
      keyword: 'removed_in_v0_3',
      message: "top-level 'operators' block was removed in ESM v0.3.0; migrate to AST equations + 'discretizations' (closed-function-registry RFC §6).",
    })
  }
  if ('registered_functions' in root) {
    errors.push({
      path: '/registered_functions',
      keyword: 'removed_in_v0_3',
      message: "top-level 'registered_functions' block was removed in ESM v0.3.0; migrate to the closed 'fn'-op registry (esm-spec §9.2).",
    })
  }

  // Walk the tree looking for `call` ops anywhere they could appear.
  const callPaths: string[] = []
  const walk = (node: unknown, path: string): void => {
    if (!node) return
    if (Array.isArray(node)) {
      for (let i = 0; i < node.length; i++) walk(node[i], `${path}/${i}`)
      return
    }
    if (typeof node !== 'object') return
    const obj = node as Record<string, unknown>
    if (obj.op === 'call') callPaths.push(path)
    for (const k of Object.keys(obj)) walk(obj[k], `${path}/${k}`)
  }
  walk(root, '')
  for (const p of callPaths) {
    errors.push({
      path: p,
      keyword: 'removed_in_v0_3',
      message: "'call' AST op was removed in ESM v0.3.0; migrate to AST equations or the closed 'fn'-op registry (esm-spec §9.2).",
    })
  }

  if (errors.length > 0) {
    throw new SchemaValidationError(
      `ESM v0.3.0 rejects ${errors.length} removed v0.2.x construct(s)`,
      errors,
    )
  }
}