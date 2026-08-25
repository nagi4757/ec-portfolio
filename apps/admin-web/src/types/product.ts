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
export type UpdateProduct = Partial<Omit<Product, 'id'>>;
