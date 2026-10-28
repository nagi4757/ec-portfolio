import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ProductApi } from '@/features/products/api'
import ProductForm from '@/features/products/components/ProductForm'
import {
    buildUpdatePayload,
    changedSinceLoad,
    isSaveOutcomeUnknown,
    saveEdit,
    type ProductFormValues,
} from '@/features/products/updatePayload'
import { adminJa } from '@/i18n/locales/ja'
import { adminKo } from '@/i18n/locales/ko'
import { ApiError, isApiErrorCode } from '@/lib/api'
import type { Product, UpdateProduct } from '@/types/product'

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

function refusal(status: number, code: string | null): ApiError {
    return new ApiError(status, code, `API request failed (HTTP ${status}).`)
}

function failureOf(request: Promise<unknown>): Promise<unknown> {
    return request.then(() => null, (cause: unknown) => cause)
}

type Exchange = { method: 'GET' } | { method: 'PATCH'; body: UpdateProduct }

/** Answers the product read and the PATCH as told, and records what was asked of it. */
function editApi(answers: { read?: () => Promise<Product>; update?: () => Promise<unknown> }) {
    const exchanges: Exchange[] = []
    return {
        exchanges,
        read: () => {
            exchanges.push({ method: 'GET' })
            return answers.read ? answers.read() : Promise.reject(new Error('Unexpected read'))
        },
        update: (body: UpdateProduct) => {
            exchanges.push({ method: 'PATCH', body })
            return answers.update ? answers.update() : Promise.resolve(loaded)
        },
    }
}

describe('save outcome', () => {
    it('cannot tell from a dropped connection whether the update was written', () => {
        // The response is what got lost when the update was committed and the connection broke after.
        expect(isSaveOutcomeUnknown(new TypeError('Failed to fetch'))).toBe(true)
    })

    it('cannot tell from a 408 or a 429 either', () => {
        expect(isSaveOutcomeUnknown(refusal(408, null))).toBe(true)
        expect(isSaveOutcomeUnknown(refusal(429, null))).toBe(true)
        expect(isSaveOutcomeUnknown(refusal(429, 'TOO_MANY_REQUESTS'))).toBe(true)
    })

    it('cannot tell from a server or gateway error', () => {
        for (const status of [500, 502, 503, 504]) {
            expect(isSaveOutcomeUnknown(refusal(status, null)), `${status}`).toBe(true)
        }
        // Answered after the commit when building the response fails.
        expect(isSaveOutcomeUnknown(refusal(500, 'INTERNAL_SERVER_ERROR'))).toBe(true)
    })

    it('cannot tell from a success whose body could not be read', () => {
        // lib/api throws this for a 2xx that is not JSON: the update may well have been written.
        expect(isSaveOutcomeUnknown(refusal(200, null))).toBe(true)
    })

    it('knows the refusals the update API answers without writing anything', () => {
        // Answered before the update runs, or from inside its transaction, which rolls back.
        expect(isSaveOutcomeUnknown(refusal(400, 'VALIDATION_FAILED'))).toBe(false)
        expect(isSaveOutcomeUnknown(refusal(400, 'MALFORMED_REQUEST'))).toBe(false)
        expect(isSaveOutcomeUnknown(refusal(401, 'UNAUTHORIZED'))).toBe(false)
        expect(isSaveOutcomeUnknown(refusal(403, 'ACCESS_DENIED'))).toBe(false)
        expect(isSaveOutcomeUnknown(refusal(404, 'PRODUCT_NOT_FOUND'))).toBe(false)
        expect(isSaveOutcomeUnknown(refusal(409, 'PRODUCT_STOCK_CONFLICT'))).toBe(false)
    })

    it('does not take any other 4xx as proof that nothing was written', () => {
        const others: [number, string | null][] = [
            [400, null], [400, 'BAD_REQUEST'], [403, null], [404, null], [404, 'RESOURCE_NOT_FOUND'],
            [405, null], [409, null], [409, 'CONFLICT'], [409, 'PRODUCT_NOT_AVAILABLE'], [413, null],
        ]
        for (const [status, code] of others) {
            expect(isSaveOutcomeUnknown(refusal(status, code)), `${status} ${code}`).toBe(true)
        }
        // A known code under another status is not that refusal.
        expect(isSaveOutcomeUnknown(refusal(400, 'PRODUCT_STOCK_CONFLICT'))).toBe(true)
    })

    it('classifies what the API client throws', async () => {
        vi.stubGlobal('fetch', () => Promise.reject(new TypeError('Failed to fetch')))
        expect(isSaveOutcomeUnknown(await failureOf(ProductApi.update(7, { price: 15000 })))).toBe(true)

        stubFetch(respond(408, {}), respond(429, {}), respond(409, { code: 'PRODUCT_STOCK_CONFLICT' }))
        expect(isSaveOutcomeUnknown(await failureOf(ProductApi.update(7, { price: 15000 })))).toBe(true)
        expect(isSaveOutcomeUnknown(await failureOf(ProductApi.update(7, { price: 15000 })))).toBe(true)
        expect(isSaveOutcomeUnknown(
            await failureOf(ProductApi.update(7, { stockQuantity: 25, expectedStockQuantity: 10 }))
        )).toBe(false)
    })
})

describe('settling an unconfirmed save', () => {
    // The admin raised the price from 12000 to 15000, and the response to that save was lost.
    const priceRaise: UpdateProduct = { price: 15000 }

    it('sees a field of the unconfirmed save written on the server', () => {
        expect(changedSinceLoad(loaded, priceRaise, { ...loaded, price: 15000 })).toBe(true)
    })

    it('sees nothing when the server still has what the form loaded', () => {
        expect(changedSinceLoad(loaded, priceRaise, loaded)).toBe(false)
    })

    it('ignores fields the unconfirmed save did not carry', () => {
        // Checkout took 3, and another admin edited the description and deactivated the product.
        const moved = { ...loaded, stockQuantity: 7, description: 'Stoneware mug', active: false }

        expect(changedSinceLoad(loaded, priceRaise, moved)).toBe(false)
    })

    it('sees a moved stock when the unconfirmed save changed the stock', () => {
        const stockChange: UpdateProduct = { stockQuantity: 20, expectedStockQuantity: 10 }

        // Written by that save, or moved by checkout: either way the loaded stock is stale.
        expect(changedSinceLoad(loaded, stockChange, { ...loaded, stockQuantity: 20 })).toBe(true)
        expect(changedSinceLoad(loaded, stockChange, { ...loaded, stockQuantity: 9 })).toBe(true)
        expect(changedSinceLoad(loaded, stockChange, loaded)).toBe(false)
    })

    it('sees a field of the unconfirmed save that someone else changed', () => {
        expect(changedSinceLoad(loaded, { name: 'Big mug' }, { ...loaded, name: 'Tea mug' })).toBe(true)
    })

    it('compares an image URL and a description the way the form shows them', () => {
        expect(changedSinceLoad(loaded, { description: '' }, { ...loaded, description: '' })).toBe(true)
        expect(changedSinceLoad(loaded, { description: '' }, { ...loaded, description: null })).toBe(true)
        // A missing value and '' both show as an empty field.
        const typedIntoMissing: UpdateProduct = { imageUrl: 'https://example.test/new.png', description: 'New' }
        expect(changedSinceLoad(bare, typedIntoMissing, { ...bare, imageUrl: '', description: '' })).toBe(false)
    })
})

describe('saving an edit', () => {
    it('sends the changes when no earlier save is unconfirmed', async () => {
        const api = editApi({})

        expect(await saveEdit(loaded, { price: 15000 }, null, api)).toEqual({ outcome: 'saved', unconfirmed: null })
        expect(api.exchanges).toEqual([{ method: 'PATCH', body: { price: 15000 } }])
    })

    it('sends nothing when nothing changed', async () => {
        const api = editApi({})

        expect(await saveEdit(loaded, {}, null, api)).toEqual({ outcome: 'noChanges', unconfirmed: null })
        expect(api.exchanges).toEqual([])
    })

    it('keeps a save that may have been written as unconfirmed', async () => {
        for (const cause of [new TypeError('Failed to fetch'), refusal(408, null), refusal(429, null), refusal(502, null)]) {
            const api = editApi({ update: () => Promise.reject(cause) })

            expect(await saveEdit(loaded, { price: 15000 }, null, api), `${cause}`)
                .toEqual({ outcome: 'unknown', unconfirmed: { price: 15000 } })
        }
    })

    it('hands back a refusal that wrote nothing', async () => {
        const conflict = refusal(409, 'PRODUCT_STOCK_CONFLICT')
        const api = editApi({ update: () => Promise.reject(conflict) })

        expect(await saveEdit(loaded, { stockQuantity: 25, expectedStockQuantity: 10 }, null, api))
            .toEqual({ outcome: 'refused', unconfirmed: null, cause: conflict })
    })

    it('reads the product before sending again, and sends if the unconfirmed save was not written', async () => {
        const api = editApi({ read: () => Promise.resolve(loaded) })

        expect(await saveEdit(loaded, { price: 15000 }, { price: 15000 }, api))
            .toEqual({ outcome: 'saved', unconfirmed: null })
        expect(api.exchanges).toEqual([{ method: 'GET' }, { method: 'PATCH', body: { price: 15000 } }])
    })

    it('does not send values set back to the loaded ones over a save that was written', async () => {
        // The raise to 15000 was written and its response lost; the admin then set 12000 again,
        // which leaves nothing to send against the form as loaded.
        const unconfirmed: UpdateProduct = { price: 15000 }
        const api = editApi({ read: () => Promise.resolve({ ...loaded, price: 15000 }) })

        const result = await saveEdit(loaded, {}, unconfirmed, api)

        expect(result.outcome).toBe('changedSinceLoad')
        expect(result.unconfirmed).toBe(unconfirmed)
        expect(api.exchanges).toEqual([{ method: 'GET' }])
    })

    it('does not send the rest of an edit when one of its fields was set back', async () => {
        const api = editApi({ read: () => Promise.resolve({ ...loaded, name: 'Big mug', price: 15000 }) })

        const result = await saveEdit(loaded, { name: 'Big mug' }, { name: 'Big mug', price: 15000 }, api)

        expect(result.outcome).toBe('changedSinceLoad')
        expect(api.exchanges).toEqual([{ method: 'GET' }])
    })

    it('does not send a stock set back over a stock change that was written', async () => {
        const api = editApi({ read: () => Promise.resolve({ ...loaded, stockQuantity: 20 }) })

        const result = await saveEdit(loaded, {}, { stockQuantity: 20, expectedStockQuantity: 10 }, api)

        expect(result.outcome).toBe('changedSinceLoad')
        expect(api.exchanges).toEqual([{ method: 'GET' }])
    })

    it('sends the edit when only fields outside the unconfirmed save moved', async () => {
        // Checkout took 3 while the price raise was unconfirmed. The stock stays out of the
        // PATCH, and a stock change would still be checked against the stock the form loaded.
        const api = editApi({ read: () => Promise.resolve({ ...loaded, stockQuantity: 7 }) })

        expect((await saveEdit(loaded, { price: 15000 }, { price: 15000 }, api)).outcome).toBe('saved')
        expect(api.exchanges).toEqual([{ method: 'GET' }, { method: 'PATCH', body: { price: 15000 } }])
    })

    it('does not send when the product cannot be read, and keeps the earlier save unconfirmed', async () => {
        const unconfirmed: UpdateProduct = { price: 15000 }
        for (const cause of [new TypeError('Failed to fetch'), refusal(408, null), refusal(503, null)]) {
            const api = editApi({ read: () => Promise.reject(cause) })

            // The admin has set the price back meanwhile, so this edit has nothing of its own.
            const result = await saveEdit(loaded, {}, unconfirmed, api)

            expect(result.outcome, `${cause}`).toBe('checkFailed')
            expect(result.unconfirmed).toBe(unconfirmed)
            expect(api.exchanges).toEqual([{ method: 'GET' }])
        }
    })

    it('settles the original unconfirmed save once the product can be read again', async () => {
        const unread = editApi({ read: () => Promise.reject(new TypeError('Failed to fetch')) })
        const failed = await saveEdit(loaded, {}, { price: 15000 }, unread)

        // Written: the price set back must not pass for "no changes".
        const written = editApi({ read: () => Promise.resolve({ ...loaded, price: 15000 }) })
        expect((await saveEdit(loaded, {}, failed.unconfirmed, written)).outcome).toBe('changedSinceLoad')
        expect(written.exchanges).toEqual([{ method: 'GET' }])

        // Not written: the edit goes out after the read.
        const unwritten = editApi({ read: () => Promise.resolve(loaded) })
        expect(await saveEdit(loaded, { price: 15000 }, failed.unconfirmed, unwritten))
            .toEqual({ outcome: 'saved', unconfirmed: null })
        expect(unwritten.exchanges).toEqual([{ method: 'GET' }, { method: 'PATCH', body: { price: 15000 } }])
    })

    it('reports no changes only once the unconfirmed save is settled', async () => {
        const api = editApi({ read: () => Promise.resolve(loaded) })

        expect(await saveEdit(loaded, {}, { price: 15000 }, api)).toEqual({ outcome: 'noChanges', unconfirmed: null })
        expect(api.exchanges).toEqual([{ method: 'GET' }])
    })

    it('replaces a settled save with the next one whose outcome is unknown', async () => {
        const api = editApi({ read: () => Promise.resolve(loaded), update: () => Promise.reject(refusal(429, null)) })

        expect(await saveEdit(loaded, { name: 'Big mug' }, { price: 15000 }, api))
            .toEqual({ outcome: 'unknown', unconfirmed: { name: 'Big mug' } })
    })
})

describe('product edit page', () => {
    const page = () => readSource('features/products/pages/AdminProductEditPage.tsx')

    /** The body of the effect that loads the product. */
    function loadEffect(source: string): string {
        const start = source.indexOf('useEffect(() => {')
        const end = source.indexOf('}, [isEdit, productId, reloadVersion])')
        expect(start).toBeGreaterThan(-1)
        expect(end).toBeGreaterThan(start)
        return source.slice(start, end)
    }

    it('saves an edit through saveEdit with this product', () => {
        const source = page()

        expect(source).toContain('saveEdit(initial!, data as UpdateProduct, unconfirmed, {')
        expect(source).toContain('read: () => ProductApi.get(productId!)')
        expect(source).toContain('update: changes => ProductApi.update(productId!, changes)')
        // What stays unconfirmed is whatever the save leaves unconfirmed.
        expect(source).toContain('setUnconfirmed(result.unconfirmed)')
    })

    it('shows a refusal that wrote nothing as before', () => {
        const source = page()

        expect(source).toContain("if (result.outcome === 'refused') throw result.cause")
        expect(source).toContain("isApiErrorCode(cause, 'PRODUCT_STOCK_CONFLICT')")
    })

    it('starts every load with nothing unconfirmed and no notice', () => {
        const effect = loadEffect(page())

        expect(effect).toContain('setUnconfirmed(null)')
        expect(effect).toContain('setNotice(null)')
    })

    it('keeps the stock conflict warning and its reload when there is nothing to send', () => {
        const source = page()

        expect(source).toContain('const stockConflictShown = saveError === STOCK_CONFLICT')
        expect(source).toContain('if (stockConflictShown) setSaveError(STOCK_CONFLICT)')
        expect(source).toContain('setNotice(NO_CHANGES)')
    })

    it('offers the reload when the server moved a field of the unconfirmed save', () => {
        expect(page()).toContain('saveError === STOCK_CONFLICT || saveError === CHANGED_SINCE_LOAD')
    })

    it('keeps what the admin typed until they ask for the reload', () => {
        const source = page()

        // Only a load replaces the product the form diffs against ...
        expect(source.match(/setInitial\(/g)).toHaveLength(2)
        expect(loadEffect(source).match(/setInitial\(/g)).toHaveLength(2)
        // ... and only the retry of a failed load and the reload button start one.
        expect(source.match(/setReloadVersion\(/g)).toHaveLength(2)
    })
})

describe('save feedback', () => {
    const added = ['saveOutcomeUnknown', 'changedSinceLoad', 'checkFailed', 'noChanges'] as const

    it('has the new messages in Korean and Japanese', () => {
        for (const key of added) {
            expect(adminKo.admin.feedback[key], `ko ${key}`).toMatch(/\S/)
            expect(adminJa.admin.feedback[key], `ja ${key}`).toMatch(/\S/)
        }
    })

    it('says that a save whose outcome is unknown may already be written', () => {
        expect(adminKo.admin.feedback.saveOutcomeUnknown).toContain('반영되었을 수')
        expect(adminJa.admin.feedback.saveOutcomeUnknown).toContain('反映されている可能性')
    })

    it('warns before the reload offered for a moved value that the typed changes will be lost', () => {
        expect(adminKo.admin.feedback.changedSinceLoad).toContain('사라지')
        expect(adminJa.admin.feedback.changedSinceLoad).toContain('失われ')
    })

    it('says that nothing was sent when the check failed or nothing changed', () => {
        expect(adminKo.admin.feedback.checkFailed).toContain('저장하지 않았습니다')
        expect(adminJa.admin.feedback.checkFailed).toContain('保存しませんでした')
        expect(adminKo.admin.feedback.noChanges).toContain('저장하지 않았습니다')
        expect(adminJa.admin.feedback.noChanges).toContain('保存しませんでした')
    })

    it('leaves the existing messages as they were', () => {
        expect(adminKo.admin.feedback.saveFailed).toBe('저장하지 못했습니다. 입력 내용은 유지되어 있습니다. 다시 시도해 주세요.')
        expect(adminJa.admin.feedback.saveFailed).toBe('保存できませんでした。入力内容は保持されています。再度お試しください。')
        expect(adminKo.admin.feedback.reloadLatest).toBe('입력 내용을 버리고 최신 정보 불러오기')
        expect(adminJa.admin.feedback.reloadLatest).toBe('入力内容を破棄して最新の情報を読み込む')
        expect(adminKo.admin.feedback.stockConflict).toBe(
            '다른 처리(주문·환불 등)에서 재고가 먼저 변경되어 저장하지 않았습니다. 최신 정보를 다시 불러오면 입력 중인 상품명·가격 등은 사라지므로 필요한 내용은 먼저 적어 두세요. 재고를 바꾸지 않고 다른 항목만 저장하려면 재고를 처음 값으로 되돌린 뒤 다시 저장하세요.'
        )
        expect(adminJa.admin.feedback.stockConflict).toBe(
            '他の処理（注文・返金など）で在庫が先に変更されたため、保存しませんでした。最新の情報を再読み込みすると、入力中の商品名・価格などは失われるため、必要な内容は先に控えてください。在庫を変えずに他の項目だけ保存する場合は、在庫を最初の値に戻してから再度保存してください。'
        )
    })
})
