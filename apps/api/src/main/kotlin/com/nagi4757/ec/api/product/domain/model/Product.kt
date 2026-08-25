package com.nagi4757.ec.api.product.domain.model

data class Product(
    val id: Long? = null,
    val name: String,
    val price: Long,
    val stockQuantity: Int,
    val imageUrl: String?,
    val description: String?
) {
    init {
        require(stockQuantity >= 0) { "stockQuantity must be greater than or equal to 0" }
    }
}
