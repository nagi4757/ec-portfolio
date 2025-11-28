package com.nagi4757.ec.api.product.application.command

data class CreateProductCommand(
    val name: String,
    val price: Long,
    val imageUrl: String? = null,
    val description: String? = null
)