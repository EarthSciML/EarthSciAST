import { defineConfig } from 'vitest/config';
import solid from 'vite-plugin-solid';

export default defineConfig({
  plugins: [solid()],
  test: {
    globals: true,
    environment: 'jsdom',
    deps: {
      optimizer: {
        web: {
          include: ['solid-js', 'solid-element', '@solidjs/testing-library']
        }
      }
    },
    setupFiles: ['./src/test-setup.ts']
  },
  resolve: {
    conditions: ['development', 'browser']
  }
});
