import { api } from '@/lib/api';
import type { ProductListResponse, ProductResponse, ProductSearchParams } from '@/types/product';

function toQueryString(params?: ProductSearchParams): string {
    if (!params) return '';
    const q = new URLSearchParams();

    if (params.keyword?.trim()) q.set('keyword', params.keyword.trim());
    if (params.minPrice !== undefined) q.set('minPrice', String(params.minPrice));
    if (params.maxPrice !== undefined) q.set('maxPrice', String(params.maxPrice));
    if (params.sort) q.set('sort', params.sort);
    if (params.page !== undefined) q.set('page', String(params.page));
    if (params.size !== undefined) q.set('size', String(params.size));

    const qs = q.toString();
    return qs ? `?${qs}` : '';
}

export const ProductAPI = {
    list: (params?: ProductSearchParams) =>
        api.get<ProductListResponse>(`/api/public/products${toQueryString(params)}`),
    get: (id: number) => api.get<ProductResponse>(`/api/public/products/${id}`),
};
