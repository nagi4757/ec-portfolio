package com.nagi4757.ec.api.order.application

import com.nagi4757.ec.api.cart.application.CartService
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.EmptyCartException
import com.nagi4757.ec.api.common.error.InsufficientStockException
import com.nagi4757.ec.api.common.error.InvalidOrderTransitionException
import com.nagi4757.ec.api.common.error.ProductNotAvailableException
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderItem
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.repository.OrderPage
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Isolation
import org.springframework.transaction.annotation.Transactional

@Service
class OrderService(
    private val orderRepository: OrderRepository,
    private val cartService: CartService,
    private val productRepository: ProductRepository
) {
    /* 장바구니 → 주문 생성 + 장바구니 비우기 */
    @Transactional(isolation = Isolation.READ_COMMITTED)
    fun placeOrder(userId: Long): Order {
        val cart = cartService.getCart(userId)
        if (cart.items.isEmpty()) throw EmptyCartException()
        if (cart.items.any { !it.available }) throw ProductNotAvailableException()

        cart.items.forEach { line ->
            if (!productRepository.decreaseStockIfAvailable(line.productId, line.quantity)) {
                throwStockUpdateFailure(line.productId)
            }
        }

        val order = Order(
            id = null,
            userId = userId,
            status = OrderStatus.PENDING,
            totalAmount = cart.totalAmount,
            createdAt = null,
            items = cart.items.map { line ->
                OrderItem(
                    id = null,
                    orderId = 0L,
                    productId = line.productId,
                    name = line.name,
                    price = line.price,
                    quantity = line.quantity,
                    lineAmount = line.lineAmount
                )
            }
        )

        val saved = orderRepository.save(order)
        cartService.clear(userId)
        return saved
    }

    /* 내 주문 목록 */
    fun getOrders(userId: Long): List<Order> = orderRepository.findByUserId(userId)

    /* 내 주문 상세 */
    fun getOrder(userId: Long, orderId: Long): Order =
        orderRepository.findByIdAndUserId(orderId, userId)
            ?: throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)

    @Transactional
    fun cancelOrder(userId: Long, orderId: Long): Order {
        val order = orderRepository.findByIdAndUserId(orderId, userId)
            ?: throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)
        if (!order.status.isUserCancellable()) {
            throw InvalidOrderTransitionException()
        }
        if (!orderRepository.transitionStatusForUser(
                id = orderId,
                userId = userId,
                expectedStatus = order.status,
                targetStatus = OrderStatus.CANCELLED
            )) {
            throw InvalidOrderTransitionException()
        }
        restoreStock(order)
        return getOrder(userId, orderId)
    }

    /* 어드민: 전체 주문 목록 */
    fun listAllOrders(page: Int, size: Int): OrderPage = orderRepository.findAll(page, size)

    /* 어드민: 주문 상세 */
    fun getOrderAdmin(orderId: Long): Order =
        orderRepository.findById(orderId)
            ?: throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)

    /* 어드민: 주문 상태 변경 */
    @Transactional
    fun updateStatus(orderId: Long, targetStatus: OrderStatus): Order {
        val order = orderRepository.findById(orderId)
            ?: throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)
        if (!order.status.canTransitionTo(targetStatus)) {
            throw InvalidOrderTransitionException()
        }
        if (!orderRepository.transitionStatus(orderId, order.status, targetStatus)) {
            throw InvalidOrderTransitionException()
        }
        if (targetStatus == OrderStatus.CANCELLED) {
            restoreStock(order)
        }
        return getOrderAdmin(orderId)
    }

    private fun restoreStock(order: Order) {
        order.items.forEach { item ->
            check(productRepository.increaseStock(item.productId, item.quantity)) {
                "Failed to restore stock for product ${item.productId}"
            }
        }
    }

    private fun throwStockUpdateFailure(productId: Long): Nothing {
        val product = productRepository.findById(productId)
            ?: throw ResourceNotFoundException(ApiErrorCode.PRODUCT_NOT_FOUND)
        if (!product.active) {
            throw ProductNotAvailableException()
        }
        throw InsufficientStockException()
    }
}
