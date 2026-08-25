package com.nagi4757.ec.api.order.application

import com.nagi4757.ec.api.cart.application.CartLine
import com.nagi4757.ec.api.cart.application.CartService
import com.nagi4757.ec.api.cart.application.CartView
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApplicationException
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.repository.OrderPage
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import java.time.LocalDateTime

class OrderServiceTest {
    @Test
    fun `placeOrder creates pending order and clears cart`() {
        val orderRepository = FakeOrderRepository()
        val cartService = mock(CartService::class.java)
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, cartService, productRepository)

        val userId = 7L
        val cart = CartView(
            items = listOf(
                CartLine(
                    productId = 101,
                    name = "T-Shirt",
                    price = 19000,
                    imageUrl = null,
                    quantity = 2,
                    lineAmount = 38000
                )
            ),
            totalQuantity = 2,
            totalAmount = 38000
        )

        `when`(cartService.getCart(userId)).thenReturn(cart)
        `when`(productRepository.decreaseStockIfAvailable(101L, 2)).thenReturn(true)

        val result = orderService.placeOrder(userId)

        verify(productRepository).decreaseStockIfAvailable(101L, 2)
        verify(cartService).clear(userId)

        val saved = orderRepository.savedOrders.single()
        assertEquals(userId, saved.userId)
        assertEquals(OrderStatus.PENDING, saved.status)
        assertEquals(38000, saved.totalAmount)
        assertEquals(1, saved.items.size)
        assertEquals(101, saved.items.first().productId)
        assertEquals(1L, result.id)
    }

    @Test
    fun `placeOrder throws bad request when cart is empty`() {
        val orderRepository = FakeOrderRepository()
        val cartService = mock(CartService::class.java)
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, cartService, productRepository)

        val userId = 7L
        `when`(cartService.getCart(userId)).thenReturn(CartView(emptyList(), 0, 0))

        val ex = assertThrows(ApplicationException::class.java) {
            orderService.placeOrder(userId)
        }

        assertEquals(ApiErrorCode.EMPTY_CART, ex.errorCode)
        assertEquals(0, orderRepository.savedOrders.size)
    }

    @Test
    fun `placeOrder keeps cart and does not save order when stock is insufficient`() {
        val orderRepository = FakeOrderRepository()
        val cartService = mock(CartService::class.java)
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, cartService, productRepository)
        val userId = 7L
        val cart = CartView(
            items = listOf(
                CartLine(
                    productId = 101L,
                    name = "T-Shirt",
                    price = 19_000L,
                    imageUrl = null,
                    quantity = 2,
                    lineAmount = 38_000L
                )
            ),
            totalQuantity = 2,
            totalAmount = 38_000L
        )
        `when`(cartService.getCart(userId)).thenReturn(cart)
        `when`(productRepository.decreaseStockIfAvailable(101L, 2)).thenReturn(false)

        val exception = assertThrows(ApplicationException::class.java) {
            orderService.placeOrder(userId)
        }

        assertEquals(ApiErrorCode.INSUFFICIENT_STOCK, exception.errorCode)
        assertEquals(0, orderRepository.savedOrders.size)
        verify(cartService, never()).clear(userId)
    }

    @Test
    fun `getOrder throws not found for another user's order`() {
        val orderRepository = FakeOrderRepository()
        val cartService = mock(CartService::class.java)
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, cartService, productRepository)

        val ex = assertThrows(ApplicationException::class.java) {
            orderService.getOrder(7L, 1L)
        }

        assertEquals(ApiErrorCode.ORDER_NOT_FOUND, ex.errorCode)
    }

    @Test
    fun `getOrderAdmin throws order not found when order does not exist`() {
        val orderRepository = FakeOrderRepository()
        val cartService = mock(CartService::class.java)
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, cartService, productRepository)

        val ex = assertThrows(ApplicationException::class.java) {
            orderService.getOrderAdmin(999L)
        }

        assertEquals(ApiErrorCode.ORDER_NOT_FOUND, ex.errorCode)
    }

    @Test
    fun `updateStatus updates and returns refreshed order`() {
        val orderRepository = FakeOrderRepository()
        val cartService = mock(CartService::class.java)
        val productRepository = mock(ProductRepository::class.java)
        val orderService = OrderService(orderRepository, cartService, productRepository)

        val before = Order(
            id = 10L,
            userId = 7L,
            status = OrderStatus.PENDING,
            items = emptyList(),
            totalAmount = 0,
            createdAt = LocalDateTime.of(2026, 7, 15, 9, 10)
        )
        orderRepository.seed(before)

        val result = orderService.updateStatus(10L, OrderStatus.SHIPPED)

        assertEquals(OrderStatus.SHIPPED, result.status)
    }

    private class FakeOrderRepository : OrderRepository {
        val savedOrders: MutableList<Order> = mutableListOf()
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

        override fun updateStatus(id: Long, status: OrderStatus): Boolean {
            val current = ordersById[id] ?: return false
            ordersById[id] = current.copy(status = status)
            return true
        }
    }
}
