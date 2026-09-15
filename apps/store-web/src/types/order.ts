// PAYMENT_PENDING means the payment outcome is not yet known. PENDING now means
// the order is paid and waiting for the seller to handle it.
export type OrderStatus =
    // Predates checkout: created without a payment, never shippable.
    | 'LEGACY_UNPAID'
    | 'PAYMENT_PENDING'
    | 'PENDING'
    | 'PREPARING'
    // A refund is in flight and its outcome is not yet known.
    | 'REFUND_PENDING'
    | 'SHIPPED'
    | 'DELIVERED'
    | 'CANCELLED'

export const ORDER_STATUS_TRANSLATION_KEY: Record<OrderStatus, string> = {
    LEGACY_UNPAID: 'store.order.status.legacyUnpaid',
    PAYMENT_PENDING: 'store.order.status.paymentPending',
    PENDING: 'store.order.status.pending',
    PREPARING: 'store.order.status.preparing',
    REFUND_PENDING: 'store.order.status.refundPending',
    SHIPPED: 'store.order.status.shipped',
    DELIVERED: 'store.order.status.delivered',
    CANCELLED: 'store.order.status.cancelled',
}

export type OrderItem = {
    productId: number
    name: string
    price: number
    quantity: number
    lineAmount: number
}

export type ShippingAddress = {
    recipientName: string
    postalCode: string
    prefecture: string
    city: string
    addressLine1: string
    addressLine2: string | null
    phoneNumber: string
}

export type Order = {
    id: number
    status: OrderStatus
    items: OrderItem[]
    totalAmount: number
    shippingAddress: ShippingAddress | null
    createdAt: string | null
}

export type OrderSummary = {
    id: number
    userId: number
    status: OrderStatus
    totalAmount: number
    createdAt: string | null
}
