package com.nagi4757.ec.api.product.application

import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApplicationException
import com.nagi4757.ec.api.product.application.command.CreateProductCommand
import com.nagi4757.ec.api.product.application.command.UpdateProductCommand
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`

class ProductServiceTest {
    private val productRepository = mock(ProductRepository::class.java)
    private val productService = ProductService(productRepository)

    @Test
    fun `create persists and returns stock quantity`() {
        val newProduct = Product(
            name = "New Product",
            price = 12_000L,
            stockQuantity = 9,
            imageUrl = null,
            description = null
        )
        val savedProduct = product(stockQuantity = 9).copy(id = 1L)
        `when`(productRepository.create(newProduct)).thenReturn(1L)
        `when`(productRepository.findById(1L)).thenReturn(savedProduct)

        val result = productService.create(
            CreateProductCommand(
                name = "New Product",
                price = 12_000L,
                stockQuantity = 9
            )
        )

        verify(productRepository).create(newProduct)
        assertEquals(9, result.stockQuantity)
    }

    @Test
    fun `update keeps existing stock quantity when omitted`() {
        val current = product(stockQuantity = 6).copy(id = 1L)
        `when`(productRepository.findById(1L)).thenReturn(current)

        productService.update(1L, UpdateProductCommand(name = "Updated"))

        verify(productRepository).update(current.copy(name = "Updated"))
    }

    @Test
    fun `update replaces stock quantity when provided`() {
        val current = product(stockQuantity = 6).copy(id = 1L)
        val updated = current.copy(stockQuantity = 2)
        `when`(productRepository.findById(1L)).thenReturn(current, updated)

        val result = productService.update(1L, UpdateProductCommand(stockQuantity = 2))

        verify(productRepository).update(updated)
        assertEquals(2, result.stockQuantity)
    }

    @Test
    fun `domain rejects negative stock quantity`() {
        assertThrows(IllegalArgumentException::class.java) {
            product(stockQuantity = -1)
        }
    }

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

    private fun product(stockQuantity: Int): Product = Product(
        name = "Product",
        price = 10_000L,
        stockQuantity = stockQuantity,
        imageUrl = null,
        description = null
    )
}
