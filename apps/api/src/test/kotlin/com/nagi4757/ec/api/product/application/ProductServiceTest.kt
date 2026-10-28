package com.nagi4757.ec.api.product.application

import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApplicationException
import com.nagi4757.ec.api.product.application.command.CreateProductCommand
import com.nagi4757.ec.api.product.application.command.UpdateProductCommand
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import org.mockito.ArgumentMatchers.anyInt
import org.mockito.ArgumentMatchers.anyLong
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.verifyNoInteractions
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
        assertTrue(result.active)
    }

    @Test
    fun `update keeps existing stock quantity when omitted`() {
        val current = product(stockQuantity = 6).copy(id = 1L)
        `when`(productRepository.findById(1L)).thenReturn(current)

        productService.update(1L, UpdateProductCommand(name = "Updated"))

        verify(productRepository).update(current.copy(name = "Updated"))
        verify(productRepository, never()).compareAndSetStock(anyLong(), anyInt(), anyInt())
    }

    @Test
    fun `update replaces stock quantity when it still matches the expected value`() {
        val current = product(stockQuantity = 6).copy(id = 1L)
        val updated = current.copy(stockQuantity = 2)
        `when`(productRepository.findById(1L)).thenReturn(current, updated)
        `when`(productRepository.compareAndSetStock(1L, 6, 2)).thenReturn(true)

        val result = productService.update(
            1L,
            UpdateProductCommand(stockQuantity = 2, expectedStockQuantity = 6)
        )

        // The field write never carries the stock; only the compare-and-set does.
        verify(productRepository).update(current)
        verify(productRepository).compareAndSetStock(1L, 6, 2)
        assertEquals(2, result.stockQuantity)
    }

    @Test
    fun `update reports a conflict when the stock moved since it was loaded`() {
        // Checkout took two units after the admin loaded a stock of six.
        val current = product(stockQuantity = 4).copy(id = 1L)
        `when`(productRepository.findById(1L)).thenReturn(current)
        `when`(productRepository.compareAndSetStock(1L, 6, 2)).thenReturn(false)

        val exception = assertThrows(ApplicationException::class.java) {
            productService.update(
                1L,
                UpdateProductCommand(name = "Updated", stockQuantity = 2, expectedStockQuantity = 6)
            )
        }

        assertEquals(ApiErrorCode.PRODUCT_STOCK_CONFLICT, exception.errorCode)
    }

    @Test
    fun `update leaves the stock alone when it is sent unchanged`() {
        // The form still shows the six it loaded; checkout has since taken two.
        val current = product(stockQuantity = 4).copy(id = 1L)
        `when`(productRepository.findById(1L)).thenReturn(current)

        productService.update(
            1L,
            UpdateProductCommand(name = "Updated", stockQuantity = 6, expectedStockQuantity = 6)
        )

        verify(productRepository).update(current.copy(name = "Updated"))
        verify(productRepository, never()).compareAndSetStock(anyLong(), anyInt(), anyInt())
    }

    @Test
    fun `update rejects a stock quantity without the expected value`() {
        val exception = assertThrows(ApplicationException::class.java) {
            productService.update(1L, UpdateProductCommand(name = "Updated", stockQuantity = 2))
        }

        assertEquals(ApiErrorCode.VALIDATION_FAILED, exception.errorCode)
        verifyNoInteractions(productRepository)
    }

    @Test
    fun `update rejects an expected value without a stock quantity`() {
        val exception = assertThrows(ApplicationException::class.java) {
            productService.update(1L, UpdateProductCommand(name = "Updated", expectedStockQuantity = 6))
        }

        assertEquals(ApiErrorCode.VALIDATION_FAILED, exception.errorCode)
        verifyNoInteractions(productRepository)
    }

    @Test
    fun `update reactivates inactive product when active is provided`() {
        val current = product(stockQuantity = 6).copy(id = 1L, active = false)
        val updated = current.copy(active = true)
        `when`(productRepository.findById(1L)).thenReturn(current, updated)

        val result = productService.update(1L, UpdateProductCommand(active = true))

        verify(productRepository).update(updated)
        assertTrue(result.active)
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
    fun `deactivate marks active product inactive`() {
        val current = product(stockQuantity = 6).copy(id = 1L)
        `when`(productRepository.findById(1L)).thenReturn(current)

        productService.deactivate(1L)

        verify(productRepository).deactivate(1L)
    }

    @Test
    fun `deactivate is idempotent for inactive product`() {
        val current = product(stockQuantity = 6).copy(id = 1L, active = false)
        `when`(productRepository.findById(1L)).thenReturn(current)

        productService.deactivate(1L)

        verify(productRepository).findById(1L)
        verify(productRepository, never()).deactivate(1L)
    }

    @Test
    fun `deactivate throws product not found when product does not exist`() {
        val exception = assertThrows(ApplicationException::class.java) {
            productService.deactivate(999L)
        }

        assertEquals(ApiErrorCode.PRODUCT_NOT_FOUND, exception.errorCode)
    }

    @Test
    fun `admin lookup includes inactive product`() {
        val inactive = product(stockQuantity = 6).copy(id = 1L, active = false)
        `when`(productRepository.findById(1L)).thenReturn(inactive)

        val result = productService.get(1L)

        assertFalse(requireNotNull(result).active)
    }

    @Test
    fun `public lookup excludes inactive product`() {
        `when`(productRepository.findActiveById(1L)).thenReturn(null)

        val result = productService.getActive(1L)

        assertNull(result)
    }

    private fun product(stockQuantity: Int): Product = Product(
        name = "Product",
        price = 10_000L,
        stockQuantity = stockQuantity,
        imageUrl = null,
        description = null
    )
}
