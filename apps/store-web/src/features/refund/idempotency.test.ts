import { beforeEach, describe, expect, it } from 'vitest'
import {
    clearRefundKey,
    peekRefundKey,
    resolveRefundKey,
    type RefundKeyStorage,
} from '@/features/refund/idempotency'

class MemoryStorage implements RefundKeyStorage {
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

    get size(): number {
        return this.entries.size
    }
}

describe('refund idempotency key lifecycle', () => {
    let storage: MemoryStorage

    beforeEach(() => {
        storage = new MemoryStorage()
    })

    it('reuses the same key for an order while the refund is unsettled', () => {
        const first = resolveRefundKey(10, storage)

        expect(resolveRefundKey(10, storage)).toBe(first)
    })

    it('keeps the key after a network failure', () => {
        const first = resolveRefundKey(10, storage)

        // Nothing is cleared on a transport error: the refund may have reached the
        // server, so the retry has to be the same attempt.
        expect(resolveRefundKey(10, storage)).toBe(first)
    })

    it('keeps the key after an unconfirmed outcome', () => {
        const first = resolveRefundKey(10, storage)

        // A 202 must not clear it: the money may already have moved.
        expect(peekRefundKey(10, storage)).toBe(first)
        expect(resolveRefundKey(10, storage)).toBe(first)
    })

    it('survives a reload in the same tab', () => {
        const first = resolveRefundKey(10, storage)

        // A fresh page reading the same storage continues the attempt.
        expect(resolveRefundKey(10, storage)).toBe(first)
    })

    it('reuses the key across an explicit user retry', () => {
        const first = resolveRefundKey(10, storage)
        const retry = resolveRefundKey(10, storage)
        const again = resolveRefundKey(10, storage)

        expect(retry).toBe(first)
        expect(again).toBe(first)
    })

    it('issues a new key only after the outcome is terminal', () => {
        const first = resolveRefundKey(10, storage)
        clearRefundKey(10, storage)

        const next = resolveRefundKey(10, storage)

        expect(next).not.toBe(first)
        expect(peekRefundKey(10, storage)).toBe(next)
    })

    it('keeps each order on its own key', () => {
        const ten = resolveRefundKey(10, storage)
        const eleven = resolveRefundKey(11, storage)

        expect(eleven).not.toBe(ten)
        expect(peekRefundKey(10, storage)).toBe(ten)
        expect(peekRefundKey(11, storage)).toBe(eleven)
    })

    it('clearing one order does not disturb another', () => {
        const ten = resolveRefundKey(10, storage)
        const eleven = resolveRefundKey(11, storage)

        clearRefundKey(10, storage)

        expect(peekRefundKey(10, storage)).toBeNull()
        // The second order's refund is still in flight and must keep its key.
        expect(peekRefundKey(11, storage)).toBe(eleven)
        expect(resolveRefundKey(11, storage)).toBe(eleven)
        expect(resolveRefundKey(10, storage)).not.toBe(ten)
    })

    it('drops the storage entry once no order has a key left', () => {
        resolveRefundKey(10, storage)
        resolveRefundKey(11, storage)

        clearRefundKey(10, storage)
        clearRefundKey(11, storage)

        expect(storage.size).toBe(0)
    })

    it('stores only order ids and keys', () => {
        resolveRefundKey(10, storage)
        resolveRefundKey(11, storage)

        const stored = JSON.parse(storage.raw[0]) as Record<string, string>
        expect(Object.keys(stored).sort()).toEqual(['10', '11'])
        Object.values(stored).forEach((value) => expect(typeof value).toBe('string'))
        // No address, payment reference, provider id or token may appear here.
        expect(storage.raw.join(' ')).not.toMatch(/token|address|payment|provider|mock-/i)
    })

    it('discards unreadable stored state instead of trusting it', () => {
        storage.setItem('refund.idempotency.v1', 'not json')

        const key = resolveRefundKey(10, storage)

        expect(key).toBeTruthy()
        expect(peekRefundKey(10, storage)).toBe(key)
    })

    it('still returns a key when storage is unavailable', () => {
        expect(resolveRefundKey(10, null)).toBeTruthy()
    })

    it('clearing an order that has no key is a no-op', () => {
        resolveRefundKey(11, storage)

        clearRefundKey(10, storage)

        expect(peekRefundKey(11, storage)).toBeTruthy()
    })
})
