package com.nagi4757.ec.api.product.application.command

data class UpdateProductCommand(
    val name: String? = null,
    val price: Long? = null,
    val stockQuantity: Int? = null,
    /** The stock [stockQuantity] replaces. Required with it, and only with it. */
    val expectedStockQuantity: Int? = null,
    val imageUrl: String? = null,
    val description: String? = null,
    val active: Boolean? = null
)
