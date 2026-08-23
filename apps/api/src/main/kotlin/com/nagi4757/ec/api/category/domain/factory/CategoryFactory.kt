package com.nagi4757.ec.api.category.domain.factory

import com.nagi4757.ec.api.category.domain.model.Category
import com.nagi4757.ec.api.category.infra.mapper.CategoryRecord
import org.springframework.stereotype.Component

@Component
class CategoryFactory {

    fun fromRecord(src: CategoryRecord): Category =
        Category(
            id = src.id,
            name = src.name ?: "",
            description = src.description
        )

    fun toRecord(src: Category): CategoryRecord =
        CategoryRecord().apply {
            id = src.id
            name = src.name
            description = src.description
        }
}
