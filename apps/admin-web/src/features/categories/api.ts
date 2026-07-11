import { api } from '@/lib/api'
import type { Category, CreateCategory, UpdateCategory } from '@/types/category'

const BASE = '/api/admin/categories'

export const CategoryApi = {
    list: () => api.get<Category[]>(BASE),
    get: (id: number) => api.get<Category>(`${BASE}/${id}`),
    create: (data: CreateCategory) => api.post<Category>(BASE, data),
    update: (id: number, data: UpdateCategory) => api.patch<Category>(`${BASE}/${id}`, data),
    remove: (id: number) => api.delete<void>(`${BASE}/${id}`),
}

