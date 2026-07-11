package com.nagi4757.ec.api.category.presentation.admin

import com.nagi4757.ec.api.category.application.CategoryService
import com.nagi4757.ec.api.category.application.command.CreateCategoryCommand
import com.nagi4757.ec.api.category.application.command.UpdateCategoryCommand
import com.nagi4757.ec.api.category.presentation.shared.CategoryRequest
import com.nagi4757.ec.api.category.presentation.shared.CategoryResponse
import com.nagi4757.ec.api.category.presentation.shared.toResponse
import jakarta.validation.Valid
import org.springframework.web.bind.annotation.DeleteMapping
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PatchMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/admin/categories")
class CategoryAdminController(
    private val categoryService: CategoryService
) {
    @GetMapping
    fun list(): List<CategoryResponse> =
        categoryService.listAll().map { it.toResponse() }

    @GetMapping("/{id}")
    fun get(@PathVariable id: Long): CategoryResponse =
        categoryService.get(id)?.toResponse() ?: error("Category($id) not found")

    @PostMapping
    fun create(
        @Valid @RequestBody req: CategoryRequest.Create
    ): CategoryResponse {
        val saved = categoryService.create(
            CreateCategoryCommand(
                name = req.name,
                description = req.description
            )
        )
        return saved.toResponse()
    }

    @PatchMapping("/{id}")
    fun update(
        @PathVariable id: Long,
        @Valid @RequestBody req: CategoryRequest.Update
    ): CategoryResponse {
        val saved = categoryService.update(
            id,
            UpdateCategoryCommand(
                name = req.name,
                description = req.description
            )
        )
        return saved.toResponse()
    }

    @DeleteMapping("/{id}")
    fun delete(@PathVariable id: Long) {
        categoryService.delete(id)
    }
}

