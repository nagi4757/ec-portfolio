package com.nagi4757.ec.api.order.presentation.shared

import com.nagi4757.ec.api.order.application.query.OrderSummary
import com.nagi4757.ec.api.order.application.query.OrderSummaryPage
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderItem
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.model.ShippingAddress as DomainShippingAddress
import io.swagger.v3.oas.annotations.media.Schema
import jakarta.validation.Valid
import jakarta.validation.constraints.NotBlank
import jakarta.validation.constraints.Pattern
import jakarta.validation.constraints.Size
import java.time.format.DateTimeFormatter

private val DT_FORMAT = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")

/* ── Request ── */
object OrderRequest {
    @Schema(name = "CreateOrderRequest")
    data class Create(
        @field:Valid
        val shippingAddress: ShippingAddressRequest
    )

    data class UpdateStatus(
        @field:NotBlank
        @field:Schema(implementation = OrderStatus::class)
        val status: String
    )
}

data class ShippingAddressRequest(
    @field:NotBlank
    @field:Size(max = 100)
    val recipientName: String,
    @field:NotBlank
    @field:Pattern(regexp = "^\\d{3}-?\\d{4}$")
    val postalCode: String,
    @field:NotBlank
    @field:Size(max = 50)
    val prefecture: String,
    @field:NotBlank
    @field:Size(max = 100)
    val city: String,
    @field:NotBlank
    @field:Size(max = 200)
    val addressLine1: String,
    @field:Size(max = 200)
    val addressLine2: String? = null,
    @field:NotBlank
    @field:Size(min = 10, max = 20)
    @field:Pattern(regexp = "^(?=.*\\d)[0-9+() -]+$")
    val phoneNumber: String
)

/* ── Response ── */
data class OrderItemResponse(
    val productId: Long,
    val name: String,
    val price: Long,
    val quantity: Int,
    val lineAmount: Long
)

data class ShippingAddressResponse(
    val recipientName: String,
    val postalCode: String,
    val prefecture: String,
    val city: String,
    val addressLine1: String,
    val addressLine2: String?,
    val phoneNumber: String
)

data class OrderResponse(
    val id: Long,
    @field:Schema(implementation = OrderStatus::class)
    val status: String,
    val items: List<OrderItemResponse>,
    val totalAmount: Long,
    @field:Schema(
        types = ["object", "null"],
        description = "Shipping address snapshot. Null for orders created before V8."
    )
    val shippingAddress: ShippingAddressResponse?,
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

fun ShippingAddressRequest.toDomain() = DomainShippingAddress(
    recipientName = recipientName.trim(),
    postalCode = postalCode.trim(),
    prefecture = prefecture.trim(),
    city = city.trim(),
    addressLine1 = addressLine1.trim(),
    addressLine2 = addressLine2?.trim()?.takeIf { it.isNotEmpty() },
    phoneNumber = phoneNumber.trim()
)

fun DomainShippingAddress.toResponse() = ShippingAddressResponse(
    recipientName = recipientName,
    postalCode = postalCode,
    prefecture = prefecture,
    city = city,
    addressLine1 = addressLine1,
    addressLine2 = addressLine2,
    phoneNumber = phoneNumber
)

fun Order.toResponse() = OrderResponse(
    id = id!!,
    status = status.name,
    items = items.map { it.toResponse() },
    totalAmount = totalAmount,
    shippingAddress = shippingAddress?.toResponse(),
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
