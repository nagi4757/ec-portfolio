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
 *
 * ## Storage can fail, and none of it may throw
 *
 * sessionStorage is not simply absent or present. Reading throws SecurityError under
 * some privacy settings, writing throws QuotaExceededError when the quota is full,
 * and either can fail in a private window. Every call below is therefore guarded
 * individually -- checking once that `sessionStorage` exists proves nothing about
 * the next operation on it.
 *
 * Nothing here throws. An exception escaping this module would leave the refund
 * button stuck mid-flight, because the caller raises its in-flight flag before it
 * asks for a key.
 *
 * When the durable copy cannot be written the key still lives in memory for the rest
 * of the page session, so a retry in this tab remains the same attempt. Only survival
 * across a reload is lost, and that case is recoverable through the server's
 * reconcile endpoint, which needs no client key at all. The alternative -- minting a
 * fresh key on every retry -- is the one that risks refunding twice.
 *
 * Clearing has to survive the same failures, and in the opposite direction. A delete
 * that storage refuses would leave a settled key behind for the next request to pick
 * up, and the server would then replay an attempt that is already terminal -- no
 * double refund, but no way to start a new one either. So a clear is remembered in
 * memory as well as attempted durably, and a removal that fails falls back to writing
 * an empty map over the entry.
 */

const STORAGE_KEY = 'refund.idempotency.v1'

export interface RefundKeyStorage {
    getItem(key: string): string | null
    setItem(key: string, value: string): void
    removeItem(key: string): void
}

type StoredKeys = Record<string, string>

/**
 * This page session's keys, written even when the durable copy cannot be.
 * Deliberately module scope: it has to outlive the component that asked for a key so
 * that a retry after a failed request is still the same attempt.
 */
const sessionKeys: StoredKeys = {}

/**
 * Orders whose refund this runtime has already settled.
 *
 * Clearing a key has to survive a storage that will not delete. Removing the entry
 * can be refused just as writing it can, and a terminal key left behind in storage
 * would be read back on the next request -- so the server would keep replaying an
 * attempt that is already finished, and the customer could never open a new refund.
 * Remembering the clear is what makes it stick even when nothing durable can.
 */
const clearedKeys = new Set<string>()

/** What a cleared store looks like when it has to be written rather than deleted. */
const EMPTY_KEYS = '{}'

function defaultStorage(): RefundKeyStorage | null {
    try {
        return globalThis.sessionStorage ?? null
    } catch {
        // Storage can be blocked outright.
        return null
    }
}

/** Each of these swallows a failing storage call; none of them may throw. */
function safeGetItem(storage: RefundKeyStorage | null): string | null {
    if (!storage) return null
    try {
        return storage.getItem(STORAGE_KEY)
    } catch {
        return null
    }
}

function safeSetItem(storage: RefundKeyStorage | null, value: string): void {
    if (!storage) return
    try {
        storage.setItem(STORAGE_KEY, value)
    } catch {
        // Quota exhausted, or writes are blocked. The in-memory copy still stands.
    }
}

/** Reports whether the entry is gone, so the caller can fall back to overwriting it. */
function safeRemoveItem(storage: RefundKeyStorage | null): boolean {
    if (!storage) return false
    try {
        storage.removeItem(STORAGE_KEY)
        return true
    } catch {
        return false
    }
}

function parse(raw: string | null): StoredKeys {
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
    return {}
}

/**
 * The durable copy with this session's keys layered over it.
 *
 * Session keys win: within a tab they are always at least as fresh as whatever
 * reached storage, and after a reload the session map is empty so the durable copy
 * stands alone.
 */
function read(storage: RefundKeyStorage | null): StoredKeys {
    const raw = safeGetItem(storage)
    const stored = parse(raw)
    if (raw && Object.keys(stored).length === 0) {
        // Present but unusable. Drop it so it is not re-parsed on every call.
        safeRemoveItem(storage)
    }

    // Keys this runtime has already settled are dropped from the durable copy. If
    // the delete could not be written -- removeItem refused, and the fallback write
    // refused too -- the stale entry is still sitting in storage, and without this
    // the next request would resurrect a key whose attempt is already terminal. The
    // server would then replay that settled attempt forever and the customer could
    // never start a new refund.
    const durable = Object.entries(stored).filter(([id]) => !clearedKeys.has(id))

    return { ...Object.fromEntries(durable), ...sessionKeys }
}

function write(storage: RefundKeyStorage | null, keys: StoredKeys): void {
    if (Object.keys(keys).length === 0) {
        // Overwriting with an empty map is the fallback when the entry cannot be
        // removed: it is a write rather than a delete, so it survives environments
        // that refuse one but allow the other.
        if (!safeRemoveItem(storage)) {
            safeSetItem(storage, EMPTY_KEYS)
        }
        return
    }
    safeSetItem(storage, JSON.stringify(keys))
}

function newKey(): string {
    try {
        const uuid = globalThis.crypto?.randomUUID?.()
        if (uuid) return uuid
    } catch {
        // randomUUID is unavailable outside a secure context in some browsers.
    }
    return `refund-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`
}

/**
 * The key to send for this order.
 *
 * An existing key is reused, which is what makes a retry a retry: after a network
 * error, after an unconfirmed result, and across a reload in the same tab. Never
 * throws, whatever storage does.
 */
export function resolveRefundKey(
    orderId: number,
    storage: RefundKeyStorage | null = defaultStorage(),
): string {
    const keys = read(storage)
    const existing = keys[String(orderId)]
    if (existing) return existing

    const key = newKey()
    // This order has a live refund again, so it is no longer one of the settled ones.
    // The new key is the only one any read can now return: it is in the session map,
    // which wins over the durable copy.
    clearedKeys.delete(String(orderId))
    sessionKeys[String(orderId)] = key
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
    const id = String(orderId)

    // Recorded before anything that can fail. Durable cleanup is attempted below and
    // usually succeeds, but this is what guarantees the outcome the caller asked for:
    // once this returns, the terminal key is gone for this runtime whatever storage
    // does with it.
    clearedKeys.add(id)
    delete sessionKeys[id]

    // read() already excludes cleared ids, so this drops any entry for other orders
    // that was previously stranded as well as this one.
    const rest = Object.fromEntries(
        Object.entries(read(storage)).filter(([key]) => key !== id),
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

/** Test seam: drops this page session's in-memory state. Not used by the application. */
export function resetSessionRefundKeys(): void {
    Object.keys(sessionKeys).forEach((id) => delete sessionKeys[id])
    clearedKeys.clear()
}
