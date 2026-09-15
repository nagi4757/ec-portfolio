import { api } from '@/lib/api'
import type { Order, OrderSummary } from '@/types/order'

const BASE = '/api/user/orders'

// There is no place(): an order only exists once it has been paid for, which is
// what CheckoutAPI does.
export const OrderAPI = {
    list: () => api.get<OrderSummary[]>(BASE),
    get: (id: number) => api.get<Order>(`${BASE}/${id}`),
    cancel: (id: number) => api.post<Order>(`${BASE}/${id}/cancel`, {}),
}
