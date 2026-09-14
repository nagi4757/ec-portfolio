import { api } from '@/lib/api'
import type { RefundResponse } from '@/types/refund'

/**
 * Refunds an order in full and cancels it.
 *
 * There is no request body: the amount and the charge being reversed are read from
 * the order's settled payment on the server, so a client cannot choose how much it
 * is refunded or which charge is reversed.
 */
export const RefundAPI = {
    refund: (orderId: number, idempotencyKey: string) =>
        api.post<RefundResponse>(
            `/api/user/orders/${orderId}/refund`,
            undefined,
            { 'Idempotency-Key': idempotencyKey },
        ),
}
