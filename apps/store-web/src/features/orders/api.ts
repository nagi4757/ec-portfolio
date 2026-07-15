import { api } from '@/lib/api'
import type { Order, OrderSummary } from '@/types/order'

const BASE = '/api/user/orders'

export const OrderAPI = {
    place: () => api.post<Order>(BASE, {}),
    list: () => api.get<OrderSummary[]>(BASE),
    get: (id: number) => api.get<Order>(`${BASE}/${id}`),
}

