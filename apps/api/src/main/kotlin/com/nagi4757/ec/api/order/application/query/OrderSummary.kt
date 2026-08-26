package com.nagi4757.ec.api.order.application.query

import com.nagi4757.ec.api.order.domain.model.OrderStatus
import java.time.LocalDateTime

data class OrderSummary(
    val id: Long,
    val userId: Long,
    val status: OrderStatus,
    val totalAmount: Long,
    val createdAt: LocalDateTime?
)

data class OrderSummaryPage(
    val items: List<OrderSummary>,
    val page: Int,
    val size: Int,
    val total: Long,
    val totalPages: Int
)
