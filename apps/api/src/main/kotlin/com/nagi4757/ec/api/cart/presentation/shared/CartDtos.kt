package com.nagi4757.ec.api.cart.presentation.shared

import com.nagi4757.ec.api.cart.application.CartLine
import com.nagi4757.ec.api.cart.application.CartView
import jakarta.validation.constraints.Min

object CartRequest {
    data class AddItem(
        @field:Min(1) val productId: Long,
        @field:Min(1) val quantity: Int = 1
    )

    data class UpdateItem(
        @field:Min(0) val quantity: Int
    )
}

data class CartItemResponse(
    val productId: Long,
    val name: String,
    val price: Long,
    val imageUrl: String?,
    val quantity: Int,
    val lineAmount: Long
)

data class CartResponse(
    val items: List<CartItemResponse>,
    val totalQuantity: Int,
    val totalAmount: Long
)

fun CartLine.toResponse() = CartItemResponse(
    productId = productId,
    name = name,
    price = price,
    imageUrl = imageUrl,
    quantity = quantity,
    lineAmount = lineAmount
)

fun CartView.toResponse() = CartResponse(
    items = items.map { it.toResponse() },
    totalQuantity = totalQuantity,
    totalAmount = totalAmount
)

