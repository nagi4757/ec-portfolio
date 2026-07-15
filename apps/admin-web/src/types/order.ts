export type OrderStatus = 'PENDING' | 'CONFIRMED' | 'SHIPPED' | 'DELIVERED' | 'CANCELLED'

export const ORDER_STATUS_LABEL: Record<OrderStatus, string> = {
    PENDING:   '결제 대기',
    CONFIRMED: '주문 확인',
    SHIPPED:   '배송 중',
    DELIVERED: '배송 완료',
    CANCELLED: '취소됨',
}

export const ORDER_STATUS_OPTIONS: OrderStatus[] = [
    'PENDING', 'CONFIRMED', 'SHIPPED', 'DELIVERED', 'CANCELLED'
]

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

