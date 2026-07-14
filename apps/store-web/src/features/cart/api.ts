import { api } from '@/lib/api'
import type { CartResponse } from '@/types/cart'

const BASE = '/api/user/cart'

export const CartAPI = {
    get: () => api.get<CartResponse>(BASE),
    addItem: (productId: number, quantity: number = 1) =>
        api.post<CartResponse>(`${BASE}/items`, { productId, quantity }),
    updateItem: (productId: number, quantity: number) =>
        api.patch<CartResponse>(`${BASE}/items/${productId}`, { quantity }),
    removeItem: (productId: number) =>
        api.delete<CartResponse>(`${BASE}/items/${productId}`),
    clear: () => api.delete<CartResponse>(BASE),
}

