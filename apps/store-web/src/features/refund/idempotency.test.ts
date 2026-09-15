import { beforeEach, describe, expect, it } from 'vitest'
import {
    clearRefundKey,
    peekRefundKey,
    resetSessionRefundKeys,
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
        // The in-memory fallback is module scope so it can outlive a component.
        // Each test needs a fresh page session.
        resetSessionRefundKeys()
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

/**
 * Storage does not only succeed or go missing: reading throws SecurityError under
 * some privacy settings and writing throws QuotaExceededError when the quota is
 * full. Nothing here may propagate, because the caller raises its in-flight flag
 * before asking for a key -- an exception would leave the refund button disabled
 * for good.
 */
describe('refund idempotency when storage operations throw', () => {
    class ThrowingStorage implements RefundKeyStorage {
        private readonly entries = new Map<string, string>()
        private readonly failing: ReadonlySet<'get' | 'set' | 'remove'>

        constructor(failing: ReadonlySet<'get' | 'set' | 'remove'>) {
            this.failing = failing
        }

        getItem(key: string): string | null {
            if (this.failing.has('get')) throw new DOMException('denied', 'SecurityError')
            return this.entries.get(key) ?? null
        }

        setItem(key: string, value: string): void {
            if (this.failing.has('set')) throw new DOMException('full', 'QuotaExceededError')
            this.entries.set(key, value)
        }

        removeItem(key: string): void {
            if (this.failing.has('remove')) throw new DOMException('denied', 'SecurityError')
            this.entries.delete(key)
        }

        /** What survived in durable storage, as the next page load would read it. */
        raw(key: string): string | null {
            return this.entries.get(key) ?? null
        }
    }

    beforeEach(() => {
        resetSessionRefundKeys()
    })

    it('returns a key when getItem throws', () => {
        const storage = new ThrowingStorage(new Set(['get']))

        expect(() => resolveRefundKey(10, storage)).not.toThrow()
        expect(resolveRefundKey(10, storage)).toBeTruthy()
    })

    it('returns a key when setItem throws', () => {
        const storage = new ThrowingStorage(new Set(['set']))

        expect(() => resolveRefundKey(10, storage)).not.toThrow()
        expect(resolveRefundKey(10, storage)).toBeTruthy()
    })

    it('clearing survives removeItem throwing', () => {
        const storage = new ThrowingStorage(new Set(['remove']))
        resolveRefundKey(10, storage)

        expect(() => clearRefundKey(10, storage)).not.toThrow()
    })

    it('peeking survives getItem throwing', () => {
        const storage = new ThrowingStorage(new Set(['get']))

        expect(() => peekRefundKey(10, storage)).not.toThrow()
    })

    it('keeps one key per order in this tab even when writes never persist', () => {
        const storage = new ThrowingStorage(new Set(['set']))

        const first = resolveRefundKey(10, storage)
        const retry = resolveRefundKey(10, storage)

        // The durable copy was never written, but a retry in this tab must still be
        // the same attempt. Minting a fresh key per retry is what risks a second
        // refund, so the key is held in memory for the rest of the page session.
        expect(retry).toBe(first)
        expect(peekRefundKey(10, storage)).toBe(first)
    })

    it('still separates orders when writes never persist', () => {
        const storage = new ThrowingStorage(new Set(['set']))

        const ten = resolveRefundKey(10, storage)
        const eleven = resolveRefundKey(11, storage)

        expect(eleven).not.toBe(ten)
    })

    it('a terminal outcome still releases the key when writes never persist', () => {
        const storage = new ThrowingStorage(new Set(['set']))
        const first = resolveRefundKey(10, storage)

        clearRefundKey(10, storage)

        expect(peekRefundKey(10, storage)).toBeNull()
        expect(resolveRefundKey(10, storage)).not.toBe(first)
    })

    it('survives every storage operation failing at once', () => {
        const storage = new ThrowingStorage(new Set(['get', 'set', 'remove']))

        expect(() => {
            const key = resolveRefundKey(10, storage)
            expect(key).toBeTruthy()
            expect(resolveRefundKey(10, storage)).toBe(key)
            clearRefundKey(10, storage)
            peekRefundKey(10, storage)
        }).not.toThrow()
    })
})

/**
 * A settled key that storage refuses to delete is a liveness problem, not a money
 * one. Read back on the next request it would drive the server to replay an attempt
 * that is already terminal: no double refund, but the customer could never open a
 * new one either. Clearing therefore has to hold whatever storage does with it.
 */
describe('clearing a refund key when storage will not delete', () => {
    class UnreliableStorage implements RefundKeyStorage {
        private readonly entries = new Map<string, string>()
        private readonly failing: Set<'get' | 'set' | 'remove'>

        constructor(failing: Iterable<'get' | 'set' | 'remove'> = []) {
            this.failing = new Set(failing)
        }

        fail(op: 'get' | 'set' | 'remove'): void {
            this.failing.add(op)
        }

        getItem(key: string): string | null {
            if (this.failing.has('get')) throw new DOMException('denied', 'SecurityError')
            return this.entries.get(key) ?? null
        }

        setItem(key: string, value: string): void {
            if (this.failing.has('set')) throw new DOMException('full', 'QuotaExceededError')
            this.entries.set(key, value)
        }

        removeItem(key: string): void {
            if (this.failing.has('remove')) throw new DOMException('denied', 'SecurityError')
            this.entries.delete(key)
        }

        /** What durable storage holds, as the next page load would read it. */
        raw(key: string): string | null {
            return this.entries.get(key) ?? null
        }
    }

    const STORAGE_KEY = 'refund.idempotency.v1'

    beforeEach(() => {
        resetSessionRefundKeys()
    })

    it('clears the key when removeItem throws but a write still succeeds', () => {
        const storage = new UnreliableStorage()
        const terminal = resolveRefundKey(10, storage)
        expect(storage.raw(STORAGE_KEY)).toContain(terminal)

        // Deleting is refused from here on; writing still works.
        storage.fail('remove')
        clearRefundKey(10, storage)

        expect(peekRefundKey(10, storage)).toBeNull()
        // The fallback overwrote the entry rather than leaving the settled key behind,
        // so even a fresh page load cannot pick it up.
        expect(storage.raw(STORAGE_KEY)).not.toContain(terminal)
        expect(resolveRefundKey(10, storage)).not.toBe(terminal)
    })

    it('does not resurrect a settled key when removal and the fallback both fail', () => {
        const storage = new UnreliableStorage()
        const terminal = resolveRefundKey(10, storage)

        // Nothing durable can be changed any more: the settled key is stuck in storage.
        storage.fail('remove')
        storage.fail('set')
        expect(() => clearRefundKey(10, storage)).not.toThrow()

        // Reading is still allowed, so the stale entry is visible -- and must be
        // ignored, because this runtime knows the attempt behind it is terminal.
        expect(storage.raw(STORAGE_KEY)).toContain(terminal)
        expect(peekRefundKey(10, storage)).toBeNull()

        const next = resolveRefundKey(10, storage)
        expect(next).not.toBe(terminal)
        // And the replacement is what every later read returns.
        expect(peekRefundKey(10, storage)).toBe(next)
        expect(resolveRefundKey(10, storage)).toBe(next)
    })

    it('leaves other orders alone when a clear cannot be written', () => {
        const storage = new UnreliableStorage()
        const ten = resolveRefundKey(10, storage)
        const eleven = resolveRefundKey(11, storage)

        storage.fail('remove')
        storage.fail('set')
        clearRefundKey(10, storage)

        expect(peekRefundKey(10, storage)).toBeNull()
        // Order 11's refund is still in flight and must keep its key.
        expect(peekRefundKey(11, storage)).toBe(eleven)
        expect(resolveRefundKey(11, storage)).toBe(eleven)
        expect(resolveRefundKey(10, storage)).not.toBe(ten)
    })

    it('still deletes the entry outright when removal works', () => {
        const storage = new UnreliableStorage()
        resolveRefundKey(10, storage)

        clearRefundKey(10, storage)

        // Unchanged behaviour: a working storage is emptied, not left holding '{}'.
        expect(storage.raw(STORAGE_KEY)).toBeNull()
        expect(peekRefundKey(10, storage)).toBeNull()
    })

    it('a fresh page reading a stranded entry treats it as a resumable key', () => {
        const storage = new UnreliableStorage()
        const terminal = resolveRefundKey(10, storage)
        storage.fail('remove')
        storage.fail('set')
        clearRefundKey(10, storage)

        // The guard is per runtime by design. After a reload the runtime has no memory
        // of the clear, so a stranded key is read back and resumed -- which is safe:
        // the server replays the settled attempt rather than refunding again, and the
        // reconcile endpoint is the way out. This documents the boundary rather than
        // claiming a guarantee the client cannot make.
        resetSessionRefundKeys()

        expect(peekRefundKey(10, storage)).toBe(terminal)
    })
})
