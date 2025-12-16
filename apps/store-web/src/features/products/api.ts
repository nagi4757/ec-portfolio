import { api } from '@/lib/api';
import type { ProductResponse } from '@/types/product';

export const ProductAPI = {
    list: () => api.get<ProductResponse[]>('/api/public/products'),
    get: (id: number) => api.get<ProductResponse>(`/api/public/products/${id}`),
};
