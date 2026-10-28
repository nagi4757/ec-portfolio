package com.nagi4757.ec.api.integration

import com.nagi4757.ec.api.cart.domain.repository.CartRepository
import com.nagi4757.ec.api.checkout.application.CheckoutCommand
import com.nagi4757.ec.api.checkout.application.CheckoutReservationService
import com.nagi4757.ec.api.checkout.application.ReserveOutcome
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApplicationException
import com.nagi4757.ec.api.order.domain.model.ShippingAddress
import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.application.command.UpdateProductCommand
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.assertj.core.api.Assertions.assertThat
import org.awaitility.Awaitility.await
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.testcontainers.service.connection.ServiceConnection
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.test.context.ActiveProfiles
import org.springframework.transaction.PlatformTransactionManager
import org.springframework.transaction.support.TransactionTemplate
import org.testcontainers.containers.GenericContainer
import org.testcontainers.containers.MariaDBContainer
import org.testcontainers.junit.jupiter.Container
import org.testcontainers.junit.jupiter.Testcontainers
import java.sql.DriverManager
import java.time.Duration
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit

/**
 * Admin product edits against the stock that checkout and refunds move at the same time.
 *
 * An edit reads the product and writes it back. A reservation, cancellation or refund
 * that commits in between must survive that write. Whether it does depends on how
 * InnoDB orders the row lock, so only the real database can show it.
 *
 * The interleavings are forced rather than hoped for: the competing transaction is held
 * open, and it commits only once InnoDB reports the edit queued behind its row lock.
 * That is the moment the edit has already read the old stock but not yet written.
 */
@Tag("integration")
@Testcontainers
@SpringBootTest
@ActiveProfiles("integration-test")
class ProductStockConcurrencyIntegrationTest @Autowired constructor(
    private val jdbcTemplate: JdbcTemplate,
    transactionManager: PlatformTransactionManager,
    private val productService: ProductService,
    private val productRepository: ProductRepository,
    private val cartRepository: CartRepository,
    private val reservationService: CheckoutReservationService
) {
    private val transactionTemplate = TransactionTemplate(transactionManager)

    // --- R1. an edit that leaves the stock alone ---------------------------------

    @Test
    fun `an edit queued behind a reservation keeps the reserved stock`() {
        val productId = newProduct(stock = 10)
        val executor = Executors.newFixedThreadPool(2)

        try {
            val reservation = holdOpen(executor) {
                check(productRepository.decreaseStockIfAvailable(productId, 3))
            }
            val edit = executor.submit<Product> {
                productService.update(productId, UpdateProductCommand(name = "renamed"))
            }
            awaitQueuedBehind(reservation)
            reservation.commit()
            edit.get(10, TimeUnit.SECONDS)

            assertThat(stored(productId)).isEqualTo(StoredProduct("renamed", ORIGINAL_PRICE, 7))
        } finally {
            executor.shutdownNow()
            deleteProduct(productId)
        }
    }

    @Test
    fun `an edit queued behind a stock restoration keeps the restored stock`() {
        val productId = newProduct(stock = 10)
        val executor = Executors.newFixedThreadPool(2)

        try {
            // The statement cancellation and refund both use to return units.
            val restoration = holdOpen(executor) {
                check(productRepository.increaseStock(productId, 3))
            }
            val edit = executor.submit<Product> {
                productService.update(productId, UpdateProductCommand(name = "renamed"))
            }
            awaitQueuedBehind(restoration)
            restoration.commit()
            edit.get(10, TimeUnit.SECONDS)

            assertThat(stored(productId)).isEqualTo(StoredProduct("renamed", ORIGINAL_PRICE, 13))
        } finally {
            executor.shutdownNow()
            deleteProduct(productId)
        }
    }

    // --- R2. an edit that sends back the stock it was loaded with ------------------

    @Test
    fun `an edit carrying the stock it was loaded with does not undo a later reservation`() {
        val productId = newProduct(stock = 10)
        val buyer = newUser()
        cartRepository.increment(buyer, productId, 3)

        try {
            // The edit page opens on a stock of 10, then checkout takes 3.
            val loaded = requireNotNull(productService.get(productId))
            assertThat(reservationService.reserve(command(buyer)))
                .isInstanceOf(ReserveOutcome.Reserved::class.java)

            // The admin renames the product and submits the stock field untouched.
            productService.update(
                productId,
                UpdateProductCommand(
                    name = "renamed",
                    stockQuantity = loaded.stockQuantity,
                    expectedStockQuantity = loaded.stockQuantity
                )
            )

            assertThat(stored(productId)).isEqualTo(StoredProduct("renamed", ORIGINAL_PRICE, 7))
            assertThat(unitsHeldByOrders(productId)).isEqualTo(3)
        } finally {
            deleteUser(buyer)
            deleteProduct(productId)
        }
    }

    // --- R3. a stock change from a value that is no longer there -------------------

    @Test
    fun `a stock change from a stale value is refused and rolls back the whole edit`() {
        val productId = newProduct(stock = 10)

        try {
            // Checkout took 3 after the admin loaded a stock of 10.
            check(productRepository.decreaseStockIfAvailable(productId, 3))

            val conflict = assertThrows<ApplicationException> {
                productService.update(productId, staleStockChange())
            }

            assertThat(conflict.errorCode).isEqualTo(ApiErrorCode.PRODUCT_STOCK_CONFLICT)
            // The name and price were written in the same transaction as the refused
            // stock change, and were rolled back with it.
            assertThat(stored(productId)).isEqualTo(StoredProduct(ORIGINAL_NAME, ORIGINAL_PRICE, 7))
        } finally {
            deleteProduct(productId)
        }
    }

    @Test
    fun `a stock change queued behind a reservation is refused once the reservation commits`() {
        val productId = newProduct(stock = 10)
        val executor = Executors.newFixedThreadPool(2)

        try {
            val reservation = holdOpen(executor) {
                check(productRepository.decreaseStockIfAvailable(productId, 3))
            }
            val edit = executor.submit<Product> {
                productService.update(productId, staleStockChange())
            }
            awaitQueuedBehind(reservation)
            reservation.commit()

            val failure = assertThrows<ExecutionException> { edit.get(10, TimeUnit.SECONDS) }
            assertThat(failure.cause).isInstanceOfSatisfying(ApplicationException::class.java) {
                assertThat(it.errorCode).isEqualTo(ApiErrorCode.PRODUCT_STOCK_CONFLICT)
            }
            assertThat(stored(productId)).isEqualTo(StoredProduct(ORIGINAL_NAME, ORIGINAL_PRICE, 7))
        } finally {
            executor.shutdownNow()
            deleteProduct(productId)
        }
    }

    // --- R4. a stock change from the current value ---------------------------------

    @Test
    fun `a stock change from the current value is applied with the rest of the edit`() {
        val productId = newProduct(stock = 10)

        try {
            val updated = productService.update(
                productId,
                UpdateProductCommand(
                    name = "renamed",
                    price = 2_000L,
                    stockQuantity = 25,
                    expectedStockQuantity = 10
                )
            )

            assertThat(updated.stockQuantity).isEqualTo(25)
            assertThat(stored(productId)).isEqualTo(StoredProduct("renamed", 2_000L, 25))
        } finally {
            deleteProduct(productId)
        }
    }

    @Test
    fun `a reservation queued behind a stock change applies on top of the new stock`() {
        val productId = newProduct(stock = 10)
        val executor = Executors.newFixedThreadPool(2)

        try {
            // The edit joins the held transaction, so its row lock outlives the call.
            val edit = holdOpen(executor) {
                productService.update(
                    productId,
                    UpdateProductCommand(stockQuantity = 25, expectedStockQuantity = 10)
                )
            }
            val reservation = executor.submit<Boolean> {
                productRepository.decreaseStockIfAvailable(productId, 3)
            }
            awaitQueuedBehind(edit)
            edit.commit()

            assertThat(reservation.get(10, TimeUnit.SECONDS)).isTrue()
            assertThat(stored(productId).stock).isEqualTo(22)
        } finally {
            executor.shutdownNow()
            deleteProduct(productId)
        }
    }

    // --- R5. many of both at once ------------------------------------------------

    /**
     * No forced order here: every interleaving the scheduler picks must keep the
     * books balanced. The forced cases above are what reproduce the bug on demand.
     */
    @Test
    fun `concurrent reservations and edits account for every unit`() {
        val initialStock = 30
        val productId = newProduct(stock = initialStock)
        val buyers = List(BUYERS) {
            newUser().also { userId -> cartRepository.increment(userId, productId, 1) }
        }
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(BUYERS + EDITS)

        try {
            val reservations = buyers.map { userId ->
                executor.submit<ReserveOutcome> {
                    start.await()
                    reservationService.reserve(command(userId))
                }
            }
            val edits = List(EDITS) { index ->
                executor.submit<Product> {
                    start.await()
                    productService.update(
                        productId,
                        UpdateProductCommand(name = "edit-$index", price = ORIGINAL_PRICE + index)
                    )
                }
            }
            start.countDown()
            val outcomes = reservations.map { it.get(30, TimeUnit.SECONDS) }
            edits.forEach { it.get(30, TimeUnit.SECONDS) }

            assertThat(outcomes).allMatch { it is ReserveOutcome.Reserved }
            // Every unit is either still on the shelf or held by an order. None was
            // written back over a reservation, and none appeared from nowhere.
            assertThat(stored(productId).stock).isEqualTo(initialStock - BUYERS)
            assertThat(unitsHeldByOrders(productId)).isEqualTo(BUYERS)
        } finally {
            executor.shutdownNow()
            buyers.forEach(::deleteUser)
            deleteProduct(productId)
        }
    }

    // --- helpers -------------------------------------------------------------------

    /** Renames, reprices and restocks a product the admin loaded with a stock of 10. */
    private fun staleStockChange() = UpdateProductCommand(
        name = "renamed",
        price = 2_000L,
        stockQuantity = 20,
        expectedStockQuantity = 10
    )

    /**
     * Runs [work] in a transaction on its own thread and keeps that transaction open,
     * with the row locks it took, until [HeldTransaction.commit] is called.
     */
    private fun holdOpen(executor: ExecutorService, work: () -> Unit): HeldTransaction {
        val connectionId = CompletableFuture<Long>()
        val release = CountDownLatch(1)
        val finished = executor.submit<Unit> {
            try {
                transactionTemplate.executeWithoutResult {
                    work()
                    connectionId.complete(
                        requireNotNull(
                            jdbcTemplate.queryForObject("SELECT CONNECTION_ID()", Long::class.java)
                        )
                    )
                    // Bounded, so a failed test cannot leave the row locked for good.
                    check(release.await(10, TimeUnit.SECONDS)) {
                        "The held transaction was never released"
                    }
                }
            } catch (failure: Throwable) {
                connectionId.completeExceptionally(failure)
                throw failure
            }
        }
        return HeldTransaction(connectionId.get(10, TimeUnit.SECONDS), release, finished)
    }

    /**
     * Waits until InnoDB reports a transaction queued behind [held]'s row lock.
     *
     * INNODB_LOCK_WAITS needs the PROCESS privilege, which the application's database
     * user does not have, so the check runs on a root connection only this test opens.
     */
    private fun awaitQueuedBehind(held: HeldTransaction) {
        DriverManager.getConnection(mariaDb.jdbcUrl, "root", mariaDb.password).use { monitor ->
            monitor.prepareStatement(
                """
                SELECT COUNT(*)
                FROM information_schema.INNODB_LOCK_WAITS w
                JOIN information_schema.INNODB_TRX blocking ON blocking.trx_id = w.blocking_trx_id
                WHERE blocking.trx_mysql_thread_id = ?
                """.trimIndent()
            ).use { query ->
                query.setLong(1, held.connectionId)
                await()
                    .atMost(Duration.ofSeconds(10))
                    .pollInterval(Duration.ofMillis(20))
                    .until { query.executeQuery().use { it.next() && it.getLong(1) > 0 } }
            }
        }
    }

    private class HeldTransaction(
        val connectionId: Long,
        private val release: CountDownLatch,
        private val finished: Future<Unit>
    ) {
        fun commit() {
            release.countDown()
            finished.get(10, TimeUnit.SECONDS)
        }
    }

    private data class StoredProduct(val name: String, val price: Long, val stock: Int)

    private fun stored(productId: Long): StoredProduct = requireNotNull(
        jdbcTemplate.queryForObject(
            "SELECT name, price, stock_quantity FROM products WHERE id = ?",
            { rs, _ -> StoredProduct(rs.getString("name"), rs.getLong("price"), rs.getInt("stock_quantity")) },
            productId
        )
    )

    private fun unitsHeldByOrders(productId: Long): Int = requireNotNull(
        jdbcTemplate.queryForObject(
            "SELECT COALESCE(SUM(quantity), 0) FROM order_items WHERE product_id = ?",
            Int::class.java,
            productId
        )
    )

    private fun newProduct(stock: Int): Long = productRepository.create(
        Product(
            id = null,
            name = ORIGINAL_NAME,
            price = ORIGINAL_PRICE,
            stockQuantity = stock,
            imageUrl = null,
            description = null,
            active = true
        )
    )

    private fun deleteProduct(productId: Long) {
        jdbcTemplate.update("DELETE FROM products WHERE id = ?", productId)
    }

    /** A real users row: checkout locks it FOR UPDATE before touching any stock. */
    private fun newUser(): Long {
        jdbcTemplate.update(
            "INSERT INTO users (email, password_hash, name, role) VALUES (?, 'x', 'Test', 'USER')",
            "stock-${UUID.randomUUID()}@example.test"
        )
        return requireNotNull(jdbcTemplate.queryForObject("SELECT LAST_INSERT_ID()", Long::class.java))
    }

    private fun deleteUser(userId: Long) {
        cartRepository.clear(userId)
        jdbcTemplate.update(
            "DELETE FROM payment_attempts WHERE order_id IN (SELECT id FROM orders WHERE user_id = ?)",
            userId
        )
        jdbcTemplate.update(
            "DELETE FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = ?)",
            userId
        )
        jdbcTemplate.update("DELETE FROM orders WHERE user_id = ?", userId)
        jdbcTemplate.update("DELETE FROM users WHERE id = ?", userId)
    }

    private fun command(userId: Long) = CheckoutCommand(
        userId = userId,
        shippingAddress = SHIPPING_ADDRESS,
        paymentMethodId = "mock:success",
        idempotencyKey = "stock-${UUID.randomUUID()}"
    )

    companion object {
        private const val ORIGINAL_NAME = "original"
        private const val ORIGINAL_PRICE = 1_000L
        private const val BUYERS = 12
        private const val EDITS = 8

        private val SHIPPING_ADDRESS = ShippingAddress(
            recipientName = "山田 太郎",
            postalCode = "100-0001",
            prefecture = "東京都",
            city = "千代田区",
            addressLine1 = "千代田1-1",
            addressLine2 = null,
            phoneNumber = "03-1234-5678"
        )

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
