export type OrderStatus = 'PENDING' | 'PREPARING' | 'SHIPPED' | 'DELIVERED' | 'CANCELLED'

export const ORDER_STATUS_TRANSLATION_KEY: Record<OrderStatus, string> = {
    PENDING: 'admin.order.status.pending',
    PREPARING: 'admin.order.status.preparing',
    SHIPPED: 'admin.order.status.shipped',
    DELIVERED: 'admin.order.status.delivered',
    CANCELLED: 'admin.order.status.cancelled',
}

export const ORDER_STATUS_TRANSITIONS: Record<OrderStatus, readonly OrderStatus[]> = {
    PENDING: ['PREPARING', 'CANCELLED'],
    PREPARING: ['SHIPPED', 'CANCELLED'],
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
    createdAt: string | null
}

export type OrderListResponse = {
    items: OrderSummary[]
    page: number
    size: number
    total: number
    totalPages: number
}
