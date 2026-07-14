export type CartItem = {
    productId: number
    name: string
    price: number
    imageUrl?: string | null
    quantity: number
    lineAmount: number
}

export type CartResponse = {
    items: CartItem[]
    totalQuantity: number
    totalAmount: number
}

