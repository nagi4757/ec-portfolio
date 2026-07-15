import { api } from '@/lib/api'
import type { Order, OrderListResponse } from '@/types/order'

const BASE = '/api/admin/orders'

export const OrderAdminApi = {
    list: (page = 1, size = 20) =>
        api.get<OrderListResponse>(`${BASE}?page=${page}&size=${size}`),
    get: (id: number) => api.get<Order>(`${BASE}/${id}`),
    updateStatus: (id: number, status: string) =>
        api.patch<Order>(`${BASE}/${id}/status`, { status }),
}

