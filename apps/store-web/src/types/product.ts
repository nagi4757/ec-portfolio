// apps/store-web/src/types/product.ts
export type ProductResponse = {
    id: number;
    name: string;
    price: number;
    imageUrl?: string | null;
    description?: string | null;
};
