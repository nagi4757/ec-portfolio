package com.nagi4757.ec.api.integration

import com.nagi4757.ec.api.cart.domain.model.CartItem
import com.nagi4757.ec.api.cart.domain.repository.CartRepository
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderItem
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import com.nagi4757.ec.api.product.domain.repository.ProductSearchCondition
import org.assertj.core.api.Assertions.assertThat
import org.flywaydb.core.Flyway
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.testcontainers.service.connection.ServiceConnection
import org.springframework.test.context.ActiveProfiles
import org.springframework.transaction.annotation.Transactional
import org.testcontainers.containers.GenericContainer
import org.testcontainers.containers.MariaDBContainer
import org.testcontainers.junit.jupiter.Container
import org.testcontainers.junit.jupiter.Testcontainers
import java.util.UUID
import java.util.concurrent.ThreadLocalRandom

@Tag("integration")
@Testcontainers
@SpringBootTest
@ActiveProfiles("integration-test")
class InfrastructureIntegrationTest @Autowired constructor(
    private val flyway: Flyway,
    private val productRepository: ProductRepository,
    private val orderRepository: OrderRepository,
    private val cartRepository: CartRepository
) {

    @Test
    fun `applies Flyway migrations V1 through V4`() {
        val appliedVersions = flyway.info().applied()
            .mapNotNull { it.version?.version }

        assertThat(appliedVersions).containsExactly("1", "2", "3", "4")
    }

    @Test
    @Transactional
    fun `searches products by keyword price sort and pagination`() {
        val keyword = "integration-${UUID.randomUUID()}"
        val products = listOf(
            Product(name = "$keyword-low", price = 10_100L, imageUrl = null, description = keyword),
            Product(name = "$keyword-middle", price = 20_200L, imageUrl = null, description = keyword),
            Product(name = "$keyword-high", price = 30_300L, imageUrl = null, description = keyword)
        )
        products.forEach(productRepository::create)

        val result = productRepository.search(
            ProductSearchCondition(
                keyword = keyword,
                minPrice = 10_000L,
                maxPrice = 31_000L,
                sort = "priceDesc",
                page = 1,
                size = 2
            )
        )

        assertThat(result.page).isEqualTo(1)
        assertThat(result.size).isEqualTo(2)
        assertThat(result.total).isEqualTo(3L)
        assertThat(result.totalPages).isEqualTo(2)
        assertThat(result.items.map(Product::price)).containsExactly(30_300L, 20_200L)
        assertThat(result.items.map(Product::name)).containsExactly("$keyword-high", "$keyword-middle")
    }

    @Test
    @Transactional
    fun `saves an order and reloads generated identifiers`() {
        val order = Order(
            id = null,
            userId = 9_001L,
            status = OrderStatus.PENDING,
            items = listOf(
                OrderItem(
                    id = null,
                    orderId = 0L,
                    productId = 8_001L,
                    name = "Integration Test Product",
                    price = 12_500L,
                    quantity = 2,
                    lineAmount = 25_000L
                )
            ),
            totalAmount = 25_000L,
            createdAt = null
        )

        val saved = orderRepository.save(order)
        val orderId = requireNotNull(saved.id)
        val reloaded = requireNotNull(orderRepository.findById(orderId))
        val reloadedItem = reloaded.items.single()

        assertThat(orderId).isPositive()
        assertThat(reloaded.userId).isEqualTo(order.userId)
        assertThat(reloaded.status).isEqualTo(OrderStatus.PENDING)
        assertThat(reloaded.totalAmount).isEqualTo(order.totalAmount)
        assertThat(reloaded.createdAt).isNotNull()
        assertThat(reloadedItem.id).isNotNull()
        assertThat(reloadedItem.orderId).isEqualTo(orderId)
        assertThat(reloadedItem.productId).isEqualTo(8_001L)
        assertThat(reloadedItem.name).isEqualTo("Integration Test Product")
        assertThat(reloadedItem.price).isEqualTo(12_500L)
        assertThat(reloadedItem.quantity).isEqualTo(2)
        assertThat(reloadedItem.lineAmount).isEqualTo(25_000L)
    }

    @Test
    fun `supports Redis cart lifecycle`() {
        val userId = ThreadLocalRandom.current().nextLong(1_000_000_000L, Long.MAX_VALUE)
        val firstProductId = 7_001L
        val secondProductId = 7_002L

        cartRepository.clear(userId)
        try {
            assertThat(cartRepository.findAll(userId)).isEmpty()

            assertThat(cartRepository.increment(userId, firstProductId, 2)).isEqualTo(2)
            assertThat(cartRepository.increment(userId, firstProductId, 3)).isEqualTo(5)
            assertThat(cartRepository.increment(userId, secondProductId, 1)).isEqualTo(1)

            cartRepository.setQuantity(userId, firstProductId, 7)
            assertThat(cartRepository.findAll(userId))
                .containsExactly(CartItem(firstProductId, 7), CartItem(secondProductId, 1))

            cartRepository.remove(userId, firstProductId)
            assertThat(cartRepository.findAll(userId))
                .containsExactly(CartItem(secondProductId, 1))

            cartRepository.clear(userId)
            assertThat(cartRepository.findAll(userId)).isEmpty()
        } finally {
            cartRepository.clear(userId)
        }
    }

    companion object {
        @Container
        @ServiceConnection
        @JvmField
        val mariaDb = MariaDBContainer<Nothing>("mariadb:10.11")

        @Container
        @ServiceConnection(name = "redis")
        @JvmField
        val redis = GenericContainer<Nothing>("redis:7").apply {
            withExposedPorts(6379)
        }
    }
}
