import { api } from '@/lib/api'
import type { RefundResponse } from '@/types/refund'

/**
 * Refunds an order in full and cancels it.
 *
 * A separate endpoint rather than a status transition: reopening CANCELLED in the
 * status transition table would recreate a way to cancel a paid order without
 * returning the money. There is no request body -- the amount and the charge being
 * reversed come from the order's settled payment on the server.
 */
export const RefundAdminApi = {
    refund: (orderId: number, idempotencyKey: string) =>
        api.post<RefundResponse>(
            `/api/admin/orders/${orderId}/refund`,
            undefined,
            { 'Idempotency-Key': idempotencyKey },
        ),

    /**
     * Resumes the refund this order already has, including one the customer started.
     *
     * Deliberately sends no Idempotency-Key. Admin storage is a different origin from
     * the storefront's, so an operator never holds the customer's key; the key the
     * provider sees is the one recorded on the stored attempt. A fresh key here would
     * be refused anyway, because the order's existing attempt is still unsettled.
     */
    reconcile: (orderId: number) =>
        api.post<RefundResponse>(`/api/admin/orders/${orderId}/refund/reconcile`, undefined),
}
