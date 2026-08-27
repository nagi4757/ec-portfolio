package com.nagi4757.ec.api.integration

import com.nagi4757.ec.api.cart.application.CartService
import com.nagi4757.ec.api.cart.domain.model.CartItem
import com.nagi4757.ec.api.cart.domain.repository.CartRepository
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApplicationException
import com.nagi4757.ec.api.common.logging.CorrelationIdContext
import com.nagi4757.ec.api.order.application.OrderService
import com.nagi4757.ec.api.order.application.query.OrderQueryRepository
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderItem
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.model.ShippingAddress
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import com.nagi4757.ec.api.product.domain.repository.ProductSearchCondition
import org.assertj.core.api.Assertions.assertThat
import org.flywaydb.core.Flyway
import org.flywaydb.core.api.MigrationVersion
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.actuate.health.HealthContributorRegistry
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.testcontainers.service.connection.ServiceConnection
import org.springframework.dao.DataIntegrityViolationException
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.datasource.DriverManagerDataSource
import org.springframework.test.context.ActiveProfiles
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get
import org.springframework.transaction.annotation.Transactional
import org.testcontainers.containers.GenericContainer
import org.testcontainers.containers.MariaDBContainer
import org.testcontainers.junit.jupiter.Container
import org.testcontainers.junit.jupiter.Testcontainers
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ThreadLocalRandom
import java.util.concurrent.TimeUnit

@Tag("integration")
@Testcontainers
@SpringBootTest
@ActiveProfiles("integration-test")
@AutoConfigureMockMvc
class InfrastructureIntegrationTest @Autowired constructor(
    private val flyway: Flyway,
    private val jdbcTemplate: JdbcTemplate,
    private val productRepository: ProductRepository,
    private val orderRepository: OrderRepository,
    private val orderQueryRepository: OrderQueryRepository,
    private val cartRepository: CartRepository,
    private val cartService: CartService,
    private val orderService: OrderService,
    private val healthContributorRegistry: HealthContributorRegistry,
    private val mockMvc: MockMvc
) {

    @Test
    fun `reports actual database and redis readiness without exposing infrastructure details`() {
        assertThat(healthContributorRegistry.getContributor("db")).isNotNull()
        assertThat(healthContributorRegistry.getContributor("redis")).isNotNull()

        listOf(
            "/actuator/health",
            "/actuator/health/liveness",
            "/actuator/health/readiness"
        ).forEach { path ->
            mockMvc.get(path)
                .andExpect {
                    status { isOk() }
                    header { exists(CorrelationIdContext.HEADER_NAME) }
                    jsonPath("$.status") { value("UP") }
                    jsonPath("$.components") { doesNotExist() }
                    jsonPath("$.details") { doesNotExist() }
                    jsonPath("$.db") { doesNotExist() }
                    jsonPath("$.redis") { doesNotExist() }
                }
        }
    }

    @Test
    fun `applies Flyway migrations V1 through V8 and initializes existing products`() {
        val appliedVersions = flyway.info().applied()
            .mapNotNull { it.version?.version }

        assertThat(appliedVersions).containsExactly("1", "2", "3", "4", "5", "6", "7", "8")
        val existingStock = jdbcTemplate.queryForList(
            "SELECT stock_quantity FROM products WHERE id IN (1, 2, 3) ORDER BY id",
            Int::class.java
        )
        assertThat(existingStock).containsExactly(0, 0, 0)
        val existingActive = jdbcTemplate.queryForList(
            "SELECT active FROM products WHERE id IN (1, 2, 3) ORDER BY id",
            Boolean::class.java
        )
        assertThat(existingActive).containsExactly(true, true, true)
    }

    @Test
    fun `migrates existing confirmed orders to preparing before adding status constraint`() {
        val legacyDatabase = MariaDBContainer<Nothing>("mariadb:10.11")
        legacyDatabase.start()
        try {
            val dataSource = DriverManagerDataSource(
                legacyDatabase.jdbcUrl,
                legacyDatabase.username,
                legacyDatabase.password
            )
            Flyway.configure()
                .dataSource(dataSource)
                .target(MigrationVersion.fromVersion("5"))
                .load()
                .migrate()
            val legacyJdbcTemplate = JdbcTemplate(dataSource)
            legacyJdbcTemplate.update(
                "INSERT INTO orders (user_id, status, total_amount) VALUES (?, 'CONFIRMED', ?)",
                uniqueUserId(),
                10_000L
            )

            val migrationResult = Flyway.configure()
                .dataSource(dataSource)
                .load()
                .migrate()

            assertThat(migrationResult.migrationsExecuted).isEqualTo(3)
            assertThat(legacyJdbcTemplate.queryForObject(
                "SELECT status FROM orders LIMIT 1",
                String::class.java
            )).isEqualTo("PREPARING")
            assertThat(legacyJdbcTemplate.queryForObject(
                "SELECT shipping_recipient_name FROM orders LIMIT 1",
                String::class.java
            )).isNull()
            org.junit.jupiter.api.assertThrows<DataIntegrityViolationException> {
                legacyJdbcTemplate.update(
                    "INSERT INTO orders (user_id, status, total_amount) VALUES (?, 'CONFIRMED', ?)",
                    uniqueUserId(),
                    10_000L
                )
            }
        } finally {
            legacyDatabase.stop()
        }
    }

    @Test
    @Transactional
    fun `database rejects unsupported order status`() {
        org.junit.jupiter.api.assertThrows<DataIntegrityViolationException> {
            jdbcTemplate.update(
                "INSERT INTO orders (user_id, status, total_amount) VALUES (?, 'UNKNOWN', ?)",
                uniqueUserId(),
                10_000L
            )
        }
    }

    @Test
    @Transactional
    fun `conditional order transition rejects a stale expected status`() {
        val saved = orderRepository.save(
            Order(
                id = null,
                userId = uniqueUserId(),
                status = OrderStatus.PENDING,
                items = emptyList(),
                totalAmount = 0L,
                createdAt = null
            )
        )
        val orderId = requireNotNull(saved.id)

        assertThat(orderRepository.transitionStatus(
            orderId,
            OrderStatus.PENDING,
            OrderStatus.PREPARING
        )).isTrue()
        assertThat(orderRepository.transitionStatus(
            orderId,
            OrderStatus.PENDING,
            OrderStatus.CANCELLED
        )).isFalse()
        assertThat(orderRepository.findById(orderId)?.status).isEqualTo(OrderStatus.PREPARING)
    }

    @Test
    @Transactional
    fun `reads lightweight order summaries while detail keeps full items`() {
        val userId = uniqueUserId()
        val productId = productRepository.create(
            product(stockQuantity = 20, namePrefix = "order-summary")
        )
        val initialTotal = orderQueryRepository.findSummaryPage(1, 1).total
        val statuses = listOf(OrderStatus.PENDING, OrderStatus.PREPARING, OrderStatus.SHIPPED)
        val savedOrders = statuses.mapIndexed { index, status ->
            orderRepository.save(
                Order(
                    id = null,
                    userId = userId,
                    status = status,
                    items = listOf(
                        orderItem(productId, "summary-item-${index + 1}-a", index + 1),
                        orderItem(productId, "summary-item-${index + 1}-b", index + 2)
                    ),
                    totalAmount = (index + 1) * 10_000L,
                    createdAt = null,
                    shippingAddress = shippingAddress()
                )
            )
        }
        val expectedDescending = savedOrders.map { requireNotNull(it.id) }.sortedDescending()

        val userSummaries = orderService.getOrders(userId)

        assertThat(userSummaries.map { it.id }).containsExactlyElementsOf(expectedDescending)
        assertThat(userSummaries.map { it.userId }).containsOnly(userId)
        assertThat(userSummaries.map { it.status })
            .containsExactly(OrderStatus.SHIPPED, OrderStatus.PREPARING, OrderStatus.PENDING)
        assertThat(userSummaries.map { it.totalAmount }).containsExactly(30_000L, 20_000L, 10_000L)
        assertThat(userSummaries.map { it.createdAt }).doesNotContainNull()

        val adminPage = orderService.listAllOrders(page = 1, size = 2)

        assertThat(adminPage.items.map { it.id }).containsExactlyElementsOf(expectedDescending.take(2))
        assertThat(adminPage.page).isEqualTo(1)
        assertThat(adminPage.size).isEqualTo(2)
        assertThat(adminPage.total).isEqualTo(initialTotal + 3)
        assertThat(adminPage.totalPages).isEqualTo(((initialTotal + 4) / 2).toInt())

        val userDetail = orderService.getOrder(userId, expectedDescending.first())
        val adminDetail = orderService.getOrderAdmin(expectedDescending[1])
        assertThat(userDetail.items).hasSize(2)
        assertThat(adminDetail.items).hasSize(2)
        assertThat(userDetail.shippingAddress).isEqualTo(shippingAddress())
        assertThat(adminDetail.shippingAddress).isEqualTo(shippingAddress())
        assertThat(userDetail.items.map { it.name })
            .containsExactly("summary-item-3-a", "summary-item-3-b")
        assertThat(adminDetail.items.map { it.name })
            .containsExactly("summary-item-2-a", "summary-item-2-b")
    }

    @Test
    @Transactional
    fun `loads a legacy order without shipping address safely`() {
        jdbcTemplate.update(
            "INSERT INTO orders (user_id, status, total_amount) VALUES (?, 'PENDING', ?)",
            uniqueUserId(),
            10_000L
        )
        val orderId = requireNotNull(jdbcTemplate.queryForObject("SELECT LAST_INSERT_ID()", Long::class.java))

        val legacyOrder = requireNotNull(orderRepository.findById(orderId))

        assertThat(legacyOrder.shippingAddress).isNull()
    }

    @Test
    @Transactional
    fun `searches products by keyword price sort and pagination`() {
        val keyword = "integration-${UUID.randomUUID()}"
        val products = listOf(
            Product(name = "$keyword-low", price = 10_100L, stockQuantity = 3, imageUrl = null, description = keyword),
            Product(name = "$keyword-middle", price = 20_200L, stockQuantity = 5, imageUrl = null, description = keyword),
            Product(name = "$keyword-high", price = 30_300L, stockQuantity = 7, imageUrl = null, description = keyword)
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
        assertThat(result.items.map(Product::stockQuantity)).containsExactly(7, 5)
    }

    @Test
    @Transactional
    fun `persists selects and updates product stock quantity`() {
        val productId = productRepository.create(
            Product(
                name = "stock-mapping-${UUID.randomUUID()}",
                price = 15_000L,
                stockQuantity = 12,
                imageUrl = null,
                description = "stock mapping test"
            )
        )

        val created = requireNotNull(productRepository.findById(productId))
        assertThat(created.stockQuantity).isEqualTo(12)

        assertThat(productRepository.update(created.copy(stockQuantity = 4))).isTrue()
        assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(4)
    }

    @Test
    @Transactional
    fun `database rejects negative product stock quantity`() {
        org.junit.jupiter.api.assertThrows<DataIntegrityViolationException> {
            jdbcTemplate.update(
                """
                INSERT INTO products (name, price, stock_quantity, image_url, description)
                VALUES (?, ?, ?, ?, ?)
                """.trimIndent(),
                "negative-stock-${UUID.randomUUID()}",
                1_000L,
                -1,
                null,
                "negative stock test"
            )
        }
    }

    @Test
    @Transactional
    fun `database rejects invalid product active value`() {
        val productId = productRepository.create(
            product(stockQuantity = 1, namePrefix = "invalid-active")
        )

        org.junit.jupiter.api.assertThrows<DataIntegrityViolationException> {
            jdbcTemplate.update(
                "UPDATE products SET active = 2 WHERE id = ?",
                productId
            )
        }
    }

    @Test
    @Transactional
    fun `deactivation retains product for admin and excludes it from public search and count`() {
        val keyword = "inactive-${UUID.randomUUID()}"
        val productId = productRepository.create(
            Product(
                name = keyword,
                price = 10_000L,
                stockQuantity = 3,
                imageUrl = null,
                description = keyword
            )
        )

        assertThat(productRepository.deactivate(productId)).isTrue()

        val stored = requireNotNull(productRepository.findById(productId))
        assertThat(stored.active).isFalse()
        assertThat(productRepository.findAll()).contains(stored)
        assertThat(productRepository.findActiveById(productId)).isNull()

        val result = productRepository.search(
            ProductSearchCondition(
                keyword = keyword,
                minPrice = null,
                maxPrice = null,
                sort = "newest",
                page = 1,
                size = 12
            )
        )
        assertThat(result.total).isZero()
        assertThat(result.items).isEmpty()
    }

    @Test
    @Transactional
    fun `inactive product rejects stock decrease but accepts stock restoration`() {
        val productId = productRepository.create(
            product(stockQuantity = 3, namePrefix = "inactive-stock")
        )
        assertThat(productRepository.deactivate(productId)).isTrue()

        assertThat(productRepository.decreaseStockIfAvailable(productId, 1)).isFalse()
        assertThat(productRepository.increaseStock(productId, 2)).isTrue()

        val stored = requireNotNull(productRepository.findById(productId))
        assertThat(stored.stockQuantity).isEqualTo(5)
        assertThat(stored.active).isFalse()
    }

    @Test
    fun `inactive product remains visible in cart and blocks cart mutation and order`() {
        val userId = uniqueUserId()
        val productId = productRepository.create(
            product(stockQuantity = 3, namePrefix = "inactive-cart")
        )
        cartRepository.clear(userId)
        cartRepository.increment(userId, productId, 2)
        productRepository.deactivate(productId)

        try {
            val cart = cartService.getCart(userId)
            val line = cart.items.single()
            assertThat(line.productId).isEqualTo(productId)
            assertThat(line.quantity).isEqualTo(2)
            assertThat(line.available).isFalse()

            val addFailure = org.junit.jupiter.api.assertThrows<ApplicationException> {
                cartService.addItem(userId, productId, 1)
            }
            assertThat(addFailure.errorCode).isEqualTo(ApiErrorCode.PRODUCT_NOT_AVAILABLE)

            val updateFailure = org.junit.jupiter.api.assertThrows<ApplicationException> {
                cartService.updateItem(userId, productId, 1)
            }
            assertThat(updateFailure.errorCode).isEqualTo(ApiErrorCode.PRODUCT_NOT_AVAILABLE)

            val orderFailure = org.junit.jupiter.api.assertThrows<ApplicationException> {
                orderService.placeOrder(userId, shippingAddress())
            }
            assertThat(orderFailure.errorCode).isEqualTo(ApiErrorCode.PRODUCT_NOT_AVAILABLE)

            assertThat(cartRepository.findAll(userId)).containsExactly(CartItem(productId, 2))
            assertThat(orderRepository.findByUserId(userId)).isEmpty()
            val stored = requireNotNull(productRepository.findById(productId))
            assertThat(stored.stockQuantity).isEqualTo(3)
            assertThat(stored.active).isFalse()
        } finally {
            cartRepository.clear(userId)
            deleteOrdersForUser(userId)
            deleteProduct(productId)
        }
    }

    @Test
    fun `batch loads active and inactive cart products while preserving Redis order`() {
        val userId = uniqueUserId()
        val activeName = "batch-active-${UUID.randomUUID()}"
        val inactiveName = "batch-inactive-${UUID.randomUUID()}"
        val activeProductId = productRepository.create(
            Product(
                name = activeName,
                price = 1_100L,
                stockQuantity = 7,
                imageUrl = null,
                description = "batch query active product"
            )
        )
        val inactiveProductId = productRepository.create(
            Product(
                name = inactiveName,
                price = 2_200L,
                stockQuantity = 9,
                imageUrl = null,
                description = "batch query inactive product"
            )
        )
        val ghostProductId = Long.MAX_VALUE
        productRepository.deactivate(inactiveProductId)
        cartRepository.clear(userId)
        cartRepository.increment(userId, ghostProductId, 4)
        cartRepository.increment(userId, inactiveProductId, 3)
        cartRepository.increment(userId, activeProductId, 2)

        try {
            val productsById = productRepository.findByIds(
                listOf(inactiveProductId, ghostProductId, activeProductId)
            ).associateBy { requireNotNull(it.id) }

            assertThat(productsById.keys).containsExactlyInAnyOrder(activeProductId, inactiveProductId)
            val activeProduct = requireNotNull(productsById[activeProductId])
            assertThat(activeProduct.name).isEqualTo(activeName)
            assertThat(activeProduct.price).isEqualTo(1_100L)
            assertThat(activeProduct.stockQuantity).isEqualTo(7)
            assertThat(activeProduct.active).isTrue()
            val inactiveProduct = requireNotNull(productsById[inactiveProductId])
            assertThat(inactiveProduct.name).isEqualTo(inactiveName)
            assertThat(inactiveProduct.price).isEqualTo(2_200L)
            assertThat(inactiveProduct.stockQuantity).isEqualTo(9)
            assertThat(inactiveProduct.active).isFalse()

            val cart = cartService.getCart(userId)

            assertThat(cart.items.map { it.productId })
                .containsExactly(activeProductId, inactiveProductId)
            assertThat(cart.items.map { it.quantity }).containsExactly(2, 3)
            assertThat(cart.items.map { it.stockQuantity }).containsExactly(7, 9)
            assertThat(cart.items.map { it.available }).containsExactly(true, false)
            assertThat(cart.totalQuantity).isEqualTo(5)
            assertThat(cart.totalAmount).isEqualTo(8_800L)
            assertThat(cartRepository.findAll(userId)).containsExactly(
                CartItem(activeProductId, 2),
                CartItem(inactiveProductId, 3),
                CartItem(ghostProductId, 4)
            )
        } finally {
            cartRepository.clear(userId)
            deleteProduct(inactiveProductId)
            deleteProduct(activeProductId)
        }
    }

    @Test
    @Transactional
    fun `conditionally decreases stock without allowing a negative value`() {
        val productId = productRepository.create(
            product(stockQuantity = 3, namePrefix = "conditional-stock")
        )

        assertThat(productRepository.decreaseStockIfAvailable(productId, 2)).isTrue()
        assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(1)
        assertThat(productRepository.decreaseStockIfAvailable(productId, 2)).isFalse()
        assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(1)
    }

    @Test
    fun `rolls back earlier stock decrease when another order item is insufficient`() {
        val userId = uniqueUserId()
        val availableProductId = productRepository.create(
            product(stockQuantity = 1, namePrefix = "rollback-available")
        )
        val unavailableProductId = productRepository.create(
            product(stockQuantity = 0, namePrefix = "rollback-unavailable")
        )
        cartRepository.clear(userId)
        cartRepository.increment(userId, availableProductId, 1)
        cartRepository.increment(userId, unavailableProductId, 1)

        try {
            val exception = org.junit.jupiter.api.assertThrows<ApplicationException> {
                orderService.placeOrder(userId, shippingAddress())
            }

            assertThat(exception.errorCode).isEqualTo(ApiErrorCode.INSUFFICIENT_STOCK)
            assertThat(productRepository.findById(availableProductId)?.stockQuantity).isEqualTo(1)
            assertThat(productRepository.findById(unavailableProductId)?.stockQuantity).isZero()
            assertThat(orderRepository.findByUserId(userId)).isEmpty()
            assertThat(cartRepository.findAll(userId)).containsExactly(
                CartItem(availableProductId, 1),
                CartItem(unavailableProductId, 1)
            )
        } finally {
            cartRepository.clear(userId)
            deleteOrdersForUser(userId)
            deleteProduct(availableProductId)
            deleteProduct(unavailableProductId)
        }
    }

    @Test
    fun `allows only one of two concurrent orders for the last item`() {
        val productName = "concurrent-stock-${UUID.randomUUID()}"
        val productId = productRepository.create(
            Product(
                name = productName,
                price = 25_000L,
                stockQuantity = 1,
                imageUrl = null,
                description = "concurrent order test"
            )
        )
        val userIds = listOf(uniqueUserId(), uniqueUserId())
        userIds.forEach { userId ->
            cartRepository.clear(userId)
            cartRepository.increment(userId, productId, 1)
        }
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(userIds.size)

        try {
            val futures = userIds.map { userId ->
                executor.submit<Pair<Long, ApiErrorCode?>> {
                    start.await()
                    try {
                        orderService.placeOrder(userId, shippingAddress())
                        userId to null
                    } catch (exception: ApplicationException) {
                        userId to exception.errorCode
                    }
                }
            }
            start.countDown()
            val attempts = futures.map { it.get(10, TimeUnit.SECONDS) }
            val successUserId = attempts.single { it.second == null }.first
            val failedAttempt = attempts.single { it.second != null }

            assertThat(failedAttempt.second).isEqualTo(ApiErrorCode.INSUFFICIENT_STOCK)
            assertThat(productRepository.findById(productId)?.stockQuantity).isZero()

            val savedOrder = orderRepository.findByUserId(successUserId).single()
            val savedItem = savedOrder.items.single()
            assertThat(savedItem.productId).isEqualTo(productId)
            assertThat(savedItem.name).isEqualTo(productName)
            assertThat(savedItem.price).isEqualTo(25_000L)
            assertThat(savedItem.quantity).isEqualTo(1)
            assertThat(savedItem.lineAmount).isEqualTo(25_000L)

            assertThat(cartRepository.findAll(successUserId)).isEmpty()
            assertThat(cartRepository.findAll(failedAttempt.first))
                .containsExactly(CartItem(productId, 1))
        } finally {
            executor.shutdownNow()
            userIds.forEach { userId ->
                cartRepository.clear(userId)
                deleteOrdersForUser(userId)
            }
            deleteProduct(productId)
        }
    }

    @Test
    fun `places and cancels an order while restoring exact stock`() {
        val userId = uniqueUserId()
        val productId = productRepository.create(
            product(stockQuantity = 5, namePrefix = "cancel-restore")
        )
        cartRepository.clear(userId)
        cartRepository.increment(userId, productId, 3)

        try {
            val order = orderService.placeOrder(userId, shippingAddress())
            assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(2)

            val cancelled = orderService.cancelOrder(userId, requireNotNull(order.id))

            assertThat(cancelled.status).isEqualTo(OrderStatus.CANCELLED)
            assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(5)
            assertThat(cartRepository.findAll(userId)).isEmpty()
        } finally {
            cartRepository.clear(userId)
            deleteOrdersForUser(userId)
            deleteProduct(productId)
        }
    }

    @Test
    fun `cancels existing order after deactivation and restores stock while remaining inactive`() {
        val userId = uniqueUserId()
        val productId = productRepository.create(
            product(stockQuantity = 5, namePrefix = "inactive-cancel-restore")
        )
        cartRepository.clear(userId)
        cartRepository.increment(userId, productId, 3)

        try {
            val order = orderService.placeOrder(userId, shippingAddress())
            assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(2)
            assertThat(productRepository.deactivate(productId)).isTrue()

            val cancelled = orderService.cancelOrder(userId, requireNotNull(order.id))

            assertThat(cancelled.status).isEqualTo(OrderStatus.CANCELLED)
            val stored = requireNotNull(productRepository.findById(productId))
            assertThat(stored.stockQuantity).isEqualTo(5)
            assertThat(stored.active).isFalse()
        } finally {
            cartRepository.clear(userId)
            deleteOrdersForUser(userId)
            deleteProduct(productId)
        }
    }

    @Test
    fun `keeps product order and cart consistent when deactivation races with order`() {
        val userId = uniqueUserId()
        val productId = productRepository.create(
            product(stockQuantity = 1, namePrefix = "deactivate-order-race")
        )
        cartRepository.clear(userId)
        cartRepository.increment(userId, productId, 1)
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)

        try {
            val deactivateFuture = executor.submit<Boolean> {
                start.await()
                productRepository.deactivate(productId)
            }
            val orderFuture = executor.submit<ApiErrorCode?> {
                start.await()
                try {
                    orderService.placeOrder(userId, shippingAddress())
                    null
                } catch (exception: ApplicationException) {
                    exception.errorCode
                }
            }

            start.countDown()
            assertThat(deactivateFuture.get(10, TimeUnit.SECONDS)).isTrue()
            val orderError = orderFuture.get(10, TimeUnit.SECONDS)
            val stored = requireNotNull(productRepository.findById(productId))
            val orders = orderRepository.findByUserId(userId)

            assertThat(stored.active).isFalse()
            assertThat(stored.stockQuantity).isGreaterThanOrEqualTo(0)
            when (orderError) {
                null -> {
                    assertThat(stored.stockQuantity).isZero()
                    assertThat(orders).hasSize(1)
                    assertThat(orders.single().items).hasSize(1)
                    assertThat(cartRepository.findAll(userId)).isEmpty()
                }
                ApiErrorCode.PRODUCT_NOT_AVAILABLE -> {
                    assertThat(stored.stockQuantity).isEqualTo(1)
                    assertThat(orders).isEmpty()
                    assertThat(cartRepository.findAll(userId)).containsExactly(CartItem(productId, 1))
                }
                else -> throw AssertionError("Unexpected order result: $orderError")
            }
        } finally {
            executor.shutdownNow()
            cartRepository.clear(userId)
            deleteOrdersForUser(userId)
            deleteProduct(productId)
        }
    }

    @Test
    fun `allows only one concurrent cancellation and restores stock once`() {
        val userId = uniqueUserId()
        val productId = productRepository.create(
            product(stockQuantity = 2, namePrefix = "concurrent-cancel")
        )
        cartRepository.clear(userId)
        cartRepository.increment(userId, productId, 2)
        val orderId = requireNotNull(orderService.placeOrder(userId, shippingAddress()).id)
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)

        try {
            val futures = List(2) {
                executor.submit<ApiErrorCode?> {
                    start.await()
                    try {
                        orderService.cancelOrder(userId, orderId)
                        null
                    } catch (exception: ApplicationException) {
                        exception.errorCode
                    }
                }
            }
            start.countDown()
            val attempts = futures.map { it.get(10, TimeUnit.SECONDS) }

            assertThat(attempts.count { it == null }).isEqualTo(1)
            assertThat(attempts.count { it == ApiErrorCode.INVALID_ORDER_TRANSITION }).isEqualTo(1)
            assertThat(orderRepository.findById(orderId)?.status).isEqualTo(OrderStatus.CANCELLED)
            assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(2)
        } finally {
            executor.shutdownNow()
            cartRepository.clear(userId)
            deleteOrdersForUser(userId)
            deleteProduct(productId)
        }
    }

    @Test
    fun `keeps order and stock consistent when admin transition races with user cancellation`() {
        val userId = uniqueUserId()
        val productId = productRepository.create(
            product(stockQuantity = 1, namePrefix = "admin-user-race")
        )
        cartRepository.clear(userId)
        cartRepository.increment(userId, productId, 1)
        val orderId = requireNotNull(orderService.placeOrder(userId, shippingAddress()).id)
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)

        try {
            val futures = listOf(
                executor.submit<ApiErrorCode?> {
                    start.await()
                    try {
                        orderService.updateStatus(orderId, OrderStatus.PREPARING)
                        null
                    } catch (exception: ApplicationException) {
                        exception.errorCode
                    }
                },
                executor.submit<ApiErrorCode?> {
                    start.await()
                    try {
                        orderService.cancelOrder(userId, orderId)
                        null
                    } catch (exception: ApplicationException) {
                        exception.errorCode
                    }
                }
            )
            start.countDown()
            val attempts = futures.map { it.get(10, TimeUnit.SECONDS) }
            val finalOrder = requireNotNull(orderRepository.findById(orderId))
            val finalStock = productRepository.findById(productId)?.stockQuantity

            assertThat(attempts.count { it == null }).isEqualTo(1)
            assertThat(attempts.count { it == ApiErrorCode.INVALID_ORDER_TRANSITION }).isEqualTo(1)
            when (finalOrder.status) {
                OrderStatus.PREPARING -> assertThat(finalStock).isZero()
                OrderStatus.CANCELLED -> assertThat(finalStock).isEqualTo(1)
                else -> throw AssertionError("Unexpected final order status: ${finalOrder.status}")
            }
        } finally {
            executor.shutdownNow()
            cartRepository.clear(userId)
            deleteOrdersForUser(userId)
            deleteProduct(productId)
        }
    }

    @Test
    fun `database rejects hard delete for product referenced by order item`() {
        val userId = uniqueUserId()
        val productId = productRepository.create(
            product(stockQuantity = 1, namePrefix = "delete-restricted")
        )
        cartRepository.clear(userId)
        cartRepository.increment(userId, productId, 1)
        orderService.placeOrder(userId, shippingAddress())

        try {
            org.junit.jupiter.api.assertThrows<DataIntegrityViolationException> {
                jdbcTemplate.update("DELETE FROM products WHERE id = ?", productId)
            }

            assertThat(productRepository.findById(productId)).isNotNull()
        } finally {
            cartRepository.clear(userId)
            deleteOrdersForUser(userId)
            deleteProduct(productId)
        }
    }

    @Test
    @Transactional
    fun `saves an order and reloads generated identifiers`() {
        val productId = productRepository.create(
            product(stockQuantity = 2, namePrefix = "order-identifiers")
        )
        val order = Order(
            id = null,
            userId = 9_001L,
            status = OrderStatus.PENDING,
            items = listOf(
                OrderItem(
                    id = null,
                    orderId = 0L,
                    productId = productId,
                    name = "Integration Test Product",
                    price = 12_500L,
                    quantity = 2,
                    lineAmount = 25_000L
                )
            ),
            totalAmount = 25_000L,
            createdAt = null,
            shippingAddress = shippingAddress()
        )

        val saved = orderRepository.save(order)
        val orderId = requireNotNull(saved.id)
        val reloaded = requireNotNull(orderRepository.findById(orderId))
        val reloadedItem = reloaded.items.single()

        assertThat(orderId).isPositive()
        assertThat(reloaded.userId).isEqualTo(order.userId)
        assertThat(reloaded.status).isEqualTo(OrderStatus.PENDING)
        assertThat(reloaded.totalAmount).isEqualTo(order.totalAmount)
        assertThat(reloaded.shippingAddress).isEqualTo(order.shippingAddress)
        assertThat(reloaded.createdAt).isNotNull()
        assertThat(reloadedItem.id).isNotNull()
        assertThat(reloadedItem.orderId).isEqualTo(orderId)
        assertThat(reloadedItem.productId).isEqualTo(productId)
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

    private fun product(stockQuantity: Int, namePrefix: String): Product = Product(
        name = "$namePrefix-${UUID.randomUUID()}",
        price = 10_000L,
        stockQuantity = stockQuantity,
        imageUrl = null,
        description = "stock integration test"
    )

    private fun orderItem(productId: Long, name: String, quantity: Int) = OrderItem(
        id = null,
        orderId = 0L,
        productId = productId,
        name = name,
        price = 1_000L,
        quantity = quantity,
        lineAmount = 1_000L * quantity
    )

    private fun shippingAddress() = ShippingAddress(
        recipientName = "Integration Recipient",
        postalCode = "100-0001",
        prefecture = "Tokyo",
        city = "Chiyoda-ku",
        addressLine1 = "Chiyoda 1-1",
        addressLine2 = "Integration Building 101",
        phoneNumber = "03-1234-5678"
    )

    private fun uniqueUserId(): Long =
        ThreadLocalRandom.current().nextLong(1_000_000_000L, Long.MAX_VALUE)

    private fun deleteOrdersForUser(userId: Long) {
        val orderIds = jdbcTemplate.queryForList(
            "SELECT id FROM orders WHERE user_id = ?",
            Long::class.java,
            userId
        )
        orderIds.forEach { orderId ->
            jdbcTemplate.update("DELETE FROM order_items WHERE order_id = ?", orderId)
            jdbcTemplate.update("DELETE FROM orders WHERE id = ?", orderId)
        }
    }

    private fun deleteProduct(productId: Long) {
        jdbcTemplate.update("DELETE FROM products WHERE id = ?", productId)
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
