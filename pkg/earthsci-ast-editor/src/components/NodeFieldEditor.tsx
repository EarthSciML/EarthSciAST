/**
 * NodeFieldEditor - Inline field editor for structural / array expression ops
 *
 * Many ESM ops (esm-spec §4.2) carry information in dedicated NON-`args` fields
 * rather than only in their argument list: `D` uses `wrt`, `const` uses `value`,
 * `table_lookup` uses `table`/`axes`/`output`, `aggregate` uses
 * `output_idx`/`reduce`/`semiring`/`expr`/`ranges`/… and so on. The recursive
 * ExpressionNode renderer edits `args` in place, but those scalar / map / list
 * fields need a dedicated form.
 *
 * This module provides:
 * - `opHasFieldEditor(op)` - whether an op exposes editable non-`args` fields
 * - `NodeFieldEditor` - an InlineForm that reads a node's fields, validates the
 *   inputs on submit (JSON / list parsing errors surface inline), rebuilds the
 *   node preserving its `args`, and applies it via the node's `onReplace`.
 *
 * The build helpers (`serializeField`, `buildUpdatedNode`) are exported for
 * unit testing the round-trip without driving the UI.
 */

import { Component } from 'solid-js';
import type { Expression, ExpressionNode as ExprNode } from '@earthsciml/ast';
import { CLOSED_FUNCTION_NAMES } from '@earthsciml/ast';
import { InlineForm, type InlineFormField } from './InlineForm';
import './node-field-editor.css';

/** How a field's string form maps to / from its stored JSON value. */
type FieldType =
  | 'string' // free text stored as a string
  | 'select' // one-of a fixed option set, stored as a string
  | 'number' // parsed as a finite number
  | 'const-value' // a number, or JSON for arrays (the `const` op's `value`)
  | 'json' // any JSON value / Expression subtree / object map
  | 'intlist' // comma-separated or JSON list of integers
  | 'mixedlist' // comma-separated or JSON list of integers and/or strings
  | 'bool'; // rendered as a false/true select

interface OpFieldSpec {
  /** Key of this field on the op node (or a synthetic `__enum*` key). */
  name: string;
  label: string;
  type: FieldType;
  /** Options for `select` fields. */
  options?: readonly string[];
  /** When true, an empty input omits the field instead of erroring. */
  optional?: boolean;
  /** Render a textarea (for JSON / map / list fields). */
  multiline?: boolean;
  placeholder?: string;
}

const MANIFOLD_OPTIONS = ['planar', 'spherical', 'geodesic'] as const;
const REDUCE_OPTIONS = ['+', '*', 'max', 'min'] as const;
const SEMIRING_OPTIONS = ['sum_product', 'max_product', 'min_sum', 'max_sum', 'bool_and_or'] as const;

/**
 * Per-op editable non-`args` fields (esm-spec §4.2 / esm-schema.json). Ops
 * absent from this table have no field editor (their content lives entirely in
 * `args`, edited in place by ExpressionNode) — e.g. `index`, `true`.
 */
const OP_FIELD_SPECS: Record<string, OpFieldSpec[]> = {
  const: [{ name: 'value', label: 'Value', type: 'const-value', placeholder: '0 or [1, 2, 3]' }],
  D: [{ name: 'wrt', label: 'With respect to', type: 'string', placeholder: 'e.g. t' }],
  fn: [{ name: 'name', label: 'Function', type: 'select', options: CLOSED_FUNCTION_NAMES }],
  // `enum` carries its type/member in args[0]/args[1] (synthetic keys below).
  enum: [
    { name: '__enumType', label: 'Enum type', type: 'string', placeholder: 'e.g. Season' },
    { name: '__enumMember', label: 'Member', type: 'string', placeholder: 'e.g. summer' }
  ],
  broadcast: [{ name: 'fn', label: 'Scalar op', type: 'string', placeholder: 'e.g. +' }],
  integral: [
    { name: 'var', label: 'Variable', type: 'string', placeholder: 'e.g. x' },
    { name: 'lower', label: 'Lower bound', type: 'json', multiline: true, placeholder: '0' },
    { name: 'upper', label: 'Upper bound', type: 'json', multiline: true, placeholder: '1' }
  ],
  table_lookup: [
    { name: 'table', label: 'Table id', type: 'string' },
    { name: 'axes', label: 'Axes (JSON map)', type: 'json', multiline: true, placeholder: '{"x": "temperature"}' },
    { name: 'output', label: 'Output (optional)', type: 'string', optional: true }
  ],
  apply_expression_template: [
    { name: 'name', label: 'Template id', type: 'string' },
    { name: 'bindings', label: 'Bindings (JSON map)', type: 'json', multiline: true, placeholder: '{"p": 1}' }
  ],
  makearray: [
    { name: 'regions', label: 'Regions (JSON)', type: 'json', multiline: true, placeholder: '[[[1, 3]]]' },
    { name: 'values', label: 'Values (JSON)', type: 'json', multiline: true, placeholder: '[0]' }
  ],
  reshape: [{ name: 'shape', label: 'Shape', type: 'mixedlist', placeholder: '2, 3 or ["m", "n"]' }],
  transpose: [{ name: 'perm', label: 'Permutation (optional)', type: 'intlist', optional: true, placeholder: '1, 0' }],
  concat: [{ name: 'axis', label: 'Axis', type: 'number', placeholder: '0' }],
  intersect_polygon: [{ name: 'manifold', label: 'Manifold', type: 'select', options: MANIFOLD_OPTIONS }],
  polygon_intersection_area: [{ name: 'manifold', label: 'Manifold', type: 'select', options: MANIFOLD_OPTIONS }],
  aggregate: [
    { name: 'output_idx', label: 'Output indices', type: 'mixedlist', placeholder: 'i, j' },
    { name: 'reduce', label: 'Reduce', type: 'select', options: REDUCE_OPTIONS },
    { name: 'semiring', label: 'Semiring', type: 'select', options: SEMIRING_OPTIONS },
    { name: 'expr', label: 'Body expr (JSON)', type: 'json', multiline: true, placeholder: '"x"' },
    { name: 'ranges', label: 'Ranges (JSON, optional)', type: 'json', multiline: true, optional: true, placeholder: '{"i": [1, 10]}' },
    { name: 'join', label: 'Join (JSON, optional)', type: 'json', multiline: true, optional: true },
    { name: 'filter', label: 'Filter (JSON, optional)', type: 'json', multiline: true, optional: true },
    { name: 'distinct', label: 'Distinct', type: 'bool' },
    { name: 'key', label: 'Key (JSON, optional)', type: 'json', multiline: true, optional: true }
  ],
  argmin: [
    { name: 'arg', label: 'Arg index', type: 'string', placeholder: 'e.g. g' },
    { name: 'expr', label: 'Body expr (JSON)', type: 'json', multiline: true },
    { name: 'ranges', label: 'Ranges (JSON, optional)', type: 'json', multiline: true, optional: true }
  ],
  argmax: [
    { name: 'arg', label: 'Arg index', type: 'string', placeholder: 'e.g. g' },
    { name: 'expr', label: 'Body expr (JSON)', type: 'json', multiline: true },
    { name: 'ranges', label: 'Ranges (JSON, optional)', type: 'json', multiline: true, optional: true }
  ]
};

/** Whether an op exposes editable non-`args` fields via this editor. */
export function opHasFieldEditor(op: string): boolean {
  return Object.prototype.hasOwnProperty.call(OP_FIELD_SPECS, op);
}

/** The InlineForm-ready field specs for an op (empty when it has no editor). */
export function getOpFieldSpecs(op: string): OpFieldSpec[] {
  return OP_FIELD_SPECS[op] ?? [];
}

/** Read a node's current value for a field as the string the form displays. */
export function serializeField(node: ExprNode, spec: OpFieldSpec): string {
  const anyNode = node as unknown as Record<string, unknown>;

  // `enum` synthetic fields read from args.
  if (spec.name === '__enumType') return String((node.args?.[0] as string | undefined) ?? '');
  if (spec.name === '__enumMember') return String((node.args?.[1] as string | undefined) ?? '');

  const value = anyNode[spec.name];

  switch (spec.type) {
    case 'const-value':
      return value === undefined ? '0' : JSON.stringify(value);
    case 'json':
      return value === undefined ? '' : JSON.stringify(value);
    case 'intlist':
    case 'mixedlist':
      return Array.isArray(value) ? value.join(', ') : '';
    case 'bool':
      return value ? 'true' : 'false';
    case 'select':
      return value !== undefined ? String(value) : (spec.options?.[0] ?? '');
    default:
      return value !== undefined && value !== null ? String(value) : '';
  }
}

type ParseResult =
  | { value: unknown }
  | { omit: true }
  | { error: string };

/** Split a "comma-separated or JSON array" input into raw parts / JSON array. */
function parseListInput(text: string): unknown[] | { error: string } {
  const trimmed = text.trim();
  if (trimmed.startsWith('[')) {
    try {
      const parsed = JSON.parse(trimmed);
      if (!Array.isArray(parsed)) return { error: 'must be a JSON array' };
      return parsed;
    } catch {
      return { error: 'invalid JSON array' };
    }
  }
  return trimmed
    .split(',')
    .map(part => part.trim())
    .filter(part => part.length > 0);
}

/** Parse one field's string input into its stored value (or an omit/error). */
function parseField(raw: string, spec: OpFieldSpec): ParseResult {
  const trimmed = raw.trim();
  const empty = trimmed.length === 0;

  switch (spec.type) {
    case 'string':
    case 'select': {
      if (empty) return spec.optional ? { omit: true } : { value: '' };
      // `output` on table_lookup is an int-or-string selector.
      if (spec.name === 'output' && /^\d+$/.test(trimmed)) {
        return { value: Number(trimmed) };
      }
      return { value: trimmed };
    }

    case 'number': {
      if (empty) return spec.optional ? { omit: true } : { error: 'must be a number' };
      const n = Number(trimmed);
      if (!Number.isFinite(n)) return { error: 'must be a number' };
      return { value: n };
    }

    case 'const-value': {
      if (empty) return { error: 'must be a number or JSON array' };
      if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
        try {
          return { value: JSON.parse(trimmed) };
        } catch {
          return { error: 'invalid JSON' };
        }
      }
      const n = Number(trimmed);
      if (!Number.isFinite(n)) return { error: 'must be a number or JSON array' };
      return { value: n };
    }

    case 'json': {
      if (empty) return spec.optional ? { omit: true } : { error: 'must be valid JSON' };
      try {
        return { value: JSON.parse(trimmed) };
      } catch {
        return { error: 'invalid JSON' };
      }
    }

    case 'intlist': {
      if (empty) return spec.optional ? { omit: true } : { error: 'must be a list of integers' };
      const parts = parseListInput(trimmed);
      if (!Array.isArray(parts)) return parts;
      const out: number[] = [];
      for (const part of parts) {
        const n = typeof part === 'number' ? part : Number(part);
        if (!Number.isInteger(n)) return { error: 'entries must be integers' };
        out.push(n);
      }
      return { value: out };
    }

    case 'mixedlist': {
      if (empty) return spec.optional ? { omit: true } : { error: 'must be a non-empty list' };
      const parts = parseListInput(trimmed);
      if (!Array.isArray(parts)) return parts;
      const out: (number | string)[] = parts.map(part => {
        if (typeof part === 'number') return part;
        const s = String(part);
        return /^-?\d+$/.test(s) ? Number(s) : s;
      });
      return { value: out };
    }

    case 'bool':
      // false is the schema default → omit it to keep the node minimal.
      return trimmed === 'true' ? { value: true } : { omit: true };

    default:
      return { value: trimmed };
  }
}

/**
 * Rebuild an op node from submitted form values, preserving `args` (and any
 * fields not exposed by the editor, e.g. `id`). Returns the new node, or an
 * error string to keep the form open with an inline message.
 */
export function buildUpdatedNode(
  node: ExprNode,
  values: Record<string, string>
): ExprNode | string {
  const specs = getOpFieldSpecs(node.op);
  const next = { ...node } as ExprNode & Record<string, unknown>;

  // `enum` edits args[0] (type) and args[1] (member) directly.
  if (node.op === 'enum') {
    const type = (values.__enumType ?? '').trim();
    const member = (values.__enumMember ?? '').trim();
    next.args = [type, member] as Expression[];
    return next;
  }

  for (const spec of specs) {
    const result = parseField(values[spec.name] ?? '', spec);
    if ('error' in result) return `${spec.label}: ${result.error}`;
    if ('omit' in result) {
      delete next[spec.name];
    } else {
      next[spec.name] = result.value;
    }
  }

  return next;
}

export interface NodeFieldEditorProps {
  /** The operator node being edited. */
  node: ExprNode;
  /** AST path of the node (passed to `onReplace`). */
  path: (string | number)[];
  /** Apply the rebuilt node. */
  onReplace: (path: (string | number)[], newExpr: Expression) => void;
  /** Close the editor. */
  onClose: () => void;
}

/**
 * InlineForm-based editor for an op node's non-`args` fields. Renders one
 * input per field, validates on submit, and applies the rebuilt node.
 */
export const NodeFieldEditor: Component<NodeFieldEditorProps> = (props) => {
  const specs = getOpFieldSpecs(props.node.op);

  const fields: InlineFormField[] = specs.map(spec => ({
    name: spec.name,
    label: spec.label,
    initial: serializeField(props.node, spec),
    placeholder: spec.placeholder,
    multiline: spec.multiline,
    options:
      spec.type === 'select'
        ? spec.options
        : spec.type === 'bool'
          ? (['false', 'true'] as const)
          : undefined
  }));

  const handleConfirm = (values: Record<string, string>): string | void => {
    const result = buildUpdatedNode(props.node, values);
    if (typeof result === 'string') return result;
    props.onReplace(props.path, result);
    props.onClose();
  };

  return (
    <div class="esm-field-editor-popover" role="dialog" aria-label={`Edit ${props.node.op} fields`}>
      <InlineForm
        title={`Edit ${props.node.op}`}
        fields={fields}
        confirmLabel="Apply"
        onConfirm={handleConfirm}
        onCancel={props.onClose}
      />
    </div>
  );
};

export default NodeFieldEditor;
