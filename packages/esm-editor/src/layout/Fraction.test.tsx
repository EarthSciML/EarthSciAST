/**
 * Fraction Component Tests
 */

import { render, cleanup } from '@solidjs/testing-library';
import { describe, it, expect, afterEach } from 'vitest';
import { Fraction } from './fraction';

afterEach(cleanup);

describe('Fraction component', () => {
  it('renders basic fraction with numerator and denominator', () => {
    const { container } = render(() =>
      <Fraction
        numerator={<span>x</span>}
        denominator={<span>y</span>}
      />
    );

    const fractionEl = container.querySelector('.esm-fraction');
    const numeratorEl = container.querySelector('.esm-fraction-numerator');
    const denominatorEl = container.querySelector('.esm-fraction-denominator');
    const barEl = container.querySelector('.esm-fraction-bar');

    expect(fractionEl).toBeTruthy();
    expect(numeratorEl?.textContent).toBe('x');
    expect(denominatorEl?.textContent).toBe('y');
    expect(barEl).toBeTruthy();
  });

  it('applies custom CSS classes', () => {
    const { container } = render(() =>
      <Fraction
        class="custom-fraction"
        numerator={<span>1</span>}
        denominator={<span>2</span>}
      />
    );

    const fractionEl = container.querySelector('.esm-fraction');
    expect(fractionEl?.classList.contains('custom-fraction')).toBe(true);
  });

  it('handles inline property correctly', () => {
    const { container } = render(() =>
      <Fraction
        inline={true}
        numerator={<span>1</span>}
        denominator={<span>2</span>}
      />
    );

    const fractionEl = container.querySelector('.esm-fraction');
    expect(fractionEl?.classList.contains('esm-fraction-inline')).toBe(true);
  });

  it('can disable inline mode', () => {
    const { container } = render(() =>
      <Fraction
        inline={false}
        numerator={<span>1</span>}
        denominator={<span>2</span>}
      />
    );

    const fractionEl = container.querySelector('.esm-fraction');
    expect(fractionEl?.classList.contains('esm-fraction-inline')).toBe(false);
  });

  it('has proper accessibility attributes', () => {
    const { container } = render(() =>
      <Fraction
        numerator={<span>a</span>}
        denominator={<span>b</span>}
      />
    );

    const fractionEl = container.querySelector('.esm-fraction');
    expect(fractionEl?.getAttribute('role')).toBe('math');
    expect(fractionEl?.getAttribute('aria-label')).toBe('fraction');
  });
});