package com.nagi4757.ec.api.product.domain.repository

import com.nagi4757.ec.api.product.domain.model.Product

interface ProductRepository {
    fun findById(id: Long): Product?
    fun findByIds(ids: Collection<Long>): List<Product>
    fun findActiveById(id: Long): Product?
    fun findAll(): List<Product>
    fun search(condition: ProductSearchCondition): ProductSearchResult
    fun create(product: Product): Long

    /**
     * Writes only the fields [changes] carries and leaves the rest of the row as it is.
     * False when there is no such product, or when [changes] is empty and nothing was
     * written.
     */
    fun updateFields(id: Long, changes: ProductFieldChanges): Boolean

    /**
     * Sets the stock to [quantity] only while it still equals [expectedQuantity].
     * False means something else changed the stock first, and nothing was written.
     */
    fun compareAndSetStock(productId: Long, expectedQuantity: Int, quantity: Int): Boolean

    fun decreaseStockIfAvailable(productId: Long, quantity: Int): Boolean
    fun increaseStock(productId: Long, quantity: Int): Boolean
    fun deactivate(id: Long): Boolean
}

/**
 * The fields an edit sets. A null field is left as stored, so an edit never writes back
 * a value it only read. The stock is not here: it changes through compare-and-set.
 */
data class ProductFieldChanges(
    val name: String? = null,
    val price: Long? = null,
    val imageUrl: String? = null,
    val description: String? = null,
    val active: Boolean? = null
) {
    val isEmpty: Boolean
        get() = name == null && price == null && imageUrl == null && description == null && active == null
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
