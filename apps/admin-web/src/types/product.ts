export type Product = {
    id: number
    name: string
    price: number
    stockQuantity: number
    active: boolean
    imageUrl?: string | null
    description?: string | null
}

export type CreateProduct = Omit<Product, 'id' | 'active'>;
/**
 * stockQuantity and expectedStockQuantity travel together or not at all. The server
 * refuses the pair with PRODUCT_STOCK_CONFLICT once the stock is no longer the
 * expected one.
 */
export type UpdateProduct = Partial<Omit<Product, 'id'>> & { expectedStockQuantity?: number };
