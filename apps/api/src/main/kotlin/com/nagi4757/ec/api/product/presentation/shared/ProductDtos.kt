package com.nagi4757.ec.api.product.presentation.shared

import com.nagi4757.ec.api.product.application.ProductSearchPage
import com.nagi4757.ec.api.product.domain.model.Product
import jakarta.validation.constraints.Min
import jakarta.validation.constraints.NotBlank

object ProductRequest {
    data class Create(
        @field:NotBlank val name: String,
        @field:Min(0) val price: Long,
        val imageUrl: String? = null,
        val description: String? = null
    )
    data class Update(
        val name: String? = null,
        @field:Min(0) val price: Long? = null,
        val imageUrl: String? = null,
        val description: String? = null
    )
}

data class ProductResponse(
    val id: Long,
    val name: String,
    val price: Long,
    val imageUrl: String?,
    val description: String?
)

fun Product.toResponse() = ProductResponse(
    id = requireNotNull(id),
    name = name,
    price = price,
    imageUrl = imageUrl,
    description = description
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
