import { ApiError } from '@/lib/api'
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

/**
 * The refusals of a product update that the API answers without having written anything:
 * before the update runs, or from inside its transaction, which then rolls back. Any other
 * failure, be it a dropped connection, a timeout, a 429 or a gateway error, may come after
 * the update was committed, with only the response lost.
 */
const UNWRITTEN_REFUSALS = new Map<string, number>([
    // Request validation, or a stock change sent without the stock it replaces.
    ['VALIDATION_FAILED', 400],
    // A body that could not be read.
    ['MALFORMED_REQUEST', 400],
    // Refused by the security filters before the request reaches the update.
    ['UNAUTHORIZED', 401],
    ['ACCESS_DENIED', 403],
    // Thrown by the update before it writes, or rolled back with what it wrote.
    ['PRODUCT_NOT_FOUND', 404],
    ['PRODUCT_STOCK_CONFLICT', 409],
])

/** Whether a failed save may still have been written. */
export function isSaveOutcomeUnknown(cause: unknown): boolean {
    return !(cause instanceof ApiError && cause.code !== null && UNWRITTEN_REFUSALS.get(cause.code) === cause.status)
}

/** The form's fields as the form fills them from a product. */
function formValuesOf(product: Product): ProductFormValues {
    return {
        name: product.name,
        price: product.price,
        stockQuantity: product.stockQuantity,
        imageUrl: product.imageUrl ?? '',
        description: product.description ?? '',
    }
}

/**
 * Whether a field that an unconfirmed save carried is no longer what the form was loaded
 * with, in which case that save may have been written. The form cannot tell such a field
 * set back to its loaded value from one never touched, and would leave the server's value
 * in place without a word.
 */
export function changedSinceLoad(initial: Product, unconfirmed: UpdateProduct, latest: Product): boolean {
    const moved = Object.keys(buildUpdatePayload(initial, formValuesOf(latest)))
    return Object.keys(unconfirmed).some(field => moved.includes(field))
}

export type EditApi = {
    /** Reads the product as the server has it now. */
    read: () => Promise<Product>
    update: (changes: UpdateProduct) => Promise<unknown>
}

/** What became of a save, and the save left unconfirmed for the next one to settle. */
export type EditSave =
    | { outcome: 'saved' | 'noChanges'; unconfirmed: null }
    | { outcome: 'changedSinceLoad' | 'checkFailed' | 'unknown'; unconfirmed: UpdateProduct }
    | { outcome: 'refused'; unconfirmed: null; cause: unknown }

/**
 * Saves the changes of an edit, worked out against the form as loaded.
 *
 * After a save whose outcome is unknown, that baseline may be stale: the save may have been
 * written and only its response lost. A field the admin then set back to its loaded value
 * would not go out, and the written value would stay. So until that save is settled, a save
 * first reads the product, and goes out only if none of the fields the unconfirmed save
 * carried has moved. The baseline is not replaced by what was read: the fields the admin did
 * not touch would become changes, and a stock change would no longer be checked against the
 * stock the admin saw.
 */
export async function saveEdit(
    initial: Product,
    changes: UpdateProduct,
    unconfirmed: UpdateProduct | null,
    api: EditApi,
): Promise<EditSave> {
    if (unconfirmed) {
        let latest: Product
        try {
            latest = await api.read()
        } catch {
            // Still unsettled, so nothing may go out.
            return { outcome: 'checkFailed', unconfirmed }
        }
        if (changedSinceLoad(initial, unconfirmed, latest)) return { outcome: 'changedSinceLoad', unconfirmed }
    }
    if (Object.keys(changes).length === 0) return { outcome: 'noChanges', unconfirmed: null }
    try {
        await api.update(changes)
    } catch (cause) {
        if (isSaveOutcomeUnknown(cause)) return { outcome: 'unknown', unconfirmed: changes }
        return { outcome: 'refused', unconfirmed: null, cause }
    }
    return { outcome: 'saved', unconfirmed: null }
}
