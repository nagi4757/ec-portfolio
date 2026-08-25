package com.nagi4757.ec.api.cart.application

import com.nagi4757.ec.api.cart.domain.model.CartItem
import com.nagi4757.ec.api.cart.domain.repository.CartRepository
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApplicationException
import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.domain.model.Product
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.mockito.ArgumentMatchers.anyLong
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.verifyNoInteractions
import org.mockito.Mockito.`when`
import org.springframework.http.HttpStatus

class CartServiceTest {
    private val cartRepository = mock(CartRepository::class.java)
    private val productService = mock(ProductService::class.java)
    private val cartService = CartService(cartRepository, productService)

    @Test
    fun `addItem rejects out of stock product`() {
        val userId = 7L
        val productId = 101L
        `when`(productService.get(productId)).thenReturn(product(stockQuantity = 0))
        `when`(cartRepository.findAll(userId)).thenReturn(emptyList())

        val exception = assertThrows(ApplicationException::class.java) {
            cartService.addItem(userId, productId, 1)
        }

        assertEquals(ApiErrorCode.INSUFFICIENT_STOCK, exception.errorCode)
        assertEquals(HttpStatus.CONFLICT, exception.errorCode.status)
        verify(cartRepository, never()).increment(userId, productId, 1)
    }

    @Test
    fun `addItem rejects quantity above stock including existing cart quantity`() {
        val userId = 7L
        val productId = 101L
        `when`(productService.get(productId)).thenReturn(product(stockQuantity = 2))
        `when`(cartRepository.findAll(userId)).thenReturn(listOf(CartItem(productId, 2)))

        val exception = assertThrows(ApplicationException::class.java) {
            cartService.addItem(userId, productId, 1)
        }

        assertEquals(ApiErrorCode.INSUFFICIENT_STOCK, exception.errorCode)
        verify(cartRepository, never()).increment(userId, productId, 1)
    }

    @Test
    fun `addItem rejects inactive product without changing cart`() {
        val userId = 7L
        val productId = 101L
        `when`(productService.get(productId)).thenReturn(product(stockQuantity = 3, active = false))

        val exception = assertThrows(ApplicationException::class.java) {
            cartService.addItem(userId, productId, 1)
        }

        assertEquals(ApiErrorCode.PRODUCT_NOT_AVAILABLE, exception.errorCode)
        assertEquals(HttpStatus.CONFLICT, exception.errorCode.status)
        verify(cartRepository, never()).increment(userId, productId, 1)
    }

    @Test
    fun `updateItem rejects quantity above stock`() {
        val userId = 7L
        val productId = 101L
        `when`(productService.get(productId)).thenReturn(product(stockQuantity = 3))

        val exception = assertThrows(ApplicationException::class.java) {
            cartService.updateItem(userId, productId, 4)
        }

        assertEquals(ApiErrorCode.INSUFFICIENT_STOCK, exception.errorCode)
        verify(cartRepository, never()).setQuantity(userId, productId, 4)
    }

    @Test
    fun `updateItem rejects quantity change for inactive product`() {
        val userId = 7L
        val productId = 101L
        `when`(productService.get(productId)).thenReturn(product(stockQuantity = 3, active = false))

        val exception = assertThrows(ApplicationException::class.java) {
            cartService.updateItem(userId, productId, 2)
        }

        assertEquals(ApiErrorCode.PRODUCT_NOT_AVAILABLE, exception.errorCode)
        verify(cartRepository, never()).setQuantity(userId, productId, 2)
    }

    @Test
    fun `removeItem removes inactive product without checking availability`() {
        val userId = 7L
        val productId = 101L
        `when`(cartRepository.findAll(userId)).thenReturn(emptyList())

        val result = cartService.removeItem(userId, productId)

        verify(cartRepository).remove(userId, productId)
        verifyNoInteractions(productService)
        assertEquals(0, result.totalQuantity)
    }

    @Test
    fun `getCart retains inactive item and marks it unavailable`() {
        val userId = 7L
        val productId = 101L
        `when`(cartRepository.findAll(userId)).thenReturn(listOf(CartItem(productId, 2)))
        `when`(productService.getByIds(listOf(productId)))
            .thenReturn(listOf(product(stockQuantity = 3, active = false)))

        val result = cartService.getCart(userId)

        val item = result.items.single()
        assertEquals(productId, item.productId)
        assertEquals("Product", item.name)
        assertEquals(2, item.quantity)
        assertFalse(item.available)
    }

    @Test
    fun `getCart marks active item available`() {
        val userId = 7L
        val productId = 101L
        `when`(cartRepository.findAll(userId)).thenReturn(listOf(CartItem(productId, 1)))
        `when`(productService.getByIds(listOf(productId)))
            .thenReturn(listOf(product(stockQuantity = 3)))

        val result = cartService.getCart(userId)

        assertTrue(result.items.single().available)
    }

    @Test
    fun `addItem accepts quantity within stock`() {
        val userId = 7L
        val productId = 101L
        `when`(productService.get(productId)).thenReturn(product(stockQuantity = 3))
        `when`(cartRepository.findAll(userId)).thenReturn(
            emptyList(),
            listOf(CartItem(productId, 2))
        )
        `when`(cartRepository.increment(userId, productId, 2)).thenReturn(2)
        `when`(productService.getByIds(listOf(productId)))
            .thenReturn(listOf(product(stockQuantity = 3)))

        val result = cartService.addItem(userId, productId, 2)

        verify(cartRepository).increment(userId, productId, 2)
        assertEquals(2, result.totalQuantity)
        assertEquals(20_000L, result.totalAmount)
        assertTrue(result.items.single().available)
    }

    @Test
    fun `getCart loads five products in one batch and preserves cart order`() {
        val userId = 7L
        val cartItems = listOf(
            CartItem(30L, 4),
            CartItem(10L, 1),
            CartItem(999L, 7),
            CartItem(20L, 2),
            CartItem(40L, 3)
        )
        `when`(cartRepository.findAll(userId)).thenReturn(cartItems)
        `when`(productService.getByIds(cartItems.map { it.productId })).thenReturn(
            listOf(
                product(id = 40L, name = "Product 40", price = 4_000L, stockQuantity = 4, active = false),
                product(id = 20L, name = "Product 20", price = 2_000L, stockQuantity = 3),
                product(id = 10L, name = "Product 10", price = 1_000L, stockQuantity = 2, active = false),
                product(id = 30L, name = "Product 30", price = 3_000L, stockQuantity = 5)
            )
        )

        val result = cartService.getCart(userId)

        assertEquals(listOf(30L, 10L, 20L, 40L), result.items.map { it.productId })
        assertEquals(listOf(4, 1, 2, 3), result.items.map { it.quantity })
        assertEquals(listOf(5, 2, 3, 4), result.items.map { it.stockQuantity })
        assertEquals(listOf(true, false, true, false), result.items.map { it.available })
        assertEquals(listOf(12_000L, 1_000L, 4_000L, 12_000L), result.items.map { it.lineAmount })
        assertEquals(10, result.totalQuantity)
        assertEquals(29_000L, result.totalAmount)
        verify(productService).getByIds(cartItems.map { it.productId })
        verify(productService, never()).get(anyLong())
    }

    @Test
    fun `getCart skips product lookup for an empty cart`() {
        val userId = 7L
        `when`(cartRepository.findAll(userId)).thenReturn(emptyList())

        val result = cartService.getCart(userId)

        assertTrue(result.items.isEmpty())
        assertEquals(0, result.totalQuantity)
        assertEquals(0L, result.totalAmount)
        verifyNoInteractions(productService)
    }

    private fun product(
        stockQuantity: Int,
        active: Boolean = true,
        id: Long = 101L,
        name: String = "Product",
        price: Long = 10_000L
    ): Product = Product(
        id = id,
        name = name,
        price = price,
        stockQuantity = stockQuantity,
        imageUrl = null,
        description = null,
        active = active
    )
}
