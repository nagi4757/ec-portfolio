import type { Product, UpdateProduct } from '@/types/product'

export type ProductFormValues = {
    name: string
    price: number
    stockQuantity: number
    imageUrl: string
    description: string
}

/**
 * The PATCH body for an edit. The stock goes out only when the admin changed it, and
 * then with the stock the form was loaded with, so the server can refuse the change
 * if checkout or a refund has moved the stock since. Sending the loaded stock back on
 * every save is what used to undo their changes.
 */
export function buildUpdatePayload(initial: Product, values: ProductFormValues): UpdateProduct {
    const { stockQuantity, ...fields } = values
    if (stockQuantity === initial.stockQuantity) return fields
    return { ...fields, stockQuantity, expectedStockQuantity: initial.stockQuantity }
}
