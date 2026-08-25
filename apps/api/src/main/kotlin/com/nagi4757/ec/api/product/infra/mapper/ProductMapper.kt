package com.nagi4757.ec.api.product.infra.mapper

import org.apache.ibatis.annotations.Mapper
import org.apache.ibatis.annotations.Param

@Mapper
interface ProductMapper {
    fun selectById(id: Long): ProductRecord?
    fun selectActiveById(id: Long): ProductRecord?
    fun selectAll(): List<ProductRecord>
    fun countSearch(
        @Param("keyword") keyword: String?,
        @Param("minPrice") minPrice: Long?,
        @Param("maxPrice") maxPrice: Long?
    ): Long

    fun search(
        @Param("keyword") keyword: String?,
        @Param("minPrice") minPrice: Long?,
        @Param("maxPrice") maxPrice: Long?,
        @Param("sort") sort: String,
        @Param("offset") offset: Int,
        @Param("limit") limit: Int
    ): List<ProductRecord>

    fun insert(record: ProductRecord): Int
    fun update(record: ProductRecord): Int
    fun decreaseStockIfAvailable(
        @Param("productId") productId: Long,
        @Param("quantity") quantity: Int
    ): Int
    fun increaseStock(
        @Param("productId") productId: Long,
        @Param("quantity") quantity: Int
    ): Int
    fun deactivate(id: Long): Int
}

data class ProductRecord(
    var id: Long? = null,
    var name: String? = null,
    var price: Long? = null,
    var stockQuantity: Int? = null,
    var imageUrl: String? = null,
    var description: String? = null,
    var active: Boolean? = null
)
