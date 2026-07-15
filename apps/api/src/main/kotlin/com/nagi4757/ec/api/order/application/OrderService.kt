package com.nagi4757.ec.api.order.application

import com.nagi4757.ec.api.cart.application.CartService
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderItem
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.repository.OrderPage
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import org.springframework.web.server.ResponseStatusException

@Service
class OrderService(
    private val orderRepository: OrderRepository,
    private val cartService: CartService
) {
    /* 장바구니 → 주문 생성 + 장바구니 비우기 */
    @Transactional
    fun placeOrder(userId: Long): Order {
        val cart = cartService.getCart(userId)
        if (cart.items.isEmpty())
            throw ResponseStatusException(HttpStatus.BAD_REQUEST, "Cart is empty")

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
            ?: throw ResponseStatusException(HttpStatus.NOT_FOUND, "Order($orderId) not found")

    /* 어드민: 전체 주문 목록 */
    fun listAllOrders(page: Int, size: Int): OrderPage = orderRepository.findAll(page, size)

    /* 어드민: 주문 상세 */
    fun getOrderAdmin(orderId: Long): Order =
        orderRepository.findById(orderId)
            ?: throw ResponseStatusException(HttpStatus.NOT_FOUND, "Order($orderId) not found")

    /* 어드민: 주문 상태 변경 */
    @Transactional
    fun updateStatus(orderId: Long, status: OrderStatus): Order {
        orderRepository.findById(orderId)
            ?: throw ResponseStatusException(HttpStatus.NOT_FOUND, "Order($orderId) not found")
        orderRepository.updateStatus(orderId, status)
        return getOrderAdmin(orderId)
    }
}

