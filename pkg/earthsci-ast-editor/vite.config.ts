import { defineConfig } from 'vite';
import solid from 'vite-plugin-solid';
import { resolve } from 'path';

export default defineConfig({
  plugins: [solid()],

  build: {
    lib: {
      entry: resolve(__dirname, 'src/index.ts'),
      name: 'ESMEditor',
      fileName: 'index',
      formats: ['es']
    },
    rollupOptions: {
      external: ['solid-js', 'solid-element', '@earthsciml/ast', 'd3-force'],
      output: {
        globals: {
          'solid-js': 'SolidJS',
          'solid-element': 'SolidElement',
          '@earthsciml/ast': 'ESMFormat',
          'd3-force': 'D3Force'
        }
      }
    }
  }

  // Test configuration lives in vitest.config.ts (vitest ignores a `test`
  // block here when that file exists).
});