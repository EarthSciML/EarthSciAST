/**
 * Delimiters Component Tests
 *
 * Covers the two audit fixes for this component:
 *  - [H] the auto-sizing ResizeObserver is torn down via `onCleanup` (Solid
 *    ignores values returned from `createEffect`, so a returned cleanup leaked).
 *  - [M] `getDelimiterChars()` is evaluated reactively in JSX, so changing the
 *    `type` prop updates the rendered delimiter glyphs.
 */

import { render, cleanup } from '@solidjs/testing-library'
import { describe, it, expect, afterEach, vi } from 'vitest'
import { createSignal } from 'solid-js'
import { Delimiters } from './Delimiters'

afterEach(cleanup)

describe('Delimiters component', () => {
  it('renders parentheses by default', () => {
    const { container } = render(() => <Delimiters autoSize={false} content={<span>x</span>} />)

    expect(container.querySelector('.esm-delimiters-left')?.textContent).toBe('(')
    expect(container.querySelector('.esm-delimiters-right')?.textContent).toBe(')')
    expect(container.querySelector('.esm-delimiters-content')?.textContent).toBe('x')
  })

  it('renders the glyphs for the requested delimiter type', () => {
    const { container } = render(() => (
      <Delimiters type="brackets" autoSize={false} content={<span>x</span>} />
    ))

    expect(container.querySelector('.esm-delimiters-left')?.textContent).toBe('[')
    expect(container.querySelector('.esm-delimiters-right')?.textContent).toBe(']')
  })

  it('reactively updates delimiter glyphs when the type prop changes', () => {
    const [type, setType] = createSignal<'parentheses' | 'braces' | 'angle'>('parentheses')
    const { container } = render(() => (
      <Delimiters type={type()} autoSize={false} content={<span>x</span>} />
    ))

    const left = () => container.querySelector('.esm-delimiters-left')?.textContent
    const right = () => container.querySelector('.esm-delimiters-right')?.textContent

    expect(left()).toBe('(')
    expect(right()).toBe(')')

    setType('braces')
    expect(left()).toBe('{')
    expect(right()).toBe('}')

    setType('angle')
    expect(left()).toBe('⟨')
    expect(right()).toBe('⟩')
  })

  it('applies base and custom CSS classes reactively', () => {
    const [size, setSize] = createSignal<'small' | 'large'>('small')
    const { container } = render(() => (
      <Delimiters class="custom" size={size()} autoSize={false} content={<span>x</span>} />
    ))

    const el = container.querySelector('.esm-delimiters')
    expect(el?.classList.contains('esm-delimiters-parentheses')).toBe(true)
    expect(el?.classList.contains('custom')).toBe(true)
    expect(el?.classList.contains('esm-delimiters-small')).toBe(true)

    setSize('large')
    expect(el?.classList.contains('esm-delimiters-small')).toBe(false)
    expect(el?.classList.contains('esm-delimiters-large')).toBe(true)
  })

  it('disconnects the ResizeObserver on cleanup (onCleanup, not a returned callback)', () => {
    const disconnect = vi.fn()
    const observe = vi.fn()
    const original = global.ResizeObserver
    global.ResizeObserver = class {
      observe = observe
      unobserve = vi.fn()
      disconnect = disconnect
    } as unknown as typeof ResizeObserver

    try {
      // autoSize defaults to true, so the auto-sizing effect installs an observer.
      const { unmount } = render(() => <Delimiters content={<span>x</span>} />)
      expect(observe).toHaveBeenCalled()
      expect(disconnect).not.toHaveBeenCalled()

      unmount()
      // If cleanup were a value returned from createEffect (React idiom), Solid
      // would never call it and disconnect would stay at zero.
      expect(disconnect).toHaveBeenCalledTimes(1)
    } finally {
      global.ResizeObserver = original
    }
  })
})
