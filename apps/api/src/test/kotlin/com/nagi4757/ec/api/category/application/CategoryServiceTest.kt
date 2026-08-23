package com.nagi4757.ec.api.category.application

import com.nagi4757.ec.api.category.application.command.UpdateCategoryCommand
import com.nagi4757.ec.api.category.domain.repository.CategoryRepository
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApplicationException
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock

class CategoryServiceTest {
    private val categoryRepository = mock(CategoryRepository::class.java)
    private val categoryService = CategoryService(categoryRepository)

    @Test
    fun `update throws category not found when category does not exist`() {
        val exception = assertThrows(ApplicationException::class.java) {
            categoryService.update(999L, UpdateCategoryCommand(name = "Updated"))
        }

        assertEquals(ApiErrorCode.CATEGORY_NOT_FOUND, exception.errorCode)
    }

    @Test
    fun `delete throws category not found when category does not exist`() {
        val exception = assertThrows(ApplicationException::class.java) {
            categoryService.delete(999L)
        }

        assertEquals(ApiErrorCode.CATEGORY_NOT_FOUND, exception.errorCode)
    }
}
