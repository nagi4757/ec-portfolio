package com.nagi4757.ec.api.order.presentation.shared

import com.nagi4757.ec.api.order.application.query.OrderSummary
import com.nagi4757.ec.api.order.application.query.OrderSummaryPage
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderItem
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import io.swagger.v3.oas.annotations.media.Schema
import jakarta.validation.constraints.NotBlank
import java.time.format.DateTimeFormatter

private val DT_FORMAT = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")

/* ── Request ── */
object OrderRequest {
    data class UpdateStatus(
        @field:NotBlank
        @field:Schema(implementation = OrderStatus::class)
        val status: String
    )
}

/* ── Response ── */
data class OrderItemResponse(
    val productId: Long,
    val name: String,
    val price: Long,
    val quantity: Int,
    val lineAmount: Long
)

data class OrderResponse(
    val id: Long,
    @field:Schema(implementation = OrderStatus::class)
    val status: String,
    val items: List<OrderItemResponse>,
    val totalAmount: Long,
    @field:Schema(
        description = "Order creation time formatted as yyyy-MM-dd HH:mm:ss.",
        pattern = "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$"
    )
    val createdAt: String?
)

data class OrderSummaryResponse(
    val id: Long,
    val userId: Long,
    @field:Schema(implementation = OrderStatus::class)
    val status: String,
    val totalAmount: Long,
    @field:Schema(
        description = "Order creation time formatted as yyyy-MM-dd HH:mm:ss.",
        pattern = "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$"
    )
    val createdAt: String?
)

data class OrderListResponse(
    val items: List<OrderSummaryResponse>,
    val page: Int,
    val size: Int,
    val total: Long,
    val totalPages: Int
)

/* ── Mappers ── */
fun OrderItem.toResponse() = OrderItemResponse(
    productId = productId,
    name = name,
    price = price,
    quantity = quantity,
    lineAmount = lineAmount
)

fun Order.toResponse() = OrderResponse(
    id = id!!,
    status = status.name,
    items = items.map { it.toResponse() },
    totalAmount = totalAmount,
    createdAt = createdAt?.format(DT_FORMAT)
)

fun OrderSummary.toResponse() = OrderSummaryResponse(
    id = id,
    userId = userId,
    status = status.name,
    totalAmount = totalAmount,
    createdAt = createdAt?.format(DT_FORMAT)
)

fun OrderSummaryPage.toResponse() = OrderListResponse(
    items = items.map { it.toResponse() },
    page = page,
    size = size,
    total = total,
    totalPages = totalPages
)
