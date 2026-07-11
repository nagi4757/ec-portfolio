package com.nagi4757.ec.api.category.domain.factory

import com.nagi4757.ec.api.category.domain.model.Category
import com.nagi4757.ec.api.infra.mbg.model.Category as MbCategory
import org.springframework.stereotype.Component

@Component
class CategoryFactory {

    fun fromMb(src: MbCategory): Category =
        Category(
            id = src.id,
            name = src.name ?: "",
            description = src.description
        )

    fun toMb(src: Category): MbCategory =
        MbCategory().apply {
            id = src.id
            name = src.name
            description = src.description
        }
}

