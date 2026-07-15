package com.nagi4757.ec.api.order.presentation.shared

import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderItem
import com.nagi4757.ec.api.order.domain.repository.OrderPage
import jakarta.validation.constraints.NotBlank
import java.time.format.DateTimeFormatter

private val DT_FORMAT = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")

/* ── Request ── */
object OrderRequest {
    data class UpdateStatus(@field:NotBlank val status: String)
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
    val status: String,
    val items: List<OrderItemResponse>,
    val totalAmount: Long,
    val createdAt: String?
)

data class OrderSummaryResponse(
    val id: Long,
    val userId: Long,
    val status: String,
    val totalAmount: Long,
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

fun Order.toSummary() = OrderSummaryResponse(
    id = id!!,
    userId = userId,
    status = status.name,
    totalAmount = totalAmount,
    createdAt = createdAt?.format(DT_FORMAT)
)

fun OrderPage.toResponse() = OrderListResponse(
    items = items.map { it.toSummary() },
    page = page,
    size = size,
    total = total,
    totalPages = totalPages
)

