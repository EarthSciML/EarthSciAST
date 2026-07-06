/**
 * Tests for ValidationPanel component
 */

import { render, screen } from '@solidjs/testing-library';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { EsmFile } from 'earthsci-toolkit';
import { ValidationPanel } from './ValidationPanel';

// Mock the validate function from earthsci-toolkit
vi.mock('earthsci-toolkit', () => ({
  validate: vi.fn()
}));

describe('ValidationPanel', () => {
  const validEsmFile: EsmFile = {
    esm: "1.0.0",
    metadata: {
      name: "Test Model",
      description: "A test model"
    },
    models: {
      TestModel: {
        variables: {
          x: { type: 'state', units: 'm', description: 'Position' }
        },
        equations: [
          { lhs: { op: 'D', args: ['x', 't'] }, rhs: 'v' }
        ]
      }
    }
  };

  const invalidEsmFile: EsmFile = {
    esm: "1.0.0",
    metadata: {
      name: "Invalid Test Model"
    },
    models: {
      TestModel: {
        variables: {
          x: { type: 'state', units: 'm', description: 'Position' }
        },
        equations: [
          { lhs: { op: 'D', args: ['x', 't'] }, rhs: 'undefined_var' }
        ]
      }
    }
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders with valid ESM file', async () => {
    const { validate } = await import('earthsci-toolkit');
    (validate as any).mockReturnValue({
      is_valid: true,
      schema_errors: [],
      structural_errors: []
    });

    render(() => <ValidationPanel esmFile={validEsmFile} />);

    expect(screen.getByText('Validation Results')).toBeInTheDocument();
    expect(screen.getByTitle('No errors found')).toBeInTheDocument();
    expect(screen.getByText('No validation errors found. The ESM file is valid.')).toBeInTheDocument();
  });

  it('renders with schema errors', async () => {
    const { validate } = await import('earthsci-toolkit');
    (validate as any).mockReturnValue({
      is_valid: false,
      schema_errors: [{
        path: '/models/TestModel/variables/x/type',
        message: 'Invalid variable type',
        code: 'enum_mismatch',
        details: { expected: ['state', 'parameter', 'observed'] }
      }],
      structural_errors: []
    });

    render(() => <ValidationPanel esmFile={invalidEsmFile} />);

    expect(screen.getByText('Validation Results')).toBeInTheDocument();
    expect(screen.getByText('Schema Errors (1)')).toBeInTheDocument();
    expect(screen.getByText('Invalid variable type')).toBeInTheDocument();
    expect(screen.getByText('enum_mismatch')).toBeInTheDocument();
  });

  it('renders with structural errors', async () => {
    const { validate } = await import('earthsci-toolkit');
    (validate as any).mockReturnValue({
      is_valid: false,
      schema_errors: [],
      structural_errors: [{
        path: '/models/TestModel/equations/0/rhs',
        message: 'Variable "undefined_var" referenced in equation is not declared',
        code: 'undefined_variable',
        details: { variable: 'undefined_var' }
      }]
    });

    render(() => <ValidationPanel esmFile={invalidEsmFile} />);

    expect(screen.getByText('Validation Results')).toBeInTheDocument();
    expect(screen.getByText('Structural Errors (1)')).toBeInTheDocument();
    expect(screen.getByText('Variable "undefined_var" referenced in equation is not declared')).toBeInTheDocument();
    expect(screen.getByText('undefined_variable')).toBeInTheDocument();
  });

  it('renders unit warnings in the Warnings section', async () => {
    const { validate } = await import('earthsci-toolkit');
    (validate as any).mockReturnValue({
      is_valid: true,
      schema_errors: [],
      structural_errors: [],
      unit_warnings: [{
        message: 'Units of lhs and rhs disagree',
        location: '/models/TestModel/equations/0',
        equation: 'D(x, t) = v'
      }]
    });

    const onErrorClick = vi.fn();
    render(() => <ValidationPanel esmFile={validEsmFile} onErrorClick={onErrorClick} />);

    // Warnings section is reachable even when the file is valid
    expect(screen.getByText('Warnings (1)')).toBeInTheDocument();
    expect(screen.getByText('Units of lhs and rhs disagree')).toBeInTheDocument();
    expect(screen.getByTitle('1 warning(s)')).toBeInTheDocument();

    // The success message is not shown when warnings are present
    expect(
      screen.queryByText('No validation errors found. The ESM file is valid.')
    ).not.toBeInTheDocument();

    // Warning items are clickable and report their location path
    const warningItem = screen.getByText('Units of lhs and rhs disagree').closest('.error-item') as HTMLElement | null;
    warningItem?.click();
    expect(onErrorClick).toHaveBeenCalledWith('/models/TestModel/equations/0');
  });

  it('displays error count badges', async () => {
    const { validate } = await import('earthsci-toolkit');
    (validate as any).mockReturnValue({
      is_valid: false,
      schema_errors: [{
        path: '/models/TestModel',
        message: 'Schema error',
        code: 'schema_error',
        details: {}
      }],
      structural_errors: [{
        path: '/models/TestModel/equations/0',
        message: 'Structural error',
        code: 'structural_error',
        details: {}
      }]
    });

    render(() => <ValidationPanel esmFile={invalidEsmFile} />);

    // Should show error count badge with total count
    expect(screen.getByTitle('2 error(s)')).toBeInTheDocument();
  });

  it('handles error clicks', async () => {
    const { validate } = await import('earthsci-toolkit');
    (validate as any).mockReturnValue({
      is_valid: false,
      schema_errors: [{
        path: '/models/TestModel/variables/x',
        message: 'Test error',
        code: 'test_error',
        details: {}
      }],
      structural_errors: []
    });

    const onErrorClick = vi.fn();
    render(() => <ValidationPanel esmFile={invalidEsmFile} onErrorClick={onErrorClick} />);

    const errorItem = screen.getByText('Test error').closest('.error-item') as HTMLElement | null;
    expect(errorItem).toBeInTheDocument();

    errorItem?.click();
    expect(onErrorClick).toHaveBeenCalledWith('/models/TestModel/variables/x');
  });

  it('supports collapse/expand functionality', async () => {
    const { validate } = await import('earthsci-toolkit');
    (validate as any).mockReturnValue({
      is_valid: true,
      schema_errors: [],
      structural_errors: []
    });

    const onToggleCollapsed = vi.fn();
    render(() => (
      <ValidationPanel
        esmFile={validEsmFile}
        collapsed={false}
        onToggleCollapsed={onToggleCollapsed}
      />
    ));

    const header = screen.getByText('Validation Results').closest('.validation-header') as HTMLElement | null;
    expect(header).toBeInTheDocument();

    header?.click();
    expect(onToggleCollapsed).toHaveBeenCalledWith(true);
  });

  it('does not show content when collapsed', async () => {
    const { validate } = await import('earthsci-toolkit');
    (validate as any).mockReturnValue({
      is_valid: true,
      schema_errors: [],
      structural_errors: []
    });

    render(() => <ValidationPanel esmFile={validEsmFile} collapsed={true} />);

    expect(screen.getByText('Validation Results')).toBeInTheDocument();
    expect(screen.queryByText('No validation errors found. The ESM file is valid.')).not.toBeInTheDocument();
  });

  it('displays error details when available', async () => {
    const { validate } = await import('earthsci-toolkit');
    (validate as any).mockReturnValue({
      is_valid: false,
      schema_errors: [{
        path: '/models/TestModel/variables/x/type',
        message: 'Invalid type',
        code: 'enum_mismatch',
        details: {
          expected: ['state', 'parameter', 'observed'],
          actual: 'invalid_type'
        }
      }],
      structural_errors: []
    });

    render(() => <ValidationPanel esmFile={invalidEsmFile} />);

    expect(screen.getByText('expected:')).toBeInTheDocument();
    expect(screen.getByText('actual:')).toBeInTheDocument();
  });

  it('handles keyboard interactions for error items', async () => {
    const { validate } = await import('earthsci-toolkit');
    (validate as any).mockReturnValue({
      is_valid: false,
      schema_errors: [{
        path: '/models/TestModel/variables/x',
        message: 'Test error',
        code: 'test_error',
        details: {}
      }],
      structural_errors: []
    });

    const onErrorClick = vi.fn();
    render(() => <ValidationPanel esmFile={invalidEsmFile} onErrorClick={onErrorClick} />);

    const errorItem = screen.getByText('Test error').closest('.error-item');
    expect(errorItem).toBeInTheDocument();

    // Simulate Enter key press
    errorItem?.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })
    );
    expect(onErrorClick).toHaveBeenCalledWith('/models/TestModel/variables/x');

    // Simulate Space key press
    onErrorClick.mockClear();
    errorItem?.dispatchEvent(
      new KeyboardEvent('keydown', { key: ' ', bubbles: true })
    );
    expect(onErrorClick).toHaveBeenCalledWith('/models/TestModel/variables/x');
  });

  it('applies custom CSS classes', async () => {
    const { validate } = await import('earthsci-toolkit');
    (validate as any).mockReturnValue({
      is_valid: true,
      schema_errors: [],
      structural_errors: []
    });

    const { container } = render(() => (
      <ValidationPanel esmFile={validEsmFile} class="custom-class" />
    ));

    expect(container.firstChild).toHaveClass('validation-panel');
    expect(container.firstChild).toHaveClass('custom-class');
    expect(container.firstChild).toHaveClass('valid');
  });

  it('shows correct CSS classes for invalid state', async () => {
    const { validate } = await import('earthsci-toolkit');
    (validate as any).mockReturnValue({
      is_valid: false,
      schema_errors: [{
        path: '/test',
        message: 'Test error',
        code: 'test_error',
        details: {}
      }],
      structural_errors: []
    });

    const { container } = render(() => <ValidationPanel esmFile={invalidEsmFile} />);

    expect(container.firstChild).toHaveClass('validation-panel');
    expect(container.firstChild).toHaveClass('invalid');
  });
});