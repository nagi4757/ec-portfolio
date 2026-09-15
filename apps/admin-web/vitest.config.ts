import { defineConfig } from 'vitest/config'
import path from 'node:path'

export default defineConfig({
    // The same manual alias vite.config.ts uses, rather than pulling in another
    // dependency just for tests.
    resolve: {
        alias: {
            '@': path.resolve(__dirname, './src'),
        },
    },
    test: {
        // These suites drive the refund contract and the per-order key lifecycle,
        // neither of which needs a DOM.
        environment: 'node',
        include: ['src/**/*.test.ts'],
    },
})
