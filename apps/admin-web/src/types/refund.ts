import type { Order, OrderStatus } from '@/types/order'

/**
 * Outcomes the refund endpoint returns in a response body.
 *
 * FAILED is absent on purpose: the server raises it as a 409 with code
 * REFUND_FAILED rather than returning it as a body.
 */
export type RefundOutcome = 'REFUNDED' | 'PENDING_CONFIRMATION'

export type RefundResponse = {
    outcome: RefundOutcome
    order: Order
}

/**
 * Orders an operator may refund and cancel.
 *
 * Mirrors OrderStatus.isRefundable on the server. SHIPPED and DELIVERED are absent:
 * refunding those and restoring stock would claim the goods are back on the shelf
 * while a customer still holds them. Returning those needs a return workflow that
 * receives the goods first, which does not exist yet.
 */
export function isRefundable(status: OrderStatus): boolean {
    return status === 'PENDING' || status === 'PREPARING'
}
