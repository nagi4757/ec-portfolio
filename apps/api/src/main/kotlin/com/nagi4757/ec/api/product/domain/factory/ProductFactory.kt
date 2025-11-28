package com.nagi4757.ec.api.product.domain.factory

import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.infra.mbg.model.Product as MbProduct
import org.springframework.stereotype.Component

@Component
class ProductFactory {

    fun fromMb(src: MbProduct): Product =
        Product(
            id = src.id,
            name = src.name ?: "",
            price = src.price ?: 0L,
            imageUrl = src.imageUrl,
            description = src.description
        )

    fun toMb(src: Product): MbProduct =
        MbProduct().apply {
            id = src.id
            name = src.name
            price = src.price
            imageUrl = src.imageUrl
            description = src.description
        }

}