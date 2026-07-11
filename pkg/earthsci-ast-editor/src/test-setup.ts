import '@testing-library/jest-dom';
import { vi } from 'vitest';

// Configure SolidJS testing environment
if (typeof global.requestAnimationFrame === 'undefined') {
  global.requestAnimationFrame = (cb) => setTimeout(cb, 16);
}

if (typeof global.cancelAnimationFrame === 'undefined') {
  global.cancelAnimationFrame = (id) => clearTimeout(id);
}

// jsdom does not implement ResizeObserver, which the Delimiters layout component
// uses for auto-sizing. Provide a no-op default so components render without
// throwing. Individual tests may replace this with a spy to assert cleanup.
if (typeof global.ResizeObserver === 'undefined') {
  global.ResizeObserver = class {
    observe(): void {}
    unobserve(): void {}
    disconnect(): void {}
  };
}

/**
 * Install a minimal `customElements` stub on `window`. The web-component
 * registration path only calls `define`/`get`/`whenDefined`, so tests that just
 * need registration to succeed can call this instead of pasting the mock.
 */
export function installCustomElementsMock(): void {
  Object.defineProperty(window, 'customElements', {
    value: {
      define: vi.fn(),
      get: vi.fn(),
      whenDefined: vi.fn().mockResolvedValue(undefined),
    },
    writable: true,
    configurable: true,
  });
}