/**
 * Tests for NodeFieldEditor - field editor for structural / array ops.
 */

import { render, screen, fireEvent } from '@solidjs/testing-library';
import { describe, it, expect, vi } from 'vitest';
import type { ExpressionNode as ExprNode } from 'earthsci-toolkit';
import {
  NodeFieldEditor,
  opHasFieldEditor,
  buildUpdatedNode,
  serializeField,
  getOpFieldSpecs
} from './NodeFieldEditor';

describe('opHasFieldEditor', () => {
  it('recognises ops with editable non-args fields', () => {
    for (const op of ['const', 'D', 'fn', 'enum', 'aggregate', 'table_lookup', 'intersect_polygon', 'reshape', 'concat']) {
      expect(opHasFieldEditor(op)).toBe(true);
    }
  });

  it('returns false for ops whose content lives entirely in args', () => {
    for (const op of ['+', 'index', 'true', 'sin', 'ifelse']) {
      expect(opHasFieldEditor(op)).toBe(false);
    }
  });
});

describe('buildUpdatedNode round-trips', () => {
  it('edits a const value (number)', () => {
    const node: ExprNode = { op: 'const', args: [], value: 0 } as unknown as ExprNode;
    const result = buildUpdatedNode(node, { value: '42' });
    expect(result).toEqual({ op: 'const', args: [], value: 42 });
  });

  it('edits a const value (JSON array)', () => {
    const node: ExprNode = { op: 'const', args: [], value: 0 } as unknown as ExprNode;
    const result = buildUpdatedNode(node, { value: '[1, 2, 3]' });
    expect(result).toEqual({ op: 'const', args: [], value: [1, 2, 3] });
  });

  it('rejects a non-numeric const value with an inline error', () => {
    const node: ExprNode = { op: 'const', args: [], value: 0 } as unknown as ExprNode;
    const result = buildUpdatedNode(node, { value: 'oops' });
    expect(typeof result).toBe('string');
  });

  it('edits D wrt while preserving args', () => {
    const node: ExprNode = { op: 'D', args: ['u'], wrt: 't' } as unknown as ExprNode;
    const result = buildUpdatedNode(node, { wrt: 'x' });
    expect(result).toEqual({ op: 'D', args: ['u'], wrt: 'x' });
  });

  it('edits enum type and member into args[0] / args[1]', () => {
    const node: ExprNode = { op: 'enum', args: ['Type', 'member'] } as unknown as ExprNode;
    const result = buildUpdatedNode(node, { __enumType: 'Season', __enumMember: 'summer' });
    expect(result).toEqual({ op: 'enum', args: ['Season', 'summer'] });
  });

  it('edits table_lookup axes (JSON map) and keeps args empty', () => {
    const node: ExprNode = { op: 'table_lookup', args: [], table: 't', axes: {} } as unknown as ExprNode;
    const result = buildUpdatedNode(node, {
      table: 'rate_table',
      axes: '{"T": "temperature"}',
      output: ''
    });
    expect(result).toEqual({
      op: 'table_lookup',
      args: [],
      table: 'rate_table',
      axes: { T: 'temperature' }
    });
  });

  it('reports invalid JSON in a map field', () => {
    const node: ExprNode = { op: 'table_lookup', args: [], table: 't', axes: {} } as unknown as ExprNode;
    const result = buildUpdatedNode(node, { table: 't', axes: '{not json', output: '' });
    expect(typeof result).toBe('string');
    expect(result as string).toMatch(/Axes/);
  });

  it('parses a comma-separated shape for reshape', () => {
    const node: ExprNode = { op: 'reshape', args: ['a'], shape: [1] } as unknown as ExprNode;
    const result = buildUpdatedNode(node, { shape: '2, 3' });
    expect(result).toEqual({ op: 'reshape', args: ['a'], shape: [2, 3] });
  });

  it('parses a mixed (int + symbolic) shape', () => {
    const node: ExprNode = { op: 'reshape', args: ['a'], shape: [1] } as unknown as ExprNode;
    const result = buildUpdatedNode(node, { shape: 'm, 3' });
    expect(result).toEqual({ op: 'reshape', args: ['a'], shape: ['m', 3] });
  });

  it('omits an optional perm when transpose input is cleared', () => {
    const node: ExprNode = { op: 'transpose', args: ['a'], perm: [1, 0] } as unknown as ExprNode;
    const result = buildUpdatedNode(node, { perm: '' });
    expect(result).toEqual({ op: 'transpose', args: ['a'] });
  });

  it('parses concat axis as a number', () => {
    const node: ExprNode = { op: 'concat', args: ['a', 'b'], axis: 0 } as unknown as ExprNode;
    const result = buildUpdatedNode(node, { axis: '2' });
    expect(result).toEqual({ op: 'concat', args: ['a', 'b'], axis: 2 });
  });

  it('edits the manifold of intersect_polygon', () => {
    const node: ExprNode = { op: 'intersect_polygon', args: ['a', 'b'], manifold: 'spherical' } as unknown as ExprNode;
    const result = buildUpdatedNode(node, { manifold: 'planar' });
    expect(result).toEqual({ op: 'intersect_polygon', args: ['a', 'b'], manifold: 'planar' });
  });

  it('edits aggregate fields and sets distinct via the bool select', () => {
    const node: ExprNode = {
      op: 'aggregate',
      args: ['rel'],
      output_idx: ['i'],
      reduce: '+',
      expr: 'x'
    } as unknown as ExprNode;
    const result = buildUpdatedNode(node, {
      output_idx: 'i, j',
      reduce: 'max',
      semiring: 'max_product',
      expr: '"x"',
      ranges: '{"j": [1, 10]}',
      join: '',
      filter: '',
      distinct: 'true',
      key: ''
    });
    expect(result).toEqual({
      op: 'aggregate',
      args: ['rel'],
      output_idx: ['i', 'j'],
      reduce: 'max',
      semiring: 'max_product',
      expr: 'x',
      ranges: { j: [1, 10] },
      distinct: true
    });
  });

  it('preserves an unrelated field such as id', () => {
    const node: ExprNode = { op: 'D', args: ['u'], wrt: 't', id: 'node-1' } as unknown as ExprNode;
    const result = buildUpdatedNode(node, { wrt: 'x' });
    expect(result).toEqual({ op: 'D', args: ['u'], wrt: 'x', id: 'node-1' });
  });
});

describe('serializeField', () => {
  it('shows an existing const value as JSON', () => {
    const node: ExprNode = { op: 'const', args: [], value: [1, 2] } as unknown as ExprNode;
    expect(serializeField(node, getOpFieldSpecs('const')[0])).toBe('[1,2]');
  });

  it('renders a select default when the field is absent', () => {
    const node: ExprNode = { op: 'aggregate', args: [], output_idx: ['i'], expr: 'x' } as unknown as ExprNode;
    const reduceSpec = getOpFieldSpecs('aggregate').find(s => s.name === 'reduce')!;
    expect(serializeField(node, reduceSpec)).toBe('+');
  });

  it('reads enum args into synthetic fields', () => {
    const node: ExprNode = { op: 'enum', args: ['Season', 'summer'] } as unknown as ExprNode;
    const specs = getOpFieldSpecs('enum');
    expect(serializeField(node, specs[0])).toBe('Season');
    expect(serializeField(node, specs[1])).toBe('summer');
  });
});

describe('NodeFieldEditor component', () => {
  it('renders one input per field with initial values and applies edits', () => {
    const node: ExprNode = { op: 'D', args: ['u'], wrt: 't' } as unknown as ExprNode;
    const onReplace = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <NodeFieldEditor node={node} path={['args', 0]} onReplace={onReplace} onClose={onClose} />
    ));

    const input = screen.getByDisplayValue('t');
    fireEvent.input(input, { target: { value: 'x' } });
    fireEvent.click(screen.getByText('Apply'));

    expect(onReplace).toHaveBeenCalledWith(['args', 0], { op: 'D', args: ['u'], wrt: 'x' });
    expect(onClose).toHaveBeenCalled();
  });

  it('keeps the form open and shows an error on invalid JSON', () => {
    const node: ExprNode = { op: 'table_lookup', args: [], table: 't', axes: {} } as unknown as ExprNode;
    const onReplace = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <NodeFieldEditor node={node} path={[]} onReplace={onReplace} onClose={onClose} />
    ));

    // Set a broken axes map and submit.
    const axesInput = screen.getByPlaceholderText('{"x": "temperature"}');
    fireEvent.input(axesInput, { target: { value: '{broken' } });
    fireEvent.click(screen.getByText('Apply'));

    expect(onReplace).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByRole('alert')).toBeInTheDocument();
  });
});
