package com.nagi4757.ec.api.product.application

import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApplicationException
import com.nagi4757.ec.api.product.application.command.UpdateProductCommand
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock

class ProductServiceTest {
    private val productRepository = mock(ProductRepository::class.java)
    private val productService = ProductService(productRepository)

    @Test
    fun `update throws product not found when product does not exist`() {
        val exception = assertThrows(ApplicationException::class.java) {
            productService.update(999L, UpdateProductCommand(name = "Updated"))
        }

        assertEquals(ApiErrorCode.PRODUCT_NOT_FOUND, exception.errorCode)
    }

    @Test
    fun `delete throws product not found when product does not exist`() {
        val exception = assertThrows(ApplicationException::class.java) {
            productService.delete(999L)
        }

        assertEquals(ApiErrorCode.PRODUCT_NOT_FOUND, exception.errorCode)
    }
}
