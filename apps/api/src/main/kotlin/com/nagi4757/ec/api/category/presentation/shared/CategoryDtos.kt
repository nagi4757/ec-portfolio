package com.nagi4757.ec.api.category.presentation.shared

import com.nagi4757.ec.api.category.domain.model.Category
import io.swagger.v3.oas.annotations.media.Schema
import jakarta.validation.constraints.NotBlank

object CategoryRequest {
    @Schema(name = "CreateCategoryRequest")
    data class Create(
        @field:NotBlank val name: String,
        val description: String? = null
    )

    data class Update(
        val name: String? = null,
        val description: String? = null
    )
}

data class CategoryResponse(
    val id: Long,
    val name: String,
    val description: String?
)

fun Category.toResponse() = CategoryResponse(
    id = requireNotNull(id),
    name = name,
    description = description
)
