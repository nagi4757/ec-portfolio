package com.nagi4757.ec.api.cart.presentation.shared

import com.nagi4757.ec.api.cart.application.CartLine
import com.nagi4757.ec.api.cart.application.CartView
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class CartDtosTest {
    @Test
    fun `maps current product stock quantity to cart response`() {
        val response = CartView(
            items = listOf(
                CartLine(
                    productId = 101L,
                    name = "Product",
                    price = 10_000L,
                    stockQuantity = 7,
                    imageUrl = null,
                    quantity = 2,
                    lineAmount = 20_000L,
                    available = true
                )
            ),
            totalQuantity = 2,
            totalAmount = 20_000L
        ).toResponse()

        assertEquals(7, response.items.single().stockQuantity)
    }
}
