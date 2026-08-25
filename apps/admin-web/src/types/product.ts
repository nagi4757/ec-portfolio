export type Product = {
    id: number
    name: string
    price: number
    stockQuantity: number
    imageUrl?: string | null
    description?: string | null
}

export type CreateProduct = Omit<Product, 'id'>;
export type UpdateProduct = Partial<Omit<Product, 'id'>>;
