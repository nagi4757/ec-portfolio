package com.nagi4757.ec.api.product.domain.repository

import com.nagi4757.ec.api.product.domain.model.Product

interface ProductRepository {
    fun findById(id: Long): Product?
    fun findAll(): List<Product>
    fun search(condition: ProductSearchCondition): ProductSearchResult
    fun create(product: Product): Long
    fun update(product: Product): Boolean
    fun delete(id: Long): Boolean
}

data class ProductSearchCondition(
    val keyword: String?,
    val minPrice: Long?,
    val maxPrice: Long?,
    val sort: String,
    val page: Int,
    val size: Int
)

data class ProductSearchResult(
    val items: List<Product>,
    val page: Int,
    val size: Int,
    val total: Long,
    val totalPages: Int
)
