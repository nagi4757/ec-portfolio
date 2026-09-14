import { api } from '@/lib/api'
import type { CheckoutRequest, CheckoutResponse } from '@/types/checkout'

const BASE = '/api/user/checkout'

export const CheckoutAPI = {
    /**
     * Pays for the current cart and creates the order.
     *
     * The idempotency key is supplied by the caller rather than generated here: it
     * has to survive retries of the same attempt, which only the caller knows about.
     */
    submit: (request: CheckoutRequest, idempotencyKey: string) =>
        api.post<CheckoutResponse>(BASE, request, { 'Idempotency-Key': idempotencyKey }),
}
