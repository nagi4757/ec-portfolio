import { defineConfig } from 'vitest/config'
import tsconfigPaths from 'vite-tsconfig-paths'

export default defineConfig({
    plugins: [tsconfigPaths()],
    test: {
        // The suites below drive the checkout contract and the idempotency key
        // lifecycle, neither of which needs a DOM. Keeping the node environment
        // avoids pulling jsdom in for tests that would not use it.
        environment: 'node',
        include: ['src/**/*.test.ts'],
    },
})
