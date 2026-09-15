import type { Order, ShippingAddress } from '@/types/order'

/**
 * Demo payment methods.
 *
 * These are the exact identifiers the backend MockPaymentGateway recognises. Any
 * other value is treated as a failure by the gateway, so they are pinned here rather
 * than typed by hand at each call site.
 *
 * There is no real card entry because there is no real provider yet: collecting card
 * details would mean handling data we have no way to protect.
 */
export const DEMO_PAYMENT_METHODS = [
    'mock:success',
    'mock:declined',
    'mock:failed',
    'mock:timeout',
] as const

export type DemoPaymentMethodId = (typeof DEMO_PAYMENT_METHODS)[number]

export const DEMO_PAYMENT_METHOD_TRANSLATION_KEY: Record<DemoPaymentMethodId, string> = {
    'mock:success': 'store.checkout.demoPayment.success',
    'mock:declined': 'store.checkout.demoPayment.declined',
    'mock:failed': 'store.checkout.demoPayment.failed',
    'mock:timeout': 'store.checkout.demoPayment.timeout',
}

/**
 * The checkout request. There is deliberately no amount: the total is computed by
 * the server from the cart and the product snapshot, so the browser cannot decide
 * what it pays.
 */
export type CheckoutRequest = {
    shippingAddress: ShippingAddress
    paymentMethodId: string
}

export type CheckoutOutcome = 'PAID' | 'PENDING_CONFIRMATION'

export type CheckoutResponse = {
    outcome: CheckoutOutcome
    order: Order
}
