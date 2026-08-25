package com.nagi4757.ec.api.cart.application

import com.nagi4757.ec.api.cart.domain.repository.CartRepository
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.InsufficientStockException
import com.nagi4757.ec.api.common.error.InvalidCartQuantityException
import com.nagi4757.ec.api.common.error.ProductNotAvailableException
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.domain.model.Product
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

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
                lineAmount = product.price * item.quantity,
                available = product.active
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
        if (quantity <= 0) throw InvalidCartQuantityException()
        val product = getRequiredProduct(productId)
        ensureAvailable(product)
        val currentQuantity = cartRepository.findAll(userId)
            .firstOrNull { it.productId == productId }
            ?.quantity
            ?: 0
        ensureStockAvailable(product, currentQuantity.toLong() + quantity)
        cartRepository.increment(userId, productId, quantity)
        return getCart(userId)
    }

    @Transactional
    fun updateItem(userId: Long, productId: Long, quantity: Int): CartView {
        val product = getRequiredProduct(productId)
        if (quantity <= 0) {
            cartRepository.remove(userId, productId)
        } else {
            ensureAvailable(product)
            ensureStockAvailable(product, quantity.toLong())
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

    private fun getRequiredProduct(productId: Long): Product =
        productService.get(productId)
            ?: throw ResourceNotFoundException(ApiErrorCode.PRODUCT_NOT_FOUND)

    private fun ensureStockAvailable(product: Product, requestedQuantity: Long) {
        if (requestedQuantity > product.stockQuantity.toLong()) {
            throw InsufficientStockException()
        }
    }

    private fun ensureAvailable(product: Product) {
        if (!product.active) {
            throw ProductNotAvailableException()
        }
    }
}

data class CartLine(
    val productId: Long,
    val name: String,
    val price: Long,
    val imageUrl: String?,
    val quantity: Int,
    val lineAmount: Long,
    val available: Boolean
)

data class CartView(
    val items: List<CartLine>,
    val totalQuantity: Int,
    val totalAmount: Long
)
