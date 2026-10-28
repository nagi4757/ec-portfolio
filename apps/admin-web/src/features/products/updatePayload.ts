import type { Product, UpdateProduct } from '@/types/product'

export type ProductFormValues = {
    name: string
    price: number
    stockQuantity: number
    imageUrl: string
    description: string
}

/**
 * The PATCH body for an edit: only the fields the admin actually changed. Sending a
 * field back as it was loaded would overwrite whatever changed since the form opened,
 * be it another admin's edit or the stock that checkout and refunds move.
 *
 * A changed stock also carries the stock the form was loaded with, so the server can
 * refuse the change if the stock has moved since.
 */
export function buildUpdatePayload(initial: Product, values: ProductFormValues): UpdateProduct {
    const payload: UpdateProduct = {}
    if (values.name !== initial.name) payload.name = values.name
    if (values.price !== initial.price) payload.price = values.price
    // The form shows a missing image URL or description as an empty field, so leaving
    // it empty is not a change. Clearing a stored value still sends ''.
    if (values.imageUrl !== (initial.imageUrl ?? '')) payload.imageUrl = values.imageUrl
    if (values.description !== (initial.description ?? '')) payload.description = values.description
    if (values.stockQuantity !== initial.stockQuantity) {
        payload.stockQuantity = values.stockQuantity
        payload.expectedStockQuantity = initial.stockQuantity
    }
    return payload
}
