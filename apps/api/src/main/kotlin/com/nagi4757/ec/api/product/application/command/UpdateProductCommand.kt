package com.nagi4757.ec.api.product.application.command

data class UpdateProductCommand(
    val name: String? = null,
    val price: Long? = null,
    val imageUrl: String? = null,
    val description: String? = null
)