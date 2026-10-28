package com.nagi4757.ec.api.product.domain.repository

import com.nagi4757.ec.api.product.domain.model.Product

interface ProductRepository {
    fun findById(id: Long): Product?
    fun findByIds(ids: Collection<Long>): List<Product>
    fun findActiveById(id: Long): Product?
    fun findAll(): List<Product>
    fun search(condition: ProductSearchCondition): ProductSearchResult
    fun create(product: Product): Long

    /** Writes every field except the stock, which only [compareAndSetStock] changes. */
    fun update(product: Product): Boolean

    /**
     * Sets the stock to [quantity] only while it still equals [expectedQuantity].
     * False means something else changed the stock first, and nothing was written.
     */
    fun compareAndSetStock(productId: Long, expectedQuantity: Int, quantity: Int): Boolean

    fun decreaseStockIfAvailable(productId: Long, quantity: Int): Boolean
    fun increaseStock(productId: Long, quantity: Int): Boolean
    fun deactivate(id: Long): Boolean
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
