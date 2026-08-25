export type OrderStatus = 'PENDING' | 'PREPARING' | 'SHIPPED' | 'DELIVERED' | 'CANCELLED'

export const ORDER_STATUS_TRANSLATION_KEY: Record<OrderStatus, string> = {
    PENDING: 'store.order.status.pending',
    PREPARING: 'store.order.status.preparing',
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

export type Order = {
    id: number
    status: OrderStatus
    items: OrderItem[]
    totalAmount: number
    createdAt: string | null
}

export type OrderSummary = {
    id: number
    userId: number
    status: OrderStatus
    totalAmount: number
    createdAt: string | null
}
