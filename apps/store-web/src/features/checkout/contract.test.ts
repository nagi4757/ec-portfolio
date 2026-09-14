import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { storeJa } from '@/i18n/locales/ja'
import { storeKo } from '@/i18n/locales/ko'
import { DEMO_PAYMENT_METHOD_TRANSLATION_KEY, DEMO_PAYMENT_METHODS } from '@/types/checkout'
import { ORDER_STATUS_TRANSLATION_KEY, type OrderStatus } from '@/types/order'

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

describe('checkout is the only order creation path', () => {
    it('no production source calls the removed order creation endpoint', () => {
        const orderApi = readSource('features/orders/api.ts')
        const checkoutPage = readSource('features/orders/pages/CheckoutPage.tsx')

        // POST /api/user/orders no longer exists: an order is created by paying.
        expect(orderApi).not.toContain('place:')
        expect(orderApi).not.toMatch(/api\.post<Order>\(BASE,/)
        expect(checkoutPage).not.toContain('OrderAPI.place')
        expect(checkoutPage).toContain('CheckoutAPI.submit')
    })

    it('the checkout page never sends a client-computed amount', () => {
        const checkoutPage = readSource('features/orders/pages/CheckoutPage.tsx')
        const submitCall = checkoutPage.slice(
            checkoutPage.indexOf('CheckoutAPI.submit('),
            checkoutPage.indexOf('idempotencyKey,'),
        )

        expect(submitCall).toContain('shippingAddress')
        expect(submitCall).toContain('paymentMethodId')
        expect(submitCall).not.toMatch(/amount|total/i)
    })

    it('does not poll on an unresolved charge', () => {
        const checkoutPage = readSource('features/orders/pages/CheckoutPage.tsx')

        // An automatic retry loop would hammer the gateway on every timeout. Re-checking
        // is an explicit user action.
        expect(checkoutPage).not.toMatch(/setInterval|setTimeout\s*\(/)
    })

    it('clears the key only on terminal outcomes', () => {
        const checkoutPage = readSource('features/orders/pages/CheckoutPage.tsx')
        const pendingBranch = checkoutPage.slice(
            checkoutPage.indexOf("result.outcome === 'PENDING_CONFIRMATION'"),
            checkoutPage.indexOf('clearIdempotencyKey()'),
        )

        // The 202 branch must return before any clear happens.
        expect(pendingBranch).toContain('setPendingConfirmation(true)')
        expect(pendingBranch).not.toContain('clearIdempotencyKey')

        // A reused-key conflict must not silently mint a new key either.
        const conflictBranch = checkoutPage.slice(
            checkoutPage.indexOf("isApiErrorCode(cause, 'PAYMENT_IDEMPOTENCY_CONFLICT')"),
            checkoutPage.indexOf("isApiErrorCode(cause, 'PRODUCT_NOT_AVAILABLE')"),
        )
        expect(conflictBranch).toContain('idempotencyConflict')
        expect(conflictBranch).not.toContain('clearIdempotencyKey')
    })
})

describe('order status presentation', () => {
    it('maps every status, including the new reserved state', () => {
        const statuses: OrderStatus[] = [
            'LEGACY_UNPAID', 'PAYMENT_PENDING', 'PENDING',
            'PREPARING', 'SHIPPED', 'DELIVERED', 'CANCELLED',
        ]

        statuses.forEach((status) => {
            expect(ORDER_STATUS_TRANSLATION_KEY[status]).toBeTruthy()
        })
        expect(ORDER_STATUS_TRANSLATION_KEY.PAYMENT_PENDING).toBe('store.order.status.paymentPending')
    })

    it('shows the reserved state in words, not as the enum name', () => {
        const key = ORDER_STATUS_TRANSLATION_KEY.PAYMENT_PENDING

        expect(lookup(storeKo, key)).toBe('결제 확인 중')
        expect(lookup(storeJa, key)).toBe('決済確認中')
    })

    it('shows the legacy unpaid state in words', () => {
        const key = ORDER_STATUS_TRANSLATION_KEY.LEGACY_UNPAID

        expect(lookup(storeKo, key)).toBeTruthy()
        expect(lookup(storeJa, key)).toBeTruthy()
    })

    it('offers cancellation only for an unpaid legacy order', () => {
        const detailPage = readSource('features/orders/pages/OrderDetailPage.tsx')

        // PENDING now means paid, and cancelling a paid order needs a refund the
        // system cannot issue. The button must follow the server's rule.
        expect(detailPage).toContain("status === 'LEGACY_UNPAID'")
        expect(detailPage).not.toContain("order.status !== 'PENDING'")
        expect(detailPage).not.toContain("{order.status === 'PENDING' && (")
    })

    it('refreshes the cart badge from the server after a successful checkout', () => {
        const checkoutPage = readSource('features/orders/pages/CheckoutPage.tsx')
        const successBranch = checkoutPage.slice(
            checkoutPage.indexOf('clearIdempotencyKey()'),
            checkoutPage.indexOf('navigate(`/orders/'),
        )

        // Cleanup only removes the reserved lines, so anything added during the
        // payment survives and the badge must reflect that instead of being zeroed.
        expect(successBranch).toContain('CartAPI.get()')
        expect(successBranch).not.toContain('setTotalQuantity(0)')
    })

    it('translates every demo payment method in both locales', () => {
        DEMO_PAYMENT_METHODS.forEach((method) => {
            const key = DEMO_PAYMENT_METHOD_TRANSLATION_KEY[method]
            expect(lookup(storeKo, key), `ko ${key}`).toBeTruthy()
            expect(lookup(storeJa, key), `ja ${key}`).toBeTruthy()
        })
    })

    it('translates every checkout outcome message in both locales', () => {
        const keys = [
            'store.checkout.declined',
            'store.checkout.failed',
            'store.checkout.idempotencyConflict',
            'store.checkout.pendingConfirmation.title',
            'store.checkout.pendingConfirmation.description',
            'store.checkout.pendingConfirmation.retry',
            'store.checkout.demoPayment.title',
            'store.checkout.demoPayment.notice',
        ]

        keys.forEach((key) => {
            expect(lookup(storeKo, key), `ko ${key}`).toBeTruthy()
            expect(lookup(storeJa, key), `ja ${key}`).toBeTruthy()
        })
    })
})
