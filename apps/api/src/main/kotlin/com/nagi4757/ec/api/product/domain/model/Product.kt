package com.nagi4757.ec.api.product.domain.model

data class Product (
    val id: Long? = null,
    val name: String,
    val price: Long,
    val imageUrl: String?,
    val description: String?
)