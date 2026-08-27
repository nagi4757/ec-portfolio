import { api } from '@/lib/api'
import type { CreateOrderRequest, Order, OrderSummary } from '@/types/order'

const BASE = '/api/user/orders'

export const OrderAPI = {
    place: (request: CreateOrderRequest) => api.post<Order>(BASE, request),
    list: () => api.get<OrderSummary[]>(BASE),
    get: (id: number) => api.get<Order>(`${BASE}/${id}`),
    cancel: (id: number) => api.post<Order>(`${BASE}/${id}/cancel`, {}),
}
