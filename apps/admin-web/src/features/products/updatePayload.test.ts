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
    imageUrl: 'https://example.test/mug.png',
    description: 'Ceramic mug',
}

/** A product stored without an image URL or description. */
const bare: Product = { ...loaded, imageUrl: null, description: null }

/** The form as it opens on [product]: a missing image URL or description shows as ''. */
function formOf(product: Product): ProductFormValues {
    return {
        name: product.name,
        price: product.price,
        stockQuantity: product.stockQuantity,
        imageUrl: product.imageUrl ?? '',
        description: product.description ?? '',
    }
}

function edited(changes: Partial<ProductFormValues>, product: Product = loaded): ProductFormValues {
    return { ...formOf(product), ...changes }
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
    it('sends only the name when only the name changed', () => {
        // Sending the other fields back as loaded would overwrite whatever another
        // admin, checkout or a refund changed while the form was open.
        expect(buildUpdatePayload(loaded, edited({ name: 'Big mug' }))).toEqual({ name: 'Big mug' })
    })

    it('sends only the price when only the price changed', () => {
        expect(buildUpdatePayload(loaded, edited({ price: 15000 }))).toEqual({ price: 15000 })
    })

    it('treats a price set to zero as a change', () => {
        expect(buildUpdatePayload(loaded, edited({ price: 0 }))).toEqual({ price: 0 })
    })

    it('detects a changed image URL and a changed description', () => {
        expect(buildUpdatePayload(loaded, edited({ imageUrl: 'https://example.test/new.png' })))
            .toEqual({ imageUrl: 'https://example.test/new.png' })
        expect(buildUpdatePayload(loaded, edited({ description: 'Stoneware mug' })))
            .toEqual({ description: 'Stoneware mug' })
    })

    it('sends a cleared image URL or description as an empty string, as before', () => {
        expect(buildUpdatePayload(loaded, edited({ imageUrl: '', description: '' })))
            .toEqual({ imageUrl: '', description: '' })
    })

    it('sends nothing when nothing changed', () => {
        expect(buildUpdatePayload(loaded, formOf(loaded))).toEqual({})
    })

    it('treats a missing image URL or description left empty as unchanged', () => {
        // The form shows null as ''. Sending that '' would replace null on every save.
        expect(buildUpdatePayload(bare, formOf(bare))).toEqual({})
        const absent: Product = { ...loaded, imageUrl: undefined, description: undefined }
        expect(buildUpdatePayload(absent, formOf(absent))).toEqual({})
    })

    it('sends what was typed into a field that was missing', () => {
        expect(buildUpdatePayload(bare, edited({ imageUrl: 'https://example.test/new.png' }, bare)))
            .toEqual({ imageUrl: 'https://example.test/new.png' })
        expect(buildUpdatePayload(bare, edited({ description: 'New' }, bare)))
            .toEqual({ description: 'New' })
    })

    it('treats fields changed and then changed back as unchanged', () => {
        // The admin edited the name, price and stock, then restored what was loaded.
        const restored = edited({ name: 'Mug', price: 12000, stockQuantity: 10 })

        expect(buildUpdatePayload(loaded, restored)).toEqual({})
    })

    it('sends a changed stock together with the stock the form was loaded with', () => {
        expect(buildUpdatePayload(loaded, edited({ stockQuantity: 25 })))
            .toEqual({ stockQuantity: 25, expectedStockQuantity: 10 })
    })

    it('treats a stock set to zero as a change', () => {
        expect(buildUpdatePayload(loaded, edited({ stockQuantity: 0 })))
            .toEqual({ stockQuantity: 0, expectedStockQuantity: 10 })
    })

    it('keeps the stock pair alongside other changes', () => {
        expect(buildUpdatePayload(loaded, edited({ name: 'Big mug', stockQuantity: 25 })))
            .toEqual({ name: 'Big mug', stockQuantity: 25, expectedStockQuantity: 10 })
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
