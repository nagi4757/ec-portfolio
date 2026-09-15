import type { Order, OrderStatus } from '@/types/order'

/**
 * Outcomes the refund endpoint returns in a response body.
 *
 * FAILED is absent on purpose: the server raises it as a 409 with code
 * REFUND_FAILED rather than returning it as a body, so it never reaches here.
 */
export type RefundOutcome = 'REFUNDED' | 'PENDING_CONFIRMATION'

export type RefundResponse = {
    outcome: RefundOutcome
    order: Order
}

/**
 * Orders that may be refunded and cancelled.
 *
 * Mirrors OrderStatus.isRefundable on the server. SHIPPED and DELIVERED are absent:
 * refunding those and restoring stock would claim the goods are back on the shelf
 * while a customer still holds them. Returning those needs a return workflow that
 * receives the goods first, which does not exist yet.
 */
export function isRefundable(status: OrderStatus): boolean {
    return status === 'PENDING' || status === 'PREPARING'
}

/** A legacy order was never paid for, so it is cancelled directly with no refund. */
export function isDirectlyCancellable(status: OrderStatus): boolean {
    return status === 'LEGACY_UNPAID'
}
