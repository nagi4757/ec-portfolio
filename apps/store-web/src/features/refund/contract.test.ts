import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { RefundAPI } from '@/features/refund/api'
import { ApiError, isApiErrorCode } from '@/lib/api'
import { storeJa } from '@/i18n/locales/ja'
import { storeKo } from '@/i18n/locales/ko'
import { ORDER_STATUS_TRANSLATION_KEY, type OrderStatus } from '@/types/order'
import { isDirectlyCancellable, isRefundable } from '@/types/refund'

const SOURCE_ROOT = join(process.cwd(), 'src')

function readSource(relativePath: string): string {
    return readFileSync(join(SOURCE_ROOT, relativePath), 'utf8')
}

function lookup(bundle: unknown, path: string): unknown {
    return path.split('.').reduce<unknown>(
        (node, segment) =>
            node && typeof node === 'object' ? (node as Record<string, unknown>)[segment] : undefined,
        bundle,
    )
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

function stubFetch(response: Response): Captured[] {
    const calls: Captured[] = []
    vi.stubGlobal('fetch', (url: string, init: RequestInit) => {
        calls.push({ url, init })
        return Promise.resolve(response)
    })
    return calls
}

const order = { id: 30, status: 'CANCELLED', items: [], totalAmount: 2000, shippingAddress: null, createdAt: null }

describe('refund eligibility', () => {
    it('allows only the paid states where nothing has shipped', () => {
        expect(isRefundable('PENDING')).toBe(true)
        expect(isRefundable('PREPARING')).toBe(true)
    })

    it('refuses states where refunding and restocking would be wrong or meaningless', () => {
        // SHIPPED and DELIVERED: the goods are with the customer, so restoring stock
        // would be a lie. Those belong to a future return workflow.
        const refused: OrderStatus[] = [
            'SHIPPED', 'DELIVERED', 'CANCELLED', 'PAYMENT_PENDING', 'REFUND_PENDING', 'LEGACY_UNPAID',
        ]
        refused.forEach((status) => expect(isRefundable(status), status).toBe(false))
    })

    it('keeps the legacy direct cancellation path separate', () => {
        expect(isDirectlyCancellable('LEGACY_UNPAID')).toBe(true)
        const others: OrderStatus[] = ['PENDING', 'PREPARING', 'SHIPPED', 'DELIVERED', 'CANCELLED']
        others.forEach((status) => expect(isDirectlyCancellable(status), status).toBe(false))
    })
})

describe('RefundAPI.refund', () => {
    beforeEach(() => {
        const entries = new Map<string, string>()
        const storage = {
            getItem: (key: string) => entries.get(key) ?? null,
            setItem: (key: string, value: string) => void entries.set(key, value),
            removeItem: (key: string) => void entries.delete(key),
            clear: () => entries.clear(),
        }
        vi.stubGlobal('localStorage', storage)
        vi.stubGlobal('sessionStorage', storage)
    })

    afterEach(() => {
        vi.unstubAllGlobals()
    })

    it('posts to the order refund endpoint with the idempotency key', async () => {
        const calls = stubFetch(respond(200, { outcome: 'REFUNDED', order }))

        await RefundAPI.refund(30, 'refund-key-1')

        expect(calls).toHaveLength(1)
        expect(calls[0].url).toContain('/api/user/orders/30/refund')
        expect(calls[0].init.method).toBe('POST')
        expect((calls[0].init.headers as Record<string, string>)['Idempotency-Key']).toBe('refund-key-1')
    })

    it('sends no amount and no payment reference', async () => {
        const calls = stubFetch(respond(200, { outcome: 'REFUNDED', order }))

        await RefundAPI.refund(30, 'refund-key-1')

        // The server reads both from the order's settled charge; a client that could
        // name either could choose how much it is refunded.
        expect(calls[0].init.body).toBeUndefined()
    })

    it('reuses the caller supplied key across a retry', async () => {
        const calls = stubFetch(respond(202, { outcome: 'PENDING_CONFIRMATION', order }))

        await RefundAPI.refund(30, 'same-key')
        await RefundAPI.refund(30, 'same-key')

        const keys = calls.map((c) => (c.init.headers as Record<string, string>)['Idempotency-Key'])
        expect(keys).toEqual(['same-key', 'same-key'])
    })

    it('returns REFUNDED for a confirmed refund', async () => {
        stubFetch(respond(200, { outcome: 'REFUNDED', order }))

        const result = await RefundAPI.refund(30, 'k')

        expect(result.outcome).toBe('REFUNDED')
        expect(result.order.status).toBe('CANCELLED')
    })

    it('returns PENDING_CONFIRMATION rather than throwing for an unresolved refund', async () => {
        stubFetch(respond(202, {
            outcome: 'PENDING_CONFIRMATION',
            order: { ...order, status: 'REFUND_PENDING' },
        }))

        const result = await RefundAPI.refund(30, 'k')

        // 202 is neither success nor failure: the money may not have moved, so the
        // order is not cancelled.
        expect(result.outcome).toBe('PENDING_CONFIRMATION')
        expect(result.order.status).toBe('REFUND_PENDING')
    })

    it.each([
        ['REFUND_FAILED'],
        ['REFUND_ATTEMPT_IN_PROGRESS'],
        ['REFUND_NOT_ELIGIBLE'],
        ['REFUND_IDEMPOTENCY_CONFLICT'],
    ])('surfaces %s as a typed API error', async (code) => {
        // The server raises every one of these as a 409 with this code.
        stubFetch(respond(409, { code }))

        const failure = await RefundAPI.refund(30, 'k').catch((cause: unknown) => cause)

        expect(failure).toBeInstanceOf(ApiError)
        expect(isApiErrorCode(failure, code)).toBe(true)
    })
})

describe('order detail refund action', () => {
    const page = () => readSource('features/orders/pages/OrderDetailPage.tsx')

    it('shows the refund action only for refundable orders', () => {
        expect(page()).toContain('{isRefundable(order.status) && (')
        // The old unconditional cancel button for paid orders is gone.
        expect(page()).not.toContain("{order.status === 'PENDING' && (")
    })

    it('keeps the legacy cancel path for unpaid legacy orders', () => {
        expect(page()).toContain('{isDirectlyCancellable(order.status) && (')
    })

    it('clears the key only on terminal outcomes', () => {
        const source = page()
        const pendingBranch = source.slice(
            source.indexOf("result.outcome === 'PENDING_CONFIRMATION'"),
            source.indexOf('clearRefundKey(orderId)'),
        )

        // The 202 branch must return before any clear happens.
        expect(pendingBranch).toContain("setRefundFeedback('pendingConfirmation')")
        expect(pendingBranch).not.toContain('clearRefundKey')

        // An in-progress refund must not mint a new key either.
        const inProgress = source.slice(
            source.indexOf("isApiErrorCode(cause, 'REFUND_ATTEMPT_IN_PROGRESS')"),
            source.indexOf("isApiErrorCode(cause, 'REFUND_NOT_ELIGIBLE')"),
        )
        expect(inProgress).toContain("setRefundFeedback('inProgress')")
        expect(inProgress).not.toContain('clearRefundKey')
        expect(inProgress).not.toContain('resolveRefundKey')
    })

    it('re-reads the order after a completed refund', () => {
        const source = page()
        const successBranch = source.slice(
            source.indexOf('clearRefundKey(orderId)'),
            source.indexOf("setRefundFeedback('success')"),
        )

        expect(successBranch).toContain('OrderAPI.get(orderId)')
    })

    it('does not poll for an unresolved refund', () => {
        // Re-checking is an explicit user action, not a loop against the provider.
        expect(page()).not.toMatch(/setInterval|setTimeout\s*\(/)
    })
})

describe('order status presentation', () => {
    it('maps the refund-pending state', () => {
        expect(ORDER_STATUS_TRANSLATION_KEY.REFUND_PENDING).toBe('store.order.status.refundPending')
    })

    it('shows the refund states in words, not as enum names', () => {
        expect(lookup(storeKo, 'store.order.status.refundPending')).toBe('환불 확인 중')
        expect(lookup(storeJa, 'store.order.status.refundPending')).toBe('返金確認中')
        expect(lookup(storeKo, 'store.order.actions.refund')).toBe('주문 취소 및 환불')
        expect(lookup(storeJa, 'store.order.actions.refund')).toBe('注文をキャンセルして返金')
    })

    it('translates every refund message in both locales', () => {
        const keys = [
            'store.order.refund.confirm',
            'store.order.refund.success',
            'store.order.refund.pendingNotice',
            'store.order.refund.recheck',
            'store.order.refund.failed',
            'store.order.refund.inProgress',
            'store.order.refund.notEligible',
            'store.order.actions.refunding',
        ]
        keys.forEach((key) => {
            expect(lookup(storeKo, key), `ko ${key}`).toBeTruthy()
            expect(lookup(storeJa, key), `ja ${key}`).toBeTruthy()
        })
    })
})
