import { api } from '@/lib/api'
import type { Product, CreateProduct, UpdateProduct } from '@/types/product'

const BASE = '/api/admin/products'

export const ProductApi = {
    list: () => api.get<Product[]>(BASE),
    get: (id: number) => api.get<Product>(`${BASE}/${id}`),
    create: (data: CreateProduct) => api.post<Product>(BASE, data),
    update: (id: number, data: UpdateProduct) => api.patch<Product>(`${BASE}/${id}`, data),
    remove: (id: number) => api.delete<void>(`${BASE}/${id}`),
}
