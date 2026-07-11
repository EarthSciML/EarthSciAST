/**
 * expression-templates - Static palette data for ExpressionPalette
 *
 * The set of insertable expression templates (esm-spec §4.2) and their category
 * display configuration. Extracted from ExpressionPalette.tsx so the component
 * file holds only behaviour; edit this module to add/adjust palette entries.
 */

import type { Expression } from '@earthsciml/ast';
import { CLOSED_FUNCTION_NAMES } from '@earthsciml/ast';
import { EXPRESSION_PLACEHOLDER } from '../constants';

/** Category a template is grouped under in the palette. */
export type TemplateCategory = 'calculus' | 'arithmetic' | 'functions' | 'logic' | 'array';

/** A single insertable palette entry. */
export interface ExpressionTemplate {
  id: string;
  label: string;
  description: string;
  expression: Expression;
  keywords: string[];
  category: TemplateCategory;
}

/** First closed function name, used as the default `fn` op template value. */
export const DEFAULT_FN_NAME = CLOSED_FUNCTION_NAMES[0] ?? 'datetime.year';

// Predefined expression templates
export const EXPRESSION_TEMPLATES: ExpressionTemplate[] = [
  // Calculus operators
  {
    id: 'derivative',
    label: 'D(_, t)',
    description: 'Time derivative',
    // The differentiation variable lives in the `wrt` field (esm-schema.json);
    // the toolkit's arity for `D` is exactly one operand.
    expression: { op: 'D', args: [EXPRESSION_PLACEHOLDER], wrt: 't' },
    keywords: ['derivative', 'time', 'differential', 'd', 'dt'],
    category: 'calculus'
  },
  {
    id: 'integral',
    label: '∫(_) dx',
    description: 'Definite integral',
    expression: { op: 'integral', args: [EXPRESSION_PLACEHOLDER], var: 'x', lower: 0, upper: 1 },
    keywords: ['integral', 'integrate', 'antiderivative', 'pide'],
    category: 'calculus'
  },

  // Arithmetic operators
  {
    id: 'addition',
    label: '_ + _',
    description: 'Addition',
    expression: { op: '+', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['add', 'addition', 'plus', '+'],
    category: 'arithmetic'
  },
  {
    id: 'subtraction',
    label: '_ - _',
    description: 'Subtraction',
    expression: { op: '-', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['subtract', 'subtraction', 'minus', '-'],
    category: 'arithmetic'
  },
  {
    id: 'multiplication',
    label: '_ * _',
    description: 'Multiplication',
    expression: { op: '*', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['multiply', 'multiplication', 'times', '*'],
    category: 'arithmetic'
  },
  {
    id: 'division',
    label: '_ / _',
    description: 'Division',
    expression: { op: '/', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['divide', 'division', 'over', '/'],
    category: 'arithmetic'
  },
  {
    id: 'power',
    label: '_ ^ _',
    description: 'Power/Exponentiation',
    expression: { op: '^', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['power', 'exponent', 'exp', '^', '**'],
    category: 'arithmetic'
  },
  {
    id: 'negate',
    label: '-_',
    description: 'Unary negation',
    expression: { op: '-', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['negate', 'negative', 'unary', 'minus'],
    category: 'arithmetic'
  },

  // Mathematical functions
  {
    id: 'exponential',
    label: 'exp(_)',
    description: 'Exponential function (e^x)',
    expression: { op: 'exp', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['exponential', 'exp', 'e'],
    category: 'functions'
  },
  {
    id: 'logarithm',
    label: 'log(_)',
    description: 'Natural logarithm',
    expression: { op: 'log', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['logarithm', 'log', 'ln', 'natural'],
    category: 'functions'
  },
  {
    id: 'log10',
    label: 'log10(_)',
    description: 'Base-10 logarithm',
    expression: { op: 'log10', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['log10', 'logarithm', 'base 10', 'common'],
    category: 'functions'
  },
  {
    id: 'sign',
    label: 'sign(_)',
    description: 'Sign function',
    expression: { op: 'sign', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['sign', 'signum', 'sgn'],
    category: 'functions'
  },
  {
    id: 'sqrt',
    label: 'sqrt(_)',
    description: 'Square root',
    expression: { op: 'sqrt', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['sqrt', 'square', 'root'],
    category: 'functions'
  },
  {
    id: 'absolute',
    label: 'abs(_)',
    description: 'Absolute value',
    expression: { op: 'abs', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['absolute', 'abs', 'magnitude'],
    category: 'functions'
  },
  {
    id: 'sine',
    label: 'sin(_)',
    description: 'Sine function',
    expression: { op: 'sin', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['sine', 'sin', 'trigonometry'],
    category: 'functions'
  },
  {
    id: 'cosine',
    label: 'cos(_)',
    description: 'Cosine function',
    expression: { op: 'cos', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['cosine', 'cos', 'trigonometry'],
    category: 'functions'
  },
  {
    id: 'tangent',
    label: 'tan(_)',
    description: 'Tangent function',
    expression: { op: 'tan', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['tangent', 'tan', 'trigonometry'],
    category: 'functions'
  },
  {
    id: 'arcsine',
    label: 'asin(_)',
    description: 'Inverse sine',
    expression: { op: 'asin', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['arcsine', 'asin', 'inverse sine', 'trigonometry'],
    category: 'functions'
  },
  {
    id: 'arccosine',
    label: 'acos(_)',
    description: 'Inverse cosine',
    expression: { op: 'acos', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['arccosine', 'acos', 'inverse cosine', 'trigonometry'],
    category: 'functions'
  },
  {
    id: 'arctangent',
    label: 'atan(_)',
    description: 'Inverse tangent',
    expression: { op: 'atan', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['arctangent', 'atan', 'inverse tangent', 'trigonometry'],
    category: 'functions'
  },
  {
    id: 'arctangent2',
    label: 'atan2(_, _)',
    description: 'Two-argument arctangent',
    expression: { op: 'atan2', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['atan2', 'arctangent', 'angle', 'trigonometry'],
    category: 'functions'
  },
  {
    id: 'sinh',
    label: 'sinh(_)',
    description: 'Hyperbolic sine',
    expression: { op: 'sinh', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['sinh', 'hyperbolic sine', 'hyperbolic'],
    category: 'functions'
  },
  {
    id: 'cosh',
    label: 'cosh(_)',
    description: 'Hyperbolic cosine',
    expression: { op: 'cosh', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['cosh', 'hyperbolic cosine', 'hyperbolic'],
    category: 'functions'
  },
  {
    id: 'tanh',
    label: 'tanh(_)',
    description: 'Hyperbolic tangent',
    expression: { op: 'tanh', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['tanh', 'hyperbolic tangent', 'hyperbolic'],
    category: 'functions'
  },
  {
    id: 'asinh',
    label: 'asinh(_)',
    description: 'Inverse hyperbolic sine',
    expression: { op: 'asinh', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['asinh', 'inverse hyperbolic sine', 'hyperbolic'],
    category: 'functions'
  },
  {
    id: 'acosh',
    label: 'acosh(_)',
    description: 'Inverse hyperbolic cosine',
    expression: { op: 'acosh', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['acosh', 'inverse hyperbolic cosine', 'hyperbolic'],
    category: 'functions'
  },
  {
    id: 'atanh',
    label: 'atanh(_)',
    description: 'Inverse hyperbolic tangent',
    expression: { op: 'atanh', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['atanh', 'inverse hyperbolic tangent', 'hyperbolic'],
    category: 'functions'
  },
  {
    id: 'floor',
    label: 'floor(_)',
    description: 'Round down to integer',
    expression: { op: 'floor', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['floor', 'round down', 'integer'],
    category: 'functions'
  },
  {
    id: 'ceil',
    label: 'ceil(_)',
    description: 'Round up to integer',
    expression: { op: 'ceil', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['ceil', 'ceiling', 'round up', 'integer'],
    category: 'functions'
  },
  {
    id: 'minimum',
    label: 'min(_, _)',
    description: 'Minimum of two values',
    expression: { op: 'min', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['minimum', 'min', 'smaller'],
    category: 'functions'
  },
  {
    id: 'maximum',
    label: 'max(_, _)',
    description: 'Maximum of two values',
    expression: { op: 'max', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['maximum', 'max', 'larger'],
    category: 'functions'
  },

  // Logical operators
  {
    id: 'ifelse',
    label: 'ifelse(_, _, _)',
    description: 'Conditional expression',
    expression: { op: 'ifelse', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['if', 'ifelse', 'conditional', 'ternary'],
    category: 'logic'
  },
  {
    id: 'greater_than',
    label: '_ > _',
    description: 'Greater than comparison',
    expression: { op: '>', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['greater', 'than', '>', 'compare'],
    category: 'logic'
  },
  {
    id: 'less_than',
    label: '_ < _',
    description: 'Less than comparison',
    expression: { op: '<', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['less', 'than', '<', 'compare'],
    category: 'logic'
  },
  {
    id: 'greater_equal',
    label: '_ >= _',
    description: 'Greater than or equal comparison',
    expression: { op: '>=', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['greater', 'equal', '>=', 'gte', 'compare'],
    category: 'logic'
  },
  {
    id: 'less_equal',
    label: '_ <= _',
    description: 'Less than or equal comparison',
    expression: { op: '<=', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['less', 'equal', '<=', 'lte', 'compare'],
    category: 'logic'
  },
  {
    id: 'equals',
    label: '_ == _',
    description: 'Equality comparison',
    expression: { op: '==', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['equals', 'equal', '==', 'compare'],
    category: 'logic'
  },
  {
    id: 'not_equals',
    label: '_ != _',
    description: 'Inequality comparison',
    expression: { op: '!=', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['not', 'equal', '!=', 'inequality', 'compare'],
    category: 'logic'
  },
  {
    id: 'logical_and',
    label: '_ && _',
    description: 'Logical AND',
    expression: { op: 'and', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['and', 'logical', '&&', 'both'],
    category: 'logic'
  },
  {
    id: 'logical_or',
    label: '_ || _',
    description: 'Logical OR',
    expression: { op: 'or', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['or', 'logical', '||', 'either'],
    category: 'logic'
  },
  {
    id: 'logical_not',
    label: '!_',
    description: 'Logical NOT',
    expression: { op: 'not', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['not', 'logical', '!', 'negate'],
    category: 'logic'
  },

  // Array / query tier ops (esm-spec §4.2). Each is insertable with sensible
  // default field values; a node field editor (⚙ on a selected node) edits the
  // non-`args` fields.
  {
    id: 'const',
    label: 'const',
    description: 'Inline literal value',
    expression: { op: 'const', args: [], value: 0 },
    keywords: ['const', 'constant', 'literal', 'value'],
    category: 'array'
  },
  {
    id: 'true',
    label: 'true',
    description: 'Boolean true literal',
    expression: { op: 'true', args: [] },
    keywords: ['true', 'boolean', 'literal'],
    category: 'array'
  },
  {
    id: 'fn',
    label: 'fn(_)',
    description: 'Closed-registry function call',
    expression: { op: 'fn', name: DEFAULT_FN_NAME, args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['fn', 'function', 'closed', 'datetime', 'interp'],
    category: 'array'
  },
  {
    id: 'enum',
    label: 'enum',
    description: 'Enum member reference',
    expression: { op: 'enum', args: ['Type', 'member'] },
    keywords: ['enum', 'enumeration', 'member'],
    category: 'array'
  },
  {
    id: 'index',
    label: 'index(_, _)',
    description: 'Array indexing',
    expression: { op: 'index', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['index', 'array', 'element', 'subscript'],
    category: 'array'
  },
  {
    id: 'broadcast',
    label: 'broadcast(_, _)',
    description: 'Element-wise scalar op over arrays',
    expression: { op: 'broadcast', fn: '+', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER] },
    keywords: ['broadcast', 'elementwise', 'map', 'array'],
    category: 'array'
  },
  {
    id: 'makearray',
    label: 'makearray',
    description: 'Build an array from regions and values',
    expression: { op: 'makearray', args: [], regions: [], values: [] },
    keywords: ['makearray', 'array', 'build', 'regions', 'values'],
    category: 'array'
  },
  {
    id: 'reshape',
    label: 'reshape(_)',
    description: 'Reshape an array',
    expression: { op: 'reshape', args: [EXPRESSION_PLACEHOLDER], shape: [1] },
    keywords: ['reshape', 'shape', 'array', 'dimensions'],
    category: 'array'
  },
  {
    id: 'transpose',
    label: 'transpose(_)',
    description: 'Transpose / permute array axes',
    expression: { op: 'transpose', args: [EXPRESSION_PLACEHOLDER] },
    keywords: ['transpose', 'permute', 'axes', 'array'],
    category: 'array'
  },
  {
    id: 'concat',
    label: 'concat(_, _)',
    description: 'Concatenate arrays along an axis',
    expression: { op: 'concat', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER], axis: 0 },
    keywords: ['concat', 'concatenate', 'join', 'array'],
    category: 'array'
  },
  {
    id: 'aggregate',
    label: 'aggregate',
    description: 'Functional aggregate query (FAQ)',
    expression: {
      op: 'aggregate',
      args: [EXPRESSION_PLACEHOLDER],
      output_idx: ['i'],
      reduce: '+',
      expr: EXPRESSION_PLACEHOLDER
    },
    keywords: ['aggregate', 'faq', 'reduce', 'einsum', 'sum', 'query'],
    category: 'array'
  },
  {
    id: 'argmin',
    label: 'argmin',
    description: 'Arg-witness minimizer',
    expression: { op: 'argmin', args: [EXPRESSION_PLACEHOLDER], arg: 'g', expr: EXPRESSION_PLACEHOLDER },
    keywords: ['argmin', 'argument', 'minimum', 'witness', 'nearest'],
    category: 'array'
  },
  {
    id: 'argmax',
    label: 'argmax',
    description: 'Arg-witness maximizer',
    expression: { op: 'argmax', args: [EXPRESSION_PLACEHOLDER], arg: 'g', expr: EXPRESSION_PLACEHOLDER },
    keywords: ['argmax', 'argument', 'maximum', 'witness'],
    category: 'array'
  },
  {
    id: 'intersect_polygon',
    label: 'intersect_polygon(_, _)',
    description: 'Clip two polygons',
    expression: { op: 'intersect_polygon', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER], manifold: 'spherical' },
    keywords: ['intersect', 'polygon', 'clip', 'geometry', 'manifold'],
    category: 'array'
  },
  {
    id: 'polygon_intersection_area',
    label: 'polygon_intersection_area(_, _)',
    description: 'Area of polygon overlap',
    expression: { op: 'polygon_intersection_area', args: [EXPRESSION_PLACEHOLDER, EXPRESSION_PLACEHOLDER], manifold: 'spherical' },
    keywords: ['polygon', 'intersection', 'area', 'overlap', 'geometry', 'manifold'],
    category: 'array'
  },
  {
    id: 'table_lookup',
    label: 'table_lookup',
    description: 'Sampled function table lookup',
    expression: { op: 'table_lookup', args: [], table: 'table_id', axes: {} },
    keywords: ['table_lookup', 'table', 'lookup', 'interpolate', 'sampled'],
    category: 'array'
  },
  {
    id: 'apply_expression_template',
    label: 'apply_expression_template',
    description: 'Invoke an in-file expression template',
    expression: { op: 'apply_expression_template', args: [], name: 'template_id', bindings: {} },
    keywords: ['apply', 'expression', 'template', 'macro'],
    category: 'array'
  }
];

/** Category display configuration (title, description, icon) keyed by category. */
export const CATEGORY_CONFIG: Record<TemplateCategory, { title: string; description: string; icon: string }> = {
  calculus: {
    title: 'Calculus',
    description: 'Differential operators',
    icon: '∂'
  },
  arithmetic: {
    title: 'Arithmetic',
    description: 'Basic mathematical operations',
    icon: '±'
  },
  functions: {
    title: 'Functions',
    description: 'Mathematical functions',
    icon: 'ƒ'
  },
  logic: {
    title: 'Logic',
    description: 'Logical operators and comparisons',
    icon: '∧'
  },
  array: {
    title: 'Arrays & Queries',
    description: 'Array, aggregate, and geometry ops',
    icon: '⊞'
  }
};
