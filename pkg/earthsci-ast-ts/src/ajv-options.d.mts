/**
 * Types for `ajv-options.mjs`.
 *
 * The options live in a `.mjs` file so the build script can import them without
 * a TypeScript loader; this is the declaration TypeScript needs to see them from
 * the test that compares the precompiled validator against a freshly compiled
 * one.
 */
import type Ajv from 'ajv'

type Options = NonNullable<ConstructorParameters<typeof Ajv>[0]>

export declare const AJV_OPTIONS: Options
