import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { RefundAdminApi } from '@/features/refund/api'
import { ApiError, isApiErrorCode } from '@/lib/api'
import {
    ORDER_STATUS_TRANSITIONS,
    ORDER_STATUS_TRANSLATION_KEY,
    type OrderStatus,
} from '@/types/order'
import { isRefundable } from '@/types/refund'

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

function stubFetch(response: Response): Captured[] {
    const calls: Captured[] = []
    vi.stubGlobal('fetch', (url: string, init: RequestInit) => {
        calls.push({ url, init })
        return Promise.resolve(response)
    })
    return calls
}

const order = { id: 30, status: 'CANCELLED', items: [], totalAmount: 2000, shippingAddress: null, createdAt: null }

describe('admin order transitions', () => {
    it('never offers a direct transition to CANCELLED from a paid state', () => {
        // Reopening this would recreate a way to cancel a paid order without
        // returning the money, which is exactly what the refund endpoint exists for.
        Object.entries(ORDER_STATUS_TRANSITIONS)
            // LEGACY_UNPAID is the one exception: it predates checkout, carries no
            // payment, and owes nobody a refund.
            .filter(([from]) => from !== 'LEGACY_UNPAID')
            .forEach(([from, targets]) => {
                expect(targets, `${from} must not reach CANCELLED`).not.toContain('CANCELLED')
            })
    })

    it('keeps direct cancellation for the unpaid legacy state only', () => {
        expect(ORDER_STATUS_TRANSITIONS.LEGACY_UNPAID).toEqual(['CANCELLED'])
    })

    it('never offers a transition out of a refund in flight', () => {
        // Shipping an order whose refund is unresolved would send goods that are
        // being paid back for.
        expect(ORDER_STATUS_TRANSITIONS.REFUND_PENDING).toEqual([])
    })

    it('keeps the ordinary lifecycle intact', () => {
        expect(ORDER_STATUS_TRANSITIONS.PENDING).toEqual(['PREPARING'])
        expect(ORDER_STATUS_TRANSITIONS.PREPARING).toEqual(['SHIPPED'])
        expect(ORDER_STATUS_TRANSITIONS.SHIPPED).toEqual(['DELIVERED'])
    })

    it('does not send a CANCELLED status update from the page', () => {
        const page = readSource('features/orders/pages/AdminOrderDetailPage.tsx')

        expect(page).not.toMatch(/updateStatus\([^)]*'CANCELLED'/)
        expect(page).toContain('RefundAdminApi.refund')
    })
})

describe('admin refund eligibility', () => {
    it('allows only the paid states where nothing has shipped', () => {
        expect(isRefundable('PENDING')).toBe(true)
        expect(isRefundable('PREPARING')).toBe(true)
    })

    it('refuses shipped and delivered orders', () => {
        // The goods are with the customer; restoring stock would be a lie. Those
        // belong to a future return workflow.
        const refused: OrderStatus[] = [
            'SHIPPED', 'DELIVERED', 'CANCELLED', 'PAYMENT_PENDING', 'REFUND_PENDING', 'LEGACY_UNPAID',
        ]
        refused.forEach((status) => expect(isRefundable(status), status).toBe(false))
    })

    it('shows the refund action only for refundable or unresolved orders', () => {
        const page = readSource('features/orders/pages/AdminOrderDetailPage.tsx')

        expect(page).toContain("(isRefundable(order.status) || order.status === 'REFUND_PENDING')")
    })
})

describe('RefundAdminApi.refund', () => {
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

    it('posts to the admin refund endpoint with the idempotency key', async () => {
        const calls = stubFetch(respond(200, { outcome: 'REFUNDED', order }))

        await RefundAdminApi.refund(30, 'admin-key-1')

        expect(calls[0].url).toContain('/api/admin/orders/30/refund')
        expect(calls[0].init.method).toBe('POST')
        expect((calls[0].init.headers as Record<string, string>)['Idempotency-Key']).toBe('admin-key-1')
    })

    it('sends no amount and no payment reference', async () => {
        const calls = stubFetch(respond(200, { outcome: 'REFUNDED', order }))

        await RefundAdminApi.refund(30, 'admin-key-1')

        expect(calls[0].init.body).toBeUndefined()
    })

    it('returns PENDING_CONFIRMATION rather than throwing for an unresolved refund', async () => {
        stubFetch(respond(202, {
            outcome: 'PENDING_CONFIRMATION',
            order: { ...order, status: 'REFUND_PENDING' },
        }))

        const result = await RefundAdminApi.refund(30, 'k')

        expect(result.outcome).toBe('PENDING_CONFIRMATION')
        expect(result.order.status).toBe('REFUND_PENDING')
    })

    it.each([
        ['REFUND_FAILED'],
        ['REFUND_ATTEMPT_IN_PROGRESS'],
        ['REFUND_NOT_ELIGIBLE'],
    ])('surfaces %s as a typed API error', async (code) => {
        stubFetch(respond(409, { code }))

        const failure = await RefundAdminApi.refund(30, 'k').catch((cause: unknown) => cause)

        expect(failure).toBeInstanceOf(ApiError)
        expect(isApiErrorCode(failure, code)).toBe(true)
    })
})

describe('admin refund key lifecycle in the page', () => {
    const page = () => readSource('features/orders/pages/AdminOrderDetailPage.tsx')

    it('clears the key only on terminal outcomes', () => {
        const source = page()
        const pendingBranch = source.slice(
            source.indexOf("result.outcome === 'PENDING_CONFIRMATION'"),
            source.indexOf('clearRefundKey(orderId)'),
        )

        expect(pendingBranch).not.toContain('clearRefundKey')

        const inProgress = source.slice(
            source.indexOf("isApiErrorCode(cause, 'REFUND_ATTEMPT_IN_PROGRESS')"),
            source.indexOf("isApiErrorCode(cause, 'REFUND_NOT_ELIGIBLE')"),
        )
        expect(inProgress).not.toContain('clearRefundKey')
        expect(inProgress).not.toContain('resolveRefundKey')
    })

    it('does not poll for an unresolved refund', () => {
        expect(page()).not.toMatch(/setInterval|setTimeout\s*\(/)
    })
})

describe('admin status presentation', () => {
    it('maps the refund-pending state', () => {
        expect(ORDER_STATUS_TRANSLATION_KEY.REFUND_PENDING).toBe('admin.order.status.refundPending')
    })
})
