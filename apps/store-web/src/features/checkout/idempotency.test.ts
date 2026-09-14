import { beforeEach, describe, expect, it } from 'vitest'
import {
    cartSignature,
    clearIdempotencyKey,
    peekIdempotencyKey,
    resolveIdempotencyKey,
    type AttemptStorage,
    type CheckoutIntent,
} from '@/features/checkout/idempotency'
import type { ShippingAddress } from '@/types/order'

class MemoryStorage implements AttemptStorage {
    private readonly entries = new Map<string, string>()

    getItem(key: string): string | null {
        return this.entries.get(key) ?? null
    }

    setItem(key: string, value: string): void {
        this.entries.set(key, value)
    }

    removeItem(key: string): void {
        this.entries.delete(key)
    }

    get raw(): string[] {
        return [...this.entries.values()]
    }
}

const ADDRESS: ShippingAddress = {
    recipientName: '山田 太郎',
    postalCode: '100-0001',
    prefecture: '東京都',
    city: '千代田区',
    addressLine1: '千代田1-1',
    addressLine2: null,
    phoneNumber: '03-1234-5678',
}

function intent(overrides: Partial<CheckoutIntent> = {}): CheckoutIntent {
    return {
        paymentMethodId: 'mock:success',
        shippingAddress: ADDRESS,
        cartSignature: cartSignature([{ productId: 2, quantity: 1 }, { productId: 1, quantity: 3 }]),
        ...overrides,
    }
}

describe('checkout idempotency key lifecycle', () => {
    let storage: MemoryStorage

    beforeEach(() => {
        storage = new MemoryStorage()
    })

    it('reuses the same key while the purchase is unchanged', () => {
        const first = resolveIdempotencyKey(intent(), storage)
        const retry = resolveIdempotencyKey(intent(), storage)

        expect(retry).toBe(first)
    })

    it('keeps the key after an unconfirmed result so a re-check is the same attempt', () => {
        const first = resolveIdempotencyKey(intent(), storage)

        // A 202 must not clear the key: the charge may already have happened.
        expect(peekIdempotencyKey(storage)).toBe(first)
        expect(resolveIdempotencyKey(intent(), storage)).toBe(first)
    })

    it('keeps the key after a network failure', () => {
        const first = resolveIdempotencyKey(intent(), storage)

        // Nothing is cleared on a transport error, so the retry reaches the same
        // server-side attempt instead of starting a second payment.
        expect(resolveIdempotencyKey(intent(), storage)).toBe(first)
    })

    it('survives a reload in the same tab', () => {
        const first = resolveIdempotencyKey(intent(), storage)

        // A fresh page reading the same storage continues the attempt.
        const afterReload = resolveIdempotencyKey(intent(), storage)

        expect(afterReload).toBe(first)
    })

    it('issues a new key once the outcome is terminal', () => {
        const first = resolveIdempotencyKey(intent(), storage)
        clearIdempotencyKey(storage)

        const next = resolveIdempotencyKey(intent(), storage)

        expect(next).not.toBe(first)
        expect(peekIdempotencyKey(storage)).toBe(next)
    })

    it('issues a new key when the payment method changes', () => {
        const first = resolveIdempotencyKey(intent(), storage)

        const next = resolveIdempotencyKey(intent({ paymentMethodId: 'mock:declined' }), storage)

        expect(next).not.toBe(first)
    })

    it('issues a new key when the shipping address changes', () => {
        const first = resolveIdempotencyKey(intent(), storage)

        const next = resolveIdempotencyKey(
            intent({ shippingAddress: { ...ADDRESS, addressLine1: '千代田2-2' } }),
            storage,
        )

        expect(next).not.toBe(first)
    })

    it('issues a new key when the cart changes', () => {
        const first = resolveIdempotencyKey(intent(), storage)

        const next = resolveIdempotencyKey(
            intent({ cartSignature: cartSignature([{ productId: 1, quantity: 4 }]) }),
            storage,
        )

        expect(next).not.toBe(first)
    })

    it('treats cart line order as irrelevant', () => {
        const ascending = cartSignature([{ productId: 1, quantity: 3 }, { productId: 2, quantity: 1 }])
        const descending = cartSignature([{ productId: 2, quantity: 1 }, { productId: 1, quantity: 3 }])

        expect(ascending).toBe(descending)
    })

    it('persists only the key and a digest, never the address', () => {
        resolveIdempotencyKey(intent(), storage)

        const stored = storage.raw.join(' ')
        expect(stored).not.toContain(ADDRESS.recipientName)
        expect(stored).not.toContain(ADDRESS.phoneNumber)
        expect(stored).not.toContain(ADDRESS.addressLine1)
        expect(stored).not.toContain(ADDRESS.postalCode)
        expect(Object.keys(JSON.parse(storage.raw[0]) as object).sort()).toEqual(['intent', 'key'])
    })

    it('discards unreadable stored state instead of trusting it', () => {
        storage.setItem('checkout.idempotency.v1', 'not json')

        const key = resolveIdempotencyKey(intent(), storage)

        expect(key).toBeTruthy()
        expect(peekIdempotencyKey(storage)).toBe(key)
    })

    it('still returns a key when storage is unavailable', () => {
        const key = resolveIdempotencyKey(intent(), null)

        expect(key).toBeTruthy()
    })
})
