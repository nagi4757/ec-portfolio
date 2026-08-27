package com.nagi4757.ec.api.product.presentation.shared

import com.nagi4757.ec.api.product.application.ProductSearchPage
import com.nagi4757.ec.api.product.domain.model.Product
import io.swagger.v3.oas.annotations.media.Schema
import jakarta.validation.constraints.Min
import jakarta.validation.constraints.NotBlank
import jakarta.validation.constraints.NotNull

object ProductRequest {
    @Schema(name = "CreateProductRequest")
    data class Create(
        @field:NotBlank val name: String,
        @field:Min(0) val price: Long,
        @field:NotNull @field:Min(0) val stockQuantity: Int?,
        val imageUrl: String? = null,
        val description: String? = null
    )
    data class Update(
        val name: String? = null,
        @field:Min(0) val price: Long? = null,
        @field:Min(0) val stockQuantity: Int? = null,
        val imageUrl: String? = null,
        val description: String? = null,
        val active: Boolean? = null
    )
}

data class ProductResponse(
    val id: Long,
    val name: String,
    val price: Long,
    val stockQuantity: Int,
    val imageUrl: String?,
    val description: String?,
    val active: Boolean
)

fun Product.toResponse() = ProductResponse(
    id = requireNotNull(id),
    name = name,
    price = price,
    stockQuantity = stockQuantity,
    imageUrl = imageUrl,
    description = description,
    active = active
)

data class ProductListResponse(
    val items: List<ProductResponse>,
    val page: Int,
    val size: Int,
    val total: Long,
    val totalPages: Int
)

fun ProductSearchPage.toResponse() = ProductListResponse(
    items = items.map { it.toResponse() },
    page = page,
    size = size,
    total = total,
    totalPages = totalPages
)
