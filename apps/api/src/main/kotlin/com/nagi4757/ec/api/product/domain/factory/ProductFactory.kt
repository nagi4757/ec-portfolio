package com.nagi4757.ec.api.product.domain.factory

import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.infra.mapper.ProductRecord
import org.springframework.stereotype.Component

@Component
class ProductFactory {

    fun fromRecord(src: ProductRecord): Product =
        Product(
            id = src.id,
            name = src.name ?: "",
            price = src.price ?: 0L,
            imageUrl = src.imageUrl,
            description = src.description
        )

    fun toRecord(src: Product): ProductRecord =
        ProductRecord().apply {
            id = src.id
            name = src.name
            price = src.price
            imageUrl = src.imageUrl
            description = src.description
        }

}
