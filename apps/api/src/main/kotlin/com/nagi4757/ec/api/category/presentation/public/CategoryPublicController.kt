package com.nagi4757.ec.api.category.presentation.public

import com.nagi4757.ec.api.category.application.CategoryService
import com.nagi4757.ec.api.category.presentation.shared.CategoryResponse
import com.nagi4757.ec.api.category.presentation.shared.toResponse
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/public/categories")
class CategoryPublicController(
    private val categoryService: CategoryService
) {
    @GetMapping
    fun list(): List<CategoryResponse> =
        categoryService.listAll().map { it.toResponse() }

    @GetMapping("/{id}")
    fun get(@PathVariable id: Long): CategoryResponse =
        categoryService.get(id)?.toResponse()
            ?: throw ResourceNotFoundException(ApiErrorCode.CATEGORY_NOT_FOUND)
}
