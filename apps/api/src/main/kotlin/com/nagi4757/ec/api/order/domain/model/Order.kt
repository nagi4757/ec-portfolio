package com.nagi4757.ec.api.order.domain.model

import java.time.LocalDateTime

data class Order(
    val id: Long?,
    val userId: Long,
    val status: OrderStatus,
    val items: List<OrderItem>,
    val totalAmount: Long,
    val createdAt: LocalDateTime?
)

