package com.nagi4757.ec.api.integration

import com.nagi4757.ec.api.cart.domain.model.CartItem
import com.nagi4757.ec.api.cart.domain.repository.CartRepository
import com.nagi4757.ec.api.checkout.application.CheckoutCommand
import com.nagi4757.ec.api.checkout.application.CheckoutCoordinator
import com.nagi4757.ec.api.checkout.application.CheckoutFinalizeService
import com.nagi4757.ec.api.checkout.application.CheckoutOutcome
import com.nagi4757.ec.api.checkout.application.CheckoutReservationService
import com.nagi4757.ec.api.checkout.application.PaymentResultService
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApplicationException
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.model.ShippingAddress
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.payment.application.ChargePaymentResult
import com.nagi4757.ec.api.payment.application.ChargePaymentStatus
import com.nagi4757.ec.api.payment.domain.model.PaymentAttemptStatus
import com.nagi4757.ec.api.payment.domain.repository.PaymentAttemptRepository
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.testcontainers.service.connection.ServiceConnection
import org.springframework.dao.DataIntegrityViolationException
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.test.context.ActiveProfiles
import org.testcontainers.containers.GenericContainer
import org.testcontainers.containers.MariaDBContainer
import org.testcontainers.junit.jupiter.Container
import org.testcontainers.junit.jupiter.Testcontainers
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The checkout contract against real MariaDB and Redis.
 *
 * Everything that matters about this flow only holds if the database enforces it:
 * the unique idempotency key, the foreign key to the order, the status CHECK, the
 * conditional transitions, and the atomicity of the Redis cart subtraction. Mocks
 * cannot demonstrate any of those.
 */
@Tag("integration")
@Testcontainers
@SpringBootTest
@ActiveProfiles("integration-test")
class CheckoutOrchestrationIntegrationTest @Autowired constructor(
    private val jdbcTemplate: JdbcTemplate,
    private val productRepository: ProductRepository,
    private val orderRepository: OrderRepository,
    private val paymentAttemptRepository: PaymentAttemptRepository,
    private val cartRepository: CartRepository,
    private val checkoutCoordinator: CheckoutCoordinator,
    private val reservationService: CheckoutReservationService,
    private val paymentResultService: PaymentResultService,
    private val finalizeService: CheckoutFinalizeService
) {
    // --- A. schema and migration ------------------------------------------------

    @Test
    fun `V10 applied and the order status check accepts payment pending`() {
        val applied = jdbcTemplate.queryForList(
            "SELECT version, success FROM flyway_schema_history WHERE version = '10'"
        )
        assertThat(applied).hasSize(1)
        assertThat(applied.single()["success"].toString()).isIn("1", "true")

        val userId = uniqueUserId()
        val productId = newProduct(stock = 5)
        cartRepository.increment(userId, productId, 1)
        val reserved = reservationService.reserve(command(userId, "mock:success"))

        assertThat(reserved.order.status).isEqualTo(OrderStatus.PAYMENT_PENDING)
        val stored = jdbcTemplate.queryForObject(
            "SELECT status FROM orders WHERE id = ?", String::class.java, reserved.order.id
        )
        assertThat(stored).isEqualTo("PAYMENT_PENDING")

        cleanup(userId, productId)
    }

    @Test
    fun `orders reject a status the check constraint does not allow`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 5)
        cartRepository.increment(userId, productId, 1)
        val orderId = reservationService.reserve(command(userId, "mock:success")).order.id

        assertThrows<DataIntegrityViolationException> {
            jdbcTemplate.update("UPDATE orders SET status = 'REFUNDED' WHERE id = ?", orderId)
        }

        cleanup(userId, productId)
    }

    @Test
    fun `payment attempts enforce the order foreign key and the unique idempotency key`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 5)
        cartRepository.increment(userId, productId, 1)
        val orderId = requireNotNull(reservationService.reserve(command(userId, "mock:success")).order.id)
        val key = "fk-unique-${UUID.randomUUID()}"

        paymentAttemptRepository.createPending(key, FINGERPRINT, 10_000L, orderId)

        // The unique constraint is what makes concurrent first requests safe.
        assertThrows<DataIntegrityViolationException> {
            paymentAttemptRepository.createPending(key, FINGERPRINT, 10_000L, orderId)
        }

        // The foreign key is what guarantees a retry can always find its order.
        assertThrows<DataIntegrityViolationException> {
            paymentAttemptRepository.createPending(
                "fk-missing-${UUID.randomUUID()}", FINGERPRINT, 10_000L, 99_999_999L
            )
        }

        cleanup(userId, productId)
    }

    @Test
    fun `payment attempt transitions follow the conditional contract`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 5)
        cartRepository.increment(userId, productId, 1)
        val orderId = requireNotNull(reservationService.reserve(command(userId, "mock:success")).order.id)

        // PENDING -> TIMEOUT is allowed, and TIMEOUT stays non-terminal.
        val pending = paymentAttemptRepository.createPending(
            "tx-pending-${UUID.randomUUID()}", FINGERPRINT, 10_000L, orderId
        )
        val toTimeout = paymentAttemptRepository.applyResult(
            requireNotNull(pending.id), PaymentAttemptStatus.TIMEOUT, null
        )
        assertThat(toTimeout.applied).isTrue()
        assertThat(toTimeout.attempt.status).isEqualTo(PaymentAttemptStatus.TIMEOUT)

        // TIMEOUT -> SUCCESS is allowed: a retry may still resolve it.
        val toSuccess = paymentAttemptRepository.applyResult(
            requireNotNull(pending.id), PaymentAttemptStatus.SUCCESS, "external-1"
        )
        assertThat(toSuccess.applied).isTrue()
        assertThat(toSuccess.attempt.status).isEqualTo(PaymentAttemptStatus.SUCCESS)
        assertThat(toSuccess.attempt.externalPaymentId).isEqualTo("external-1")

        // terminal -> anything is refused, and the caller is handed the stored fact
        // rather than an error. This is the 0-row reload contract.
        val afterTerminal = paymentAttemptRepository.applyResult(
            requireNotNull(pending.id), PaymentAttemptStatus.FAILED, null
        )
        assertThat(afterTerminal.applied).isFalse()
        assertThat(afterTerminal.attempt.status).isEqualTo(PaymentAttemptStatus.SUCCESS)
        assertThat(afterTerminal.attempt.externalPaymentId).isEqualTo("external-1")

        val onDisk = jdbcTemplate.queryForMap(
            "SELECT status, external_payment_id FROM payment_attempts WHERE id = ?", pending.id
        )
        assertThat(onDisk["status"]).isEqualTo("SUCCESS")
        assertThat(onDisk["external_payment_id"]).isEqualTo("external-1")

        cleanup(userId, productId)
    }

    // --- B. Redis Lua cart cleanup ----------------------------------------------

    @Test
    fun `cart cleanup subtracts only the reserved quantity`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 5)

        val remaining = cartRepository.removeSnapshotQuantity(userId, productId, 3)

        assertThat(remaining).isEqualTo(2)
        assertThat(cartRepository.findAll(userId)).containsExactly(CartItem(productId, 2))

        cleanup(userId, productId)
    }

    @Test
    fun `cart cleanup removes the line when nothing is left`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)

        val remaining = cartRepository.removeSnapshotQuantity(userId, productId, 3)

        assertThat(remaining).isEqualTo(0)
        assertThat(cartRepository.findAll(userId)).isEmpty()
        // Subtracting again from an absent line is a no-op, not a negative quantity.
        assertThat(cartRepository.removeSnapshotQuantity(userId, productId, 3)).isEqualTo(0)

        cleanup(userId, productId)
    }

    @Test
    fun `a concurrent add is never swallowed by a cleanup`() {
        // The whole reason the subtraction is a Lua script. Read-then-write would let
        // the add land between the two commands and be deleted with the line.
        repeat(30) {
            val userId = uniqueUserId()
            val productId = newProduct(stock = 100)
            cartRepository.increment(userId, productId, 3)

            val start = CountDownLatch(1)
            val executor = Executors.newFixedThreadPool(2)
            try {
                val adder = executor.submit {
                    start.await()
                    cartRepository.increment(userId, productId, 2)
                }
                val cleaner = executor.submit {
                    start.await()
                    cartRepository.removeSnapshotQuantity(userId, productId, 3)
                }
                start.countDown()
                adder.get(10, TimeUnit.SECONDS)
                cleaner.get(10, TimeUnit.SECONDS)

                // 3 + 2 - 3 = 2 whichever order the two operations land in.
                assertThat(cartRepository.findAll(userId)).containsExactly(CartItem(productId, 2))
            } finally {
                executor.shutdownNow()
                cleanup(userId, productId)
            }
        }
    }

    @Test
    fun `replaying a successful checkout does not subtract the cart twice`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val command = command(userId, "mock:success")

        val first = checkoutCoordinator.checkout(command)
        assertThat(first.outcome).isEqualTo(CheckoutOutcome.PAID)
        assertThat(cartRepository.findAll(userId)).isEmpty()

        // The customer puts two of the same product back in the basket, then the
        // original request is retried. The replay must not touch the new line.
        cartRepository.increment(userId, productId, 2)

        val replay = checkoutCoordinator.checkout(command)

        assertThat(replay.outcome).isEqualTo(CheckoutOutcome.PAID)
        assertThat(replay.order.id).isEqualTo(first.order.id)
        assertThat(cartRepository.findAll(userId)).containsExactly(CartItem(productId, 2))

        cleanup(userId, productId)
    }

    // --- C. coordinator contract -------------------------------------------------

    @Test
    fun `successful checkout confirms the order and records the charge`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)

        val result = checkoutCoordinator.checkout(command(userId, "mock:success"))

        assertThat(result.outcome).isEqualTo(CheckoutOutcome.PAID)
        assertThat(result.order.status).isEqualTo(OrderStatus.PENDING)
        assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(7)
        assertThat(cartRepository.findAll(userId)).isEmpty()

        val attempt = attemptFor(result.order.id)
        assertThat(attempt.status).isEqualTo(PaymentAttemptStatus.SUCCESS)
        assertThat(attempt.externalPaymentId).isNotNull()

        cleanup(userId, productId)
    }

    @Test
    fun `declined and failed checkouts cancel the order and restore stock exactly once`() {
        listOf("mock:declined" to CheckoutOutcome.DECLINED, "mock:failed" to CheckoutOutcome.FAILED)
            .forEach { (paymentMethod, expected) ->
                val userId = uniqueUserId()
                val productId = newProduct(stock = 10)
                cartRepository.increment(userId, productId, 3)
                val command = command(userId, paymentMethod)

                val result = checkoutCoordinator.checkout(command)

                assertThat(result.outcome).isEqualTo(expected)
                assertThat(result.order.status).isEqualTo(OrderStatus.CANCELLED)
                assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(10)
                // The basket survives so the customer can try another card.
                assertThat(cartRepository.findAll(userId)).containsExactly(CartItem(productId, 3))

                // Replaying must not restore the stock a second time.
                checkoutCoordinator.checkout(command)
                assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(10)

                cleanup(userId, productId)
            }
    }

    @Test
    fun `a timeout holds the reservation instead of cancelling it`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)

        val result = checkoutCoordinator.checkout(command(userId, "mock:timeout"))

        assertThat(result.outcome).isEqualTo(CheckoutOutcome.PENDING_CONFIRMATION)
        assertThat(result.order.status).isEqualTo(OrderStatus.PAYMENT_PENDING)
        // The charge may have happened. Releasing the stock and cancelling would risk
        // taking the money and shipping nothing.
        assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(7)
        assertThat(cartRepository.findAll(userId)).containsExactly(CartItem(productId, 3))
        assertThat(attemptFor(result.order.id).status).isEqualTo(PaymentAttemptStatus.TIMEOUT)

        cleanup(userId, productId)
    }

    @Test
    fun `reusing a key with a different request is refused`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val key = "conflict-${UUID.randomUUID()}"

        checkoutCoordinator.checkout(command(userId, "mock:success", key))

        // Same key, different payment method: a different request.
        val conflict = assertThrows<ApplicationException> {
            checkoutCoordinator.checkout(command(userId, "mock:declined", key))
        }
        assertThat(conflict.errorCode).isEqualTo(ApiErrorCode.PAYMENT_IDEMPOTENCY_CONFLICT)

        cleanup(userId, productId)
    }

    @Test
    fun `a retry identifies the request from the stored order even when the cart has changed`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 10)
        val otherProductId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val command = command(userId, "mock:timeout")

        val first = checkoutCoordinator.checkout(command)
        assertThat(first.outcome).isEqualTo(CheckoutOutcome.PENDING_CONFIRMATION)

        // The cart is now completely different from the one that was reserved. If the
        // retry derived its fingerprint from the cart it would see a different request
        // and reject a legitimate retry.
        cartRepository.clear(userId)
        cartRepository.increment(userId, otherProductId, 7)

        val retry = checkoutCoordinator.checkout(command)

        assertThat(retry.outcome).isEqualTo(CheckoutOutcome.PENDING_CONFIRMATION)
        assertThat(retry.order.id).isEqualTo(first.order.id)

        cleanup(userId, productId)
        deleteProduct(otherProductId)
    }

    @Test
    fun `a pending attempt is resumed rather than charged again`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val command = command(userId, "mock:success")

        // A reservation whose charge never got recorded: the process died between the
        // gateway call and T2.
        val reserved = reservationService.reserve(command)
        assertThat(attemptFor(reserved.order.id).status).isEqualTo(PaymentAttemptStatus.PENDING)

        val resumed = checkoutCoordinator.checkout(command)

        assertThat(resumed.outcome).isEqualTo(CheckoutOutcome.PAID)
        assertThat(resumed.order.id).isEqualTo(reserved.order.id)
        assertThat(resumed.order.status).isEqualTo(OrderStatus.PENDING)
        // No second reservation was made, so the stock moved once.
        assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(7)
        assertThat(attemptCountFor(command.idempotencyKey)).isEqualTo(1)

        cleanup(userId, productId)
    }

    @Test
    fun `a recorded success with an unfinalised order is durable and recovered by a retry`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val command = command(userId, "mock:success")

        // T1 and T2 run; T3 is deliberately skipped, which is what a crash between
        // them looks like.
        val reserved = reservationService.reserve(command)
        paymentResultService.record(
            reserved.paymentAttemptId,
            ChargePaymentResult(ChargePaymentStatus.SUCCESS, "external-durable")
        )

        // The evidence that money was taken survives on its own.
        val stranded = jdbcTemplate.queryForMap(
            """
            SELECT a.status AS attempt_status, a.external_payment_id, o.status AS order_status
            FROM payment_attempts a JOIN orders o ON o.id = a.order_id
            WHERE a.id = ?
            """.trimIndent(),
            reserved.paymentAttemptId
        )
        assertThat(stranded["attempt_status"]).isEqualTo("SUCCESS")
        assertThat(stranded["external_payment_id"]).isEqualTo("external-durable")
        assertThat(stranded["order_status"]).isEqualTo("PAYMENT_PENDING")

        // This is exactly the reconciliation query an operator would run.
        val strandedCount = jdbcTemplate.queryForObject(
            """
            SELECT COUNT(*) FROM payment_attempts a JOIN orders o ON o.id = a.order_id
            WHERE a.status = 'SUCCESS' AND o.status = 'PAYMENT_PENDING' AND a.id = ?
            """.trimIndent(),
            Int::class.java,
            reserved.paymentAttemptId
        )
        assertThat(strandedCount).isEqualTo(1)

        // A retry finishes the job without charging again.
        val recovered = checkoutCoordinator.checkout(command)

        assertThat(recovered.outcome).isEqualTo(CheckoutOutcome.PAID)
        assertThat(recovered.order.status).isEqualTo(OrderStatus.PENDING)
        assertThat(cartRepository.findAll(userId)).isEmpty()

        cleanup(userId, productId)
    }

    @Test
    fun `concurrent retries finalise and restore stock exactly once`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val command = command(userId, "mock:declined")
        val threads = 4
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(threads)
        val failures = AtomicInteger()

        try {
            val futures = List(threads) {
                executor.submit<CheckoutOutcome?> {
                    start.await()
                    try {
                        checkoutCoordinator.checkout(command).outcome
                    } catch (_: ApplicationException) {
                        failures.incrementAndGet()
                        null
                    }
                }
            }
            start.countDown()
            val outcomes = futures.map { it.get(20, TimeUnit.SECONDS) }

            assertThat(failures.get()).isZero()
            assertThat(outcomes).allMatch { it == CheckoutOutcome.DECLINED }
            // One reservation, one compensation: the stock is whole, not inflated.
            assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(10)
            assertThat(attemptCountFor(command.idempotencyKey)).isEqualTo(1)
            assertThat(orderCountFor(userId)).isEqualTo(1)
        } finally {
            executor.shutdownNow()
            cleanup(userId, productId)
        }
    }

    @Test
    fun `concurrent first requests keep exactly one reservation`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val command = command(userId, "mock:success")
        val threads = 4
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(threads)

        try {
            val futures = List(threads) {
                executor.submit<CheckoutOutcome?> {
                    start.await()
                    runCatching { checkoutCoordinator.checkout(command).outcome }.getOrNull()
                }
            }
            start.countDown()
            val outcomes = futures.map { it.get(20, TimeUnit.SECONDS) }

            assertThat(outcomes).allMatch { it == CheckoutOutcome.PAID }
            // Losers of the unique-key race roll back their reservation entirely, so
            // only one order exists and only three units left the shelf.
            assertThat(orderCountFor(userId)).isEqualTo(1)
            assertThat(attemptCountFor(command.idempotencyKey)).isEqualTo(1)
            assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(7)
        } finally {
            executor.shutdownNow()
            cleanup(userId, productId)
        }
    }

    // --- D. known limitation -----------------------------------------------------

    @Test
    fun `a crash between finalisation and cart cleanup leaves a stale cart but correct money`() {
        val userId = uniqueUserId()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val command = command(userId, "mock:success")

        // T1, T2 and T3 run; T4 does not. That is the crash window.
        val reserved = reservationService.reserve(command)
        paymentResultService.record(
            reserved.paymentAttemptId,
            ChargePaymentResult(ChargePaymentStatus.SUCCESS, "external-stale-cart")
        )
        val finalized = finalizeService.finalize(
            requireNotNull(reserved.order.id),
            PaymentAttemptStatus.SUCCESS
        )
        assertThat(finalized.changed).isTrue()

        val retry = checkoutCoordinator.checkout(command)

        // Documented limitation: the retry finds the order already finalised, so it
        // skips cleanup and the reserved line stays in the cart.
        assertThat(cartRepository.findAll(userId)).containsExactly(CartItem(productId, 3))

        // Everything that costs money is still correct.
        assertThat(retry.outcome).isEqualTo(CheckoutOutcome.PAID)
        assertThat(retry.order.status).isEqualTo(OrderStatus.PENDING)
        assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(7)
        assertThat(attemptCountFor(command.idempotencyKey)).isEqualTo(1)
        assertThat(attemptFor(retry.order.id).status).isEqualTo(PaymentAttemptStatus.SUCCESS)

        cleanup(userId, productId)
    }

    // --- helpers ------------------------------------------------------------------

    private fun command(
        userId: Long,
        paymentMethodId: String,
        idempotencyKey: String = "checkout-${UUID.randomUUID()}"
    ) = CheckoutCommand(
        userId = userId,
        shippingAddress = SHIPPING_ADDRESS,
        paymentMethodId = paymentMethodId,
        idempotencyKey = idempotencyKey
    )

    private fun attemptFor(orderId: Long?) = requireNotNull(
        jdbcTemplate.queryForObject(
            "SELECT idempotency_key FROM payment_attempts WHERE order_id = ? ORDER BY id LIMIT 1",
            String::class.java,
            orderId
        )?.let { paymentAttemptRepository.findByIdempotencyKey(it) }
    ) { "No payment attempt for order $orderId" }

    private fun attemptCountFor(idempotencyKey: String): Int = requireNotNull(
        jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM payment_attempts WHERE idempotency_key = ?",
            Int::class.java,
            idempotencyKey
        )
    )

    private fun orderCountFor(userId: Long): Int = requireNotNull(
        jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM orders WHERE user_id = ?", Int::class.java, userId
        )
    )

    private fun newProduct(stock: Int): Long = productRepository.create(
        Product(
            id = null,
            name = "checkout-${UUID.randomUUID()}",
            price = 1_000L,
            stockQuantity = stock,
            imageUrl = null,
            description = null,
            active = true
        )
    )

    private fun cleanup(userId: Long, productId: Long) {
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
        deleteProduct(productId)
    }

    private fun deleteProduct(productId: Long) {
        jdbcTemplate.update("DELETE FROM products WHERE id = ?", productId)
    }

    private fun uniqueUserId(): Long = USER_IDS.incrementAndGet().toLong()

    companion object {
        private val USER_IDS = AtomicInteger(900_000)
        private val FINGERPRINT = "c".repeat(64)

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
