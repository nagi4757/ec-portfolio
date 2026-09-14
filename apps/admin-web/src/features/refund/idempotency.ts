/**
 * Idempotency keys for refunds, kept per order.
 *
 * A key identifies one refund attempt, not one button press. Issuing a fresh key
 * after a network error or an unconfirmed result would ask the server to return the
 * money a second time, so the key survives every retry of the same attempt and is
 * only dropped once the outcome is terminal.
 *
 * Keys are held per order id rather than as one global value: a customer can have
 * refunds in flight on several orders, and one order's retry must not reuse or clear
 * another's key.
 *
 * Refund keys are deliberately separate from the checkout key. They identify a
 * different operation against a different server-side attempt, and sharing storage
 * would let a checkout retry clear a refund key or the reverse.
 *
 * Only the order id and the key are stored. No address, no payment or provider
 * reference, no token.
 */

const STORAGE_KEY = 'refund.idempotency.v1'

export interface RefundKeyStorage {
    getItem(key: string): string | null
    setItem(key: string, value: string): void
    removeItem(key: string): void
}

type StoredKeys = Record<string, string>

function defaultStorage(): RefundKeyStorage | null {
    try {
        return globalThis.sessionStorage ?? null
    } catch {
        // Storage can be unavailable or blocked. The flow still works; a refresh
        // simply cannot resume the attempt.
        return null
    }
}

function read(storage: RefundKeyStorage | null): StoredKeys {
    if (!storage) return {}
    const raw = storage.getItem(STORAGE_KEY)
    if (!raw) return {}
    try {
        const parsed: unknown = JSON.parse(raw)
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
            const entries = Object.entries(parsed as Record<string, unknown>)
                .filter((entry): entry is [string, string] => typeof entry[1] === 'string')
            return Object.fromEntries(entries)
        }
    } catch {
        // Unreadable state is discarded rather than trusted.
    }
    storage.removeItem(STORAGE_KEY)
    return {}
}

function write(storage: RefundKeyStorage | null, keys: StoredKeys): void {
    if (!storage) return
    if (Object.keys(keys).length === 0) {
        storage.removeItem(STORAGE_KEY)
        return
    }
    storage.setItem(STORAGE_KEY, JSON.stringify(keys))
}

function newKey(): string {
    const uuid = globalThis.crypto?.randomUUID?.()
    if (uuid) return uuid
    return `refund-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`
}

/**
 * The key to send for this order.
 *
 * An existing key is reused, which is what makes a retry a retry: after a network
 * error, after an unconfirmed result, and across a reload in the same tab.
 */
export function resolveRefundKey(
    orderId: number,
    storage: RefundKeyStorage | null = defaultStorage(),
): string {
    const keys = read(storage)
    const existing = keys[String(orderId)]
    if (existing) return existing

    const key = newKey()
    write(storage, { ...keys, [String(orderId)]: key })
    return key
}

/**
 * Called once this order's refund outcome is terminal: refunded, or refused with a
 * known answer. An unconfirmed result must not clear the key, because the next
 * attempt has to reuse it.
 */
export function clearRefundKey(
    orderId: number,
    storage: RefundKeyStorage | null = defaultStorage(),
): void {
    const keys = read(storage)
    if (!(String(orderId) in keys)) return

    const rest = Object.fromEntries(
        Object.entries(keys).filter(([id]) => id !== String(orderId)),
    )
    write(storage, rest)
}

/** Exposed for tests and diagnostics; never rendered. */
export function peekRefundKey(
    orderId: number,
    storage: RefundKeyStorage | null = defaultStorage(),
): string | null {
    return read(storage)[String(orderId)] ?? null
}
