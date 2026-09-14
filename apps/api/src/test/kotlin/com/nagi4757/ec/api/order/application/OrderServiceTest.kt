package com.nagi4757.ec.api.order.application

import com.nagi4757.ec.api.cart.application.CartLine
import com.nagi4757.ec.api.cart.application.CartService
import com.nagi4757.ec.api.cart.application.CartView
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApplicationException
import com.nagi4757.ec.api.order.application.query.OrderQueryRepository
import com.nagi4757.ec.api.order.application.query.OrderSummary
import com.nagi4757.ec.api.order.application.query.OrderSummaryPage
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderItem
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.model.ShippingAddress
import com.nagi4757.ec.api.order.domain.repository.OrderPage
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.EnumSource
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verifyNoInteractions
import java.time.LocalDateTime

class OrderServiceTest {
    @Test
    fun `getOrder throws not found for another user's order`() {
        val orderRepository = FakeOrderRepository()
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, mock(OrderQueryRepository::class.java), productRepository)

        val ex = assertThrows(ApplicationException::class.java) {
            orderService.getOrder(7L, 1L)
        }

        assertEquals(ApiErrorCode.ORDER_NOT_FOUND, ex.errorCode)
    }

    @Test
    fun `getOrderAdmin throws order not found when order does not exist`() {
        val orderRepository = FakeOrderRepository()
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, mock(OrderQueryRepository::class.java), productRepository)

        val ex = assertThrows(ApplicationException::class.java) {
            orderService.getOrderAdmin(999L)
        }

        assertEquals(ApiErrorCode.ORDER_NOT_FOUND, ex.errorCode)
    }

    @Test
    fun `cancelOrder returns not found for another user order`() {
        val orderRepository = FakeOrderRepository()
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, mock(OrderQueryRepository::class.java), productRepository)
        orderRepository.seed(order(status = OrderStatus.PENDING, userId = 8L))

        val exception = assertThrows(ApplicationException::class.java) {
            orderService.cancelOrder(7L, 10L)
        }

        assertEquals(ApiErrorCode.ORDER_NOT_FOUND, exception.errorCode)
    }

    @Test
    fun `updateStatus rejects an invalid admin transition`() {
        val orderRepository = FakeOrderRepository()
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, mock(OrderQueryRepository::class.java), productRepository)
        orderRepository.seed(order(status = OrderStatus.PENDING))

        val exception = assertThrows(ApplicationException::class.java) {
            orderService.updateStatus(10L, OrderStatus.SHIPPED)
        }

        assertEquals(ApiErrorCode.INVALID_ORDER_TRANSITION, exception.errorCode)
        assertEquals(OrderStatus.PENDING, orderRepository.findById(10L)?.status)
    }

    @Test
    fun `updateStatus updates and returns refreshed order`() {
        val orderRepository = FakeOrderRepository()
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, mock(OrderQueryRepository::class.java), productRepository)

        val before = Order(
            id = 10L,
            userId = 7L,
            status = OrderStatus.PENDING,
            items = emptyList(),
            totalAmount = 0,
            createdAt = LocalDateTime.of(2026, 7, 15, 9, 10)
        )
        orderRepository.seed(before)

        val result = orderService.updateStatus(10L, OrderStatus.PREPARING)

        assertEquals(OrderStatus.PREPARING, result.status)
    }

    @ParameterizedTest
    @EnumSource(value = OrderStatus::class, names = ["PENDING", "PREPARING", "SHIPPED", "DELIVERED"])
    fun `cancelOrder refuses a paid order because it would need a refund`(status: OrderStatus) {
        val orderRepository = FakeOrderRepository()
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, mock(OrderQueryRepository::class.java), productRepository)
        orderRepository.seed(order(status = status))

        val exception = assertThrows(ApplicationException::class.java) {
            orderService.cancelOrder(7L, 10L)
        }

        assertEquals(ApiErrorCode.ORDER_CANCELLATION_REQUIRES_REFUND, exception.errorCode)
        assertEquals(status, orderRepository.findById(10L)?.status)
    }

    @Test
    fun `cancelOrder refuses a reserved order because the payment is unresolved`() {
        val orderRepository = FakeOrderRepository()
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, mock(OrderQueryRepository::class.java), productRepository)
        orderRepository.seed(order(status = OrderStatus.PAYMENT_PENDING))

        val exception = assertThrows(ApplicationException::class.java) {
            orderService.cancelOrder(7L, 10L)
        }

        assertEquals(ApiErrorCode.INVALID_ORDER_TRANSITION, exception.errorCode)
        assertEquals(OrderStatus.PAYMENT_PENDING, orderRepository.findById(10L)?.status)
    }

    @ParameterizedTest
    @EnumSource(value = OrderStatus::class, names = ["PENDING", "PREPARING"])
    fun `updateStatus refuses to cancel a paid order`(status: OrderStatus) {
        val orderRepository = FakeOrderRepository()
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, mock(OrderQueryRepository::class.java), productRepository)
        orderRepository.seed(order(status = status))

        val exception = assertThrows(ApplicationException::class.java) {
            orderService.updateStatus(10L, OrderStatus.CANCELLED)
        }

        assertEquals(ApiErrorCode.INVALID_ORDER_TRANSITION, exception.errorCode)
        assertEquals(status, orderRepository.findById(10L)?.status)
    }

    @Test
    fun `getOrders uses the summary query repository`() {
        val orderRepository = mock(OrderRepository::class.java)
        val productRepository = mock(ProductRepository::class.java)
        val orderQueryRepository = mock(OrderQueryRepository::class.java)
        val orderService = OrderService(orderRepository, orderQueryRepository, productRepository)
        val summaries = listOf(summary(id = 2L), summary(id = 1L))
        `when`(orderQueryRepository.findSummariesByUserId(7L)).thenReturn(summaries)

        assertEquals(summaries, orderService.getOrders(7L))

        verify(orderQueryRepository).findSummariesByUserId(7L)
        verifyNoInteractions(orderRepository)
    }

    @Test
    fun `listAllOrders uses the paged summary query repository`() {
        val orderRepository = mock(OrderRepository::class.java)
        val productRepository = mock(ProductRepository::class.java)
        val orderQueryRepository = mock(OrderQueryRepository::class.java)
        val orderService = OrderService(orderRepository, orderQueryRepository, productRepository)
        val page = OrderSummaryPage(listOf(summary(id = 3L)), 1, 20, 1L, 1)
        `when`(orderQueryRepository.findSummaryPage(1, 20)).thenReturn(page)

        assertEquals(page, orderService.listAllOrders(1, 20))

        verify(orderQueryRepository).findSummaryPage(1, 20)
        verifyNoInteractions(orderRepository)
    }

    private fun summary(id: Long) = OrderSummary(
        id = id,
        userId = 7L,
        status = OrderStatus.PENDING,
        totalAmount = 10_000L,
        createdAt = LocalDateTime.of(2026, 8, 26, 10, 0)
    )

    private fun order(
        status: OrderStatus,
        userId: Long = 7L
    ): Order = Order(
        id = 10L,
        userId = userId,
        status = status,
        items = listOf(
            OrderItem(
                id = 1L,
                orderId = 10L,
                productId = 101L,
                name = "First Product",
                price = 10_000L,
                quantity = 2,
                lineAmount = 20_000L
            ),
            OrderItem(
                id = 2L,
                orderId = 10L,
                productId = 102L,
                name = "Second Product",
                price = 20_000L,
                quantity = 3,
                lineAmount = 60_000L
            )
        ),
        totalAmount = 80_000L,
        createdAt = LocalDateTime.of(2026, 8, 25, 10, 0)
    )

    private fun cart(available: Boolean): CartView = CartView(
        items = listOf(
            CartLine(
                productId = 101L,
                name = "T-Shirt",
                price = 19_000L,
                stockQuantity = 10,
                imageUrl = null,
                quantity = 2,
                lineAmount = 38_000L,
                available = available
            )
        ),
        totalQuantity = 2,
        totalAmount = 38_000L
    )

    private fun product(stockQuantity: Int, active: Boolean = true): Product = Product(
        id = 101L,
        name = "T-Shirt",
        price = 19_000L,
        stockQuantity = stockQuantity,
        imageUrl = null,
        description = null,
        active = active
    )

    private fun shippingAddress() = ShippingAddress(
        recipientName = "Test Recipient",
        postalCode = "100-0001",
        prefecture = "Tokyo",
        city = "Chiyoda-ku",
        addressLine1 = "Chiyoda 1-1",
        addressLine2 = "Test Building 101",
        phoneNumber = "03-1234-5678"
    )

    private class FakeOrderRepository : OrderRepository {
        val savedOrders: MutableList<Order> = mutableListOf()
        var rejectTransitions: Boolean = false
        private val ordersById: MutableMap<Long, Order> = mutableMapOf()
        private var nextId = 1L

        fun seed(order: Order) {
            val id = requireNotNull(order.id)
            ordersById[id] = order
            if (id >= nextId) nextId = id + 1
        }

        override fun save(order: Order): Order {
            val id = order.id ?: nextId++
            val saved = order.copy(id = id, createdAt = order.createdAt ?: LocalDateTime.now())
            savedOrders += saved
            ordersById[id] = saved
            return saved
        }

        override fun findById(id: Long): Order? = ordersById[id]

        override fun lockForUpdate(id: Long): Order? = ordersById[id]

        override fun findByIdAndUserId(id: Long, userId: Long): Order? =
            ordersById[id]?.takeIf { it.userId == userId }

        override fun findByUserId(userId: Long): List<Order> =
            ordersById.values.filter { it.userId == userId }.sortedByDescending { it.id }

        override fun findAll(page: Int, size: Int): OrderPage {
            val all = ordersById.values.sortedByDescending { it.id }
            val safePage = page.coerceAtLeast(1)
            val safeSize = size.coerceIn(1, 100)
            val offset = (safePage - 1) * safeSize
            val items = all.drop(offset).take(safeSize)
            val total = all.size.toLong()
            val totalPages = if (total == 0L) 0 else ((total + safeSize - 1) / safeSize).toInt()
            return OrderPage(items, safePage, safeSize, total, totalPages)
        }

        override fun transitionStatus(
            id: Long,
            expectedStatus: OrderStatus,
            targetStatus: OrderStatus
        ): Boolean {
            if (rejectTransitions) return false
            val current = ordersById[id] ?: return false
            if (current.status != expectedStatus) return false
            ordersById[id] = current.copy(status = targetStatus)
            return true
        }

        override fun transitionStatusForUser(
            id: Long,
            userId: Long,
            expectedStatus: OrderStatus,
            targetStatus: OrderStatus
        ): Boolean {
            if (rejectTransitions) return false
            val current = ordersById[id] ?: return false
            if (current.userId != userId || current.status != expectedStatus) return false
            ordersById[id] = current.copy(status = targetStatus)
            return true
        }
    }
}
