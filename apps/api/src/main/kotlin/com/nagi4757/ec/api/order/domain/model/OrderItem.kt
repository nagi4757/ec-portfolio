package com.nagi4757.ec.api.order.domain.model

data class OrderItem(
    val id: Long?,
    val orderId: Long,
    val productId: Long,
    val name: String,
    val price: Long,
    val quantity: Int,
    val lineAmount: Long
)

