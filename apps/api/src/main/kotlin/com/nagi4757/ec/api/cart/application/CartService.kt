package com.nagi4757.ec.api.cart.application

import com.nagi4757.ec.api.cart.domain.repository.CartRepository
import com.nagi4757.ec.api.product.application.ProductService
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import org.springframework.web.server.ResponseStatusException

@Service
class CartService(
    private val cartRepository: CartRepository,
    private val productService: ProductService
) {
    @Transactional(readOnly = true)
    fun getCart(userId: Long): CartView {
        val items = cartRepository.findAll(userId).mapNotNull { item ->
            val product = productService.get(item.productId) ?: return@mapNotNull null
            CartLine(
                productId = item.productId,
                name = product.name,
                price = product.price,
                imageUrl = product.imageUrl,
                quantity = item.quantity,
                lineAmount = product.price * item.quantity
            )
        }

        return CartView(
            items = items,
            totalQuantity = items.sumOf { it.quantity },
            totalAmount = items.sumOf { it.lineAmount }
        )
    }

    @Transactional
    fun addItem(userId: Long, productId: Long, quantity: Int): CartView {
        if (quantity <= 0) throw ResponseStatusException(HttpStatus.BAD_REQUEST, "quantity must be positive")
        ensureProductExists(productId)
        cartRepository.increment(userId, productId, quantity)
        return getCart(userId)
    }

    @Transactional
    fun updateItem(userId: Long, productId: Long, quantity: Int): CartView {
        ensureProductExists(productId)
        if (quantity <= 0) {
            cartRepository.remove(userId, productId)
        } else {
            cartRepository.setQuantity(userId, productId, quantity)
        }
        return getCart(userId)
    }

    @Transactional
    fun removeItem(userId: Long, productId: Long): CartView {
        cartRepository.remove(userId, productId)
        return getCart(userId)
    }

    @Transactional
    fun clear(userId: Long): CartView {
        cartRepository.clear(userId)
        return CartView(emptyList(), 0, 0L)
    }

    private fun ensureProductExists(productId: Long) {
        if (productService.get(productId) == null) {
            throw ResponseStatusException(HttpStatus.NOT_FOUND, "Product($productId) not found")
        }
    }
}

data class CartLine(
    val productId: Long,
    val name: String,
    val price: Long,
    val imageUrl: String?,
    val quantity: Int,
    val lineAmount: Long
)

data class CartView(
    val items: List<CartLine>,
    val totalQuantity: Int,
    val totalAmount: Long
)

