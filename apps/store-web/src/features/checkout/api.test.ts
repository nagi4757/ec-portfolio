import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { CheckoutAPI } from '@/features/checkout/api'
import { ApiError, isApiErrorCode } from '@/lib/api'
import { DEMO_PAYMENT_METHODS } from '@/types/checkout'
import type { ShippingAddress } from '@/types/order'

const ADDRESS: ShippingAddress = {
    recipientName: '山田 太郎',
    postalCode: '100-0001',
    prefecture: '東京都',
    city: '千代田区',
    addressLine1: '千代田1-1',
    addressLine2: null,
    phoneNumber: '03-1234-5678',
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

const order = {
    id: 30,
    status: 'PENDING',
    items: [],
    totalAmount: 2000,
    shippingAddress: ADDRESS,
    createdAt: null,
}

describe('CheckoutAPI.submit', () => {
    beforeEach(() => {
        // authStore reads web storage on every request; the node environment has none.
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

    it('posts to the checkout endpoint, never to order creation', async () => {
        const calls = stubFetch(respond(201, { outcome: 'PAID', order }))

        await CheckoutAPI.submit({ shippingAddress: ADDRESS, paymentMethodId: 'mock:success' }, 'key-1')

        expect(calls).toHaveLength(1)
        expect(calls[0].url).toContain('/api/user/checkout')
        expect(calls[0].url).not.toContain('/api/user/orders')
        expect(calls[0].init.method).toBe('POST')
    })

    it('sends the idempotency key as a header', async () => {
        const calls = stubFetch(respond(201, { outcome: 'PAID', order }))

        await CheckoutAPI.submit({ shippingAddress: ADDRESS, paymentMethodId: 'mock:success' }, 'key-abc')

        const headers = calls[0].init.headers as Record<string, string>
        expect(headers['Idempotency-Key']).toBe('key-abc')
    })

    it('never puts an amount in the request body', async () => {
        const calls = stubFetch(respond(201, { outcome: 'PAID', order }))

        await CheckoutAPI.submit({ shippingAddress: ADDRESS, paymentMethodId: 'mock:success' }, 'key-1')

        const body = JSON.parse(calls[0].init.body as string) as Record<string, unknown>
        // The server derives the total from the cart. A browser-supplied amount would
        // let a client choose what it pays.
        expect(Object.keys(body).sort()).toEqual(['paymentMethodId', 'shippingAddress'])
        expect(JSON.stringify(body)).not.toMatch(/amount/i)
        expect(JSON.stringify(body)).not.toMatch(/total/i)
    })

    it('reuses the supplied key across a retry', async () => {
        const calls = stubFetch(respond(202, { outcome: 'PENDING_CONFIRMATION', order }))
        const request = { shippingAddress: ADDRESS, paymentMethodId: 'mock:timeout' }

        await CheckoutAPI.submit(request, 'same-key')
        await CheckoutAPI.submit(request, 'same-key')

        const keys = calls.map((call) => (call.init.headers as Record<string, string>)['Idempotency-Key'])
        expect(keys).toEqual(['same-key', 'same-key'])
    })

    it('returns PAID for a confirmed charge', async () => {
        stubFetch(respond(201, { outcome: 'PAID', order }))

        const result = await CheckoutAPI.submit(
            { shippingAddress: ADDRESS, paymentMethodId: 'mock:success' },
            'key-1',
        )

        expect(result.outcome).toBe('PAID')
        expect(result.order.id).toBe(30)
    })

    it('returns PENDING_CONFIRMATION rather than throwing for an unresolved charge', async () => {
        stubFetch(respond(202, {
            outcome: 'PENDING_CONFIRMATION',
            order: { ...order, status: 'PAYMENT_PENDING' },
        }))

        const result = await CheckoutAPI.submit(
            { shippingAddress: ADDRESS, paymentMethodId: 'mock:timeout' },
            'key-1',
        )

        // 202 is neither a success nor an error: the order is reserved and the charge
        // is unknown, so the caller must not treat it as paid.
        expect(result.outcome).toBe('PENDING_CONFIRMATION')
        expect(result.order.status).toBe('PAYMENT_PENDING')
    })

    it.each([
        ['PAYMENT_DECLINED'],
        ['PAYMENT_FAILED'],
        ['PAYMENT_IDEMPOTENCY_CONFLICT'],
    ])('surfaces %s as a typed API error', async (code) => {
        stubFetch(respond(code === 'PAYMENT_IDEMPOTENCY_CONFLICT' ? 409 : 402, { code }))

        const failure = await CheckoutAPI.submit(
            { shippingAddress: ADDRESS, paymentMethodId: 'mock:declined' },
            'key-1',
        ).catch((cause: unknown) => cause)

        expect(failure).toBeInstanceOf(ApiError)
        expect(isApiErrorCode(failure, code)).toBe(true)
    })

    it('offers exactly the payment methods the mock gateway accepts', () => {
        // These strings are the gateway's contract. Guessing one would silently become
        // a failed payment, because unknown methods are treated as failures.
        expect([...DEMO_PAYMENT_METHODS]).toEqual([
            'mock:success',
            'mock:declined',
            'mock:failed',
            'mock:timeout',
        ])
    })
})
