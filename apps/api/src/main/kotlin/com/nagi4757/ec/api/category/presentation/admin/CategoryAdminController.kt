package com.nagi4757.ec.api.category.presentation.admin

import com.nagi4757.ec.api.category.application.CategoryService
import com.nagi4757.ec.api.category.application.command.CreateCategoryCommand
import com.nagi4757.ec.api.category.application.command.UpdateCategoryCommand
import com.nagi4757.ec.api.category.presentation.shared.CategoryRequest
import com.nagi4757.ec.api.category.presentation.shared.CategoryResponse
import com.nagi4757.ec.api.category.presentation.shared.toResponse
import com.nagi4757.ec.api.common.config.ApiErrorCodes
import com.nagi4757.ec.api.common.config.OpenApiConfig
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import jakarta.validation.Valid
import org.springframework.http.HttpStatus
import org.springframework.web.bind.annotation.DeleteMapping
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PatchMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.ResponseStatus
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/admin/categories")
@Tag(name = "Admin - Categories")
@SecurityRequirement(name = OpenApiConfig.BEARER_AUTH_NAME)
@ApiErrorCodes(ApiErrorCode.UNAUTHORIZED, ApiErrorCode.ACCESS_DENIED)
class CategoryAdminController(
    private val categoryService: CategoryService
) {
    @GetMapping
    @Operation(operationId = "listAdminCategories")
    fun list(): List<CategoryResponse> =
        categoryService.listAll().map { it.toResponse() }

    @GetMapping("/{id}")
    @Operation(operationId = "getAdminCategory")
    @ApiErrorCodes(ApiErrorCode.CATEGORY_NOT_FOUND)
    fun get(@PathVariable id: Long): CategoryResponse =
        categoryService.get(id)?.toResponse()
            ?: throw ResourceNotFoundException(ApiErrorCode.CATEGORY_NOT_FOUND)

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @Operation(operationId = "createCategory")
    @ApiErrorCodes(ApiErrorCode.VALIDATION_FAILED, ApiErrorCode.MALFORMED_REQUEST)
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
    @Operation(operationId = "updateCategory")
    @ApiErrorCodes(ApiErrorCode.MALFORMED_REQUEST, ApiErrorCode.CATEGORY_NOT_FOUND)
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
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @Operation(operationId = "deleteCategory")
    @ApiErrorCodes(ApiErrorCode.CATEGORY_NOT_FOUND)
    fun delete(@PathVariable id: Long) {
        categoryService.delete(id)
    }
}
