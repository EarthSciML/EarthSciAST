import js from '@eslint/js'
import tseslint from 'typescript-eslint'

export default tseslint.config(
  {
    // Generated files and build output are not linted; they are produced by
    // scripts/generate-embedded-schema.mjs and json-schema-to-typescript.
    ignores: ['dist/**', 'src/generated.ts', 'src/embedded-schema.ts'],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    rules: {
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
      // Pre-existing `any`s in the AST-walking code are surfaced as warnings
      // to ratchet down over time without blocking CI.
      '@typescript-eslint/no-explicit-any': 'warn',
    },
  },
)
