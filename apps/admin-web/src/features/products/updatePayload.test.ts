import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ProductApi } from '@/features/products/api'
import ProductForm from '@/features/products/components/ProductForm'
import { buildUpdatePayload, type ProductFormValues } from '@/features/products/updatePayload'
import { adminJa } from '@/i18n/locales/ja'
import { adminKo } from '@/i18n/locales/ko'
import { ApiError, isApiErrorCode } from '@/lib/api'
import type { Product } from '@/types/product'

// ProductForm only needs a t function; the app's i18n setup touches the DOM.
vi.mock('react-i18next', () => ({
    useTranslation: () => ({ t: (key: string) => key }),
}))

const SOURCE_ROOT = join(process.cwd(), 'src')

function readSource(relativePath: string): string {
    return readFileSync(join(SOURCE_ROOT, relativePath), 'utf8')
}

type Captured = { url: string; init: RequestInit }

function respond(status: number, body: unknown): Response {
    return {
        ok: status >= 200 && status < 300,
        status,
        headers: {
            get: (name: string) =>
                name.toLowerCase() === 'content-type' ? 'application/json' : null,
        },
        json: async () => body,
    } as unknown as Response
}

/** Answers each request with the next response, in order. */
function stubFetch(...responses: Response[]): Captured[] {
    const calls: Captured[] = []
    vi.stubGlobal('fetch', (url: string, init: RequestInit) => {
        calls.push({ url, init })
        const response = responses[calls.length - 1]
        return response
            ? Promise.resolve(response)
            : Promise.reject(new Error(`Unexpected request ${calls.length}: ${url}`))
    })
    return calls
}

const loaded: Product = {
    id: 7,
    name: 'Mug',
    price: 12000,
    stockQuantity: 10,
    active: true,
    imageUrl: '',
    description: '',
}

function edited(changes: Partial<ProductFormValues>): ProductFormValues {
    return {
        name: loaded.name,
        price: loaded.price,
        stockQuantity: loaded.stockQuantity,
        imageUrl: '',
        description: '',
        ...changes,
    }
}

beforeEach(() => {
    const entries = new Map<string, string>()
    vi.stubGlobal('localStorage', {
        getItem: (key: string) => entries.get(key) ?? null,
        setItem: (key: string, value: string) => void entries.set(key, value),
        removeItem: (key: string) => void entries.delete(key),
        clear: () => entries.clear(),
    })
})

afterEach(() => {
    vi.unstubAllGlobals()
})

describe('product edit payload', () => {
    it('leaves the stock out when the admin did not change it', () => {
        // Sending the loaded stock back is exactly what used to undo a reservation
        // made while the form was open.
        const payload = buildUpdatePayload(loaded, edited({ name: 'Renamed' }))

        expect(payload).toEqual({ name: 'Renamed', price: 12000, imageUrl: '', description: '' })
        expect(payload).not.toHaveProperty('stockQuantity')
        expect(payload).not.toHaveProperty('expectedStockQuantity')
    })

    it('sends a changed stock together with the stock the form was loaded with', () => {
        const payload = buildUpdatePayload(loaded, edited({ stockQuantity: 25 }))

        expect(payload).toMatchObject({ stockQuantity: 25, expectedStockQuantity: 10 })
    })

    it('treats a stock set to zero as a change', () => {
        const payload = buildUpdatePayload(loaded, edited({ stockQuantity: 0 }))

        expect(payload).toMatchObject({ stockQuantity: 0, expectedStockQuantity: 10 })
    })

    it('goes out as the PATCH body for the product', async () => {
        const calls = stubFetch(respond(200, { ...loaded, stockQuantity: 25 }))
        const payload = buildUpdatePayload(loaded, edited({ stockQuantity: 25 }))

        await ProductApi.update(7, payload)

        expect(calls[0].url).toContain('/api/admin/products/7')
        expect(calls[0].init.method).toBe('PATCH')
        expect(JSON.parse(calls[0].init.body as string)).toEqual(payload)
    })
})

describe('product stock conflict', () => {
    it('surfaces the conflict the server answers a stale stock change with', async () => {
        stubFetch(respond(409, { code: 'PRODUCT_STOCK_CONFLICT' }))

        const failure = await ProductApi.update(7, { stockQuantity: 25, expectedStockQuantity: 10 })
            .then(() => null, (cause: unknown) => cause)

        expect(failure).toBeInstanceOf(ApiError)
        expect((failure as ApiError).status).toBe(409)
        expect(isApiErrorCode(failure, 'PRODUCT_STOCK_CONFLICT')).toBe(true)
    })

    it('reloads the product from the server and shows the latest stock', async () => {
        // Opened on a stock of 10; checkout has taken 3 by the time of the reload.
        const latest = { ...loaded, stockQuantity: 7 }
        const calls = stubFetch(respond(200, loaded), respond(200, latest))

        await ProductApi.get(7)
        const reloaded = await ProductApi.get(7)

        // A second request, not a copy kept from the first one.
        expect(calls).toHaveLength(2)
        expect(calls.map(call => call.url)).toEqual(['/api/admin/products/7', '/api/admin/products/7'])
        expect(reloaded.stockQuantity).toBe(7)

        const form = renderToStaticMarkup(
            createElement(ProductForm, { initial: reloaded, onSubmit: () => undefined })
        )
        expect(form).toContain('value="7"')
        expect(form).not.toContain('value="10"')
    })

    it('reloads only on request, through a fresh load and a rebuilt form', () => {
        const page = readSource('features/products/pages/AdminProductEditPage.tsx')

        expect(page).toContain("isApiErrorCode(cause, 'PRODUCT_STOCK_CONFLICT')")
        expect(page).toContain('setReloadVersion(value => value + 1)')
        // The load drops the copy of the rejected edit before asking the server again,
        expect(page).toContain('setInitial(null)')
        expect(page).toMatch(/const data = await ProductApi\.get\(productId!\)/)
        // and the form is keyed by the load, so its fields start from the new response.
        expect(page).toContain("key={`${id ?? 'new'}:${reloadVersion}`}")
    })

    it('warns before the reload that the typed changes will be lost', () => {
        expect(adminKo.admin.feedback.stockConflict).toContain('사라지')
        expect(adminKo.admin.feedback.reloadLatest).toContain('버리고')
        expect(adminJa.admin.feedback.stockConflict).toContain('失われ')
        expect(adminJa.admin.feedback.reloadLatest).toContain('破棄')
    })
})
