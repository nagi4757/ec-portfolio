// PAYMENT_PENDING is set while a payment outcome is unresolved. PENDING now means
// the order is paid and waiting to be handled.
export type OrderStatus =
    | 'PAYMENT_PENDING'
    | 'PENDING'
    | 'PREPARING'
    | 'SHIPPED'
    | 'DELIVERED'
    | 'CANCELLED'

export const ORDER_STATUS_TRANSLATION_KEY: Record<OrderStatus, string> = {
    PAYMENT_PENDING: 'admin.order.status.paymentPending',
    PENDING: 'admin.order.status.pending',
    PREPARING: 'admin.order.status.preparing',
    SHIPPED: 'admin.order.status.shipped',
    DELIVERED: 'admin.order.status.delivered',
    CANCELLED: 'admin.order.status.cancelled',
}

// Mirrors OrderStatus.canTransitionTo on the server.
//
// Cancellation is absent from the paid states: the money has been captured and
// refund orchestration does not exist yet, so the server refuses those transitions.
// PAYMENT_PENDING is absent because the payment outcome is unresolved, and preparing
// such an order could ship goods that were never paid for.
export const ORDER_STATUS_TRANSITIONS: Record<OrderStatus, readonly OrderStatus[]> = {
    PAYMENT_PENDING: [],
    PENDING: ['PREPARING'],
    PREPARING: ['SHIPPED'],
    SHIPPED: ['DELIVERED'],
    DELIVERED: [],
    CANCELLED: [],
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

export type OrderSummary = {
    id: number
    userId: number
    status: OrderStatus
    totalAmount: number
    createdAt: string | null
}

export type Order = {
    id: number
    status: OrderStatus
    items: OrderItem[]
    totalAmount: number
    shippingAddress: ShippingAddress | null
    createdAt: string | null
}

export type OrderListResponse = {
    items: OrderSummary[]
    page: number
    size: number
    total: number
    totalPages: number
}
