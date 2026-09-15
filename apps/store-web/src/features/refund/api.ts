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

    /**
     * Resumes the refund this order already has.
     *
     * Deliberately sends no Idempotency-Key. The key identifying the attempt lives on
     * the server; this is the path for a customer who no longer has their copy of it,
     * so sending one would defeat the point. A fresh key here would also be refused,
     * because the order's existing attempt is still unsettled.
     */
    reconcile: (orderId: number) =>
        api.post<RefundResponse>(`/api/user/orders/${orderId}/refund/reconcile`, undefined),
}
