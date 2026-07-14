// apps/store-web/src/types/product.ts
export type ProductResponse = {
    id: number;
    name: string;
    price: number;
    imageUrl?: string | null;
    description?: string | null;
};

export type ProductListResponse = {
    items: ProductResponse[];
    page: number;
    size: number;
    total: number;
    totalPages: number;
};

export type ProductSearchParams = {
    keyword?: string;
    minPrice?: number;
    maxPrice?: number;
    sort?: 'newest' | 'priceAsc' | 'priceDesc' | 'nameAsc';
    page?: number;
    size?: number;
};
