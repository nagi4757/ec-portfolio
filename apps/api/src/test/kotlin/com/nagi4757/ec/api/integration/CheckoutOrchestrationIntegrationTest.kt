package com.nagi4757.ec.api.integration

import com.nagi4757.ec.api.cart.domain.model.CartItem
import com.nagi4757.ec.api.cart.domain.repository.CartRepository
import com.nagi4757.ec.api.checkout.application.CheckoutCommand
import com.nagi4757.ec.api.checkout.application.CheckoutCoordinator
import com.nagi4757.ec.api.checkout.application.CheckoutFinalizeService
import com.nagi4757.ec.api.checkout.application.CheckoutOutcome
import com.nagi4757.ec.api.checkout.application.CheckoutReservationService
import com.nagi4757.ec.api.checkout.application.ReserveOutcome
import com.nagi4757.ec.api.checkout.application.ReservedCheckout
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
        val reserved = reserveOrFail(command(userId, "mock:success"))

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
        val orderId = reserveOrFail(command(userId, "mock:success")).order.id

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
        val orderId = requireNotNull(reserveOrFail(command(userId, "mock:success")).order.id)
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
        val orderId = requireNotNull(reserveOrFail(command(userId, "mock:success")).order.id)

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
        val reserved = reserveOrFail(command)
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
        val reserved = reserveOrFail(command)
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
                executor.submit<CheckoutCallResult> {
                    start.await()
                    callCheckout(command)
                }
            }
            start.countDown()
            val results = futures.map { it.get(20, TimeUnit.SECONDS) }

            // Every caller gets the same checkout's result. None may fail: a duplicate
            // submit is a replay, whatever the cart looks like by the time it is
            // served. EMPTY_CART here would mean idempotency was decided from cart
            // state instead of from the key.
            assertThat(results).allSatisfy { outcome ->
                assertThat(outcome.error).isNull()
                assertThat(outcome.thrown).isNull()
                assertThat(outcome.outcome).isEqualTo(CheckoutOutcome.PAID)
                assertThat(outcome.orderId).isEqualTo(results.first().orderId)
            }
            // One reservation: one order, one attempt, three units off the shelf.
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
        val reserved = reserveOrFail(command)
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


    // --- E. active checkout guard (server side) ---------------------------------

    @Test
    fun `a second key is refused while the customer has an unresolved charge`() {
        val userId = newUser()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)

        val first = checkoutCoordinator.checkout(command(userId, "mock:timeout"))
        assertThat(first.outcome).isEqualTo(CheckoutOutcome.PENDING_CONFIRMATION)

        val chargesBefore = chargeCount()
        val refused = assertThrows<ApplicationException> {
            checkoutCoordinator.checkout(command(userId, "mock:success"))
        }

        assertThat(refused.errorCode).isEqualTo(ApiErrorCode.PAYMENT_ATTEMPT_IN_PROGRESS)
        // The decisive assertion: the second key never reached the gateway, so the
        // customer cannot be charged twice.
        assertThat(chargeCount()).isEqualTo(chargesBefore)
        assertThat(orderCountFor(userId)).isEqualTo(1)

        cleanup(userId, productId)
    }

    @Test
    fun `simultaneous different keys start at most one charge`() {
        val userId = newUser()
        val productId = newProduct(stock = 20)
        cartRepository.increment(userId, productId, 3)
        val threads = 4
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(threads)
        val chargesBefore = chargeCount()

        try {
            val futures = List(threads) { index ->
                executor.submit<ApiErrorCode?> {
                    start.await()
                    try {
                        checkoutCoordinator.checkout(
                            command(userId, "mock:timeout", "distinct-key-$index-${UUID.randomUUID()}")
                        )
                        null
                    } catch (exception: ApplicationException) {
                        exception.errorCode
                    }
                }
            }
            start.countDown()
            val results = futures.map { it.get(30, TimeUnit.SECONDS) }

            // The charge is left unresolved on purpose: the guard is about payments
            // that may still be in flight. Exactly one request may proceed; the rest
            // are told a payment is already in progress, and the user row lock is what
            // makes that decision reliable.
            assertThat(results.count { it == null }).isEqualTo(1)
            assertThat(results.count { it == ApiErrorCode.PAYMENT_ATTEMPT_IN_PROGRESS })
                .isEqualTo(threads - 1)
            assertThat(chargeCount() - chargesBefore).isEqualTo(1)
            assertThat(orderCountFor(userId)).isEqualTo(1)
        } finally {
            executor.shutdownNow()
            cleanup(userId, productId)
        }
    }

    @Test
    fun `the loser of a same-key race resumes the winner instead of failing on stock`() {
        val userId = newUser()
        // Stock is exactly what the cart holds, so a second reservation could not
        // succeed even if one were attempted.
        val productId = newProduct(stock = 3)
        cartRepository.increment(userId, productId, 3)
        val command = command(userId, "mock:success")
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)

        try {
            val futures = List(2) {
                executor.submit<Pair<CheckoutOutcome?, ApiErrorCode?>> {
                    start.await()
                    try {
                        checkoutCoordinator.checkout(command).outcome to null
                    } catch (exception: ApplicationException) {
                        null to exception.errorCode
                    }
                }
            }
            start.countDown()
            val results = futures.map { it.get(30, TimeUnit.SECONDS) }

            // Both see the same settled payment. Neither is told the shelf is empty:
            // the guard resumes the winner's attempt rather than reserving again.
            assertThat(results.map { it.second }).containsOnlyNulls()
            assertThat(results.map { it.first }).allMatch { it == CheckoutOutcome.PAID }
            assertThat(orderCountFor(userId)).isEqualTo(1)
            assertThat(attemptCountFor(command.idempotencyKey)).isEqualTo(1)
            assertThat(productRepository.findById(productId)?.stockQuantity).isZero()
        } finally {
            executor.shutdownNow()
            cleanup(userId, productId)
        }
    }

    // --- F. retry ownership and fingerprint -------------------------------------

    @Test
    fun `another account cannot use a key and learns nothing about the order`() {
        val owner = newUser()
        val intruder = newUser()
        val productId = newProduct(stock = 10)
        cartRepository.increment(owner, productId, 3)
        val key = "owned-${UUID.randomUUID()}"

        val paid = checkoutCoordinator.checkout(command(owner, "mock:success", key))
        assertThat(paid.outcome).isEqualTo(CheckoutOutcome.PAID)

        val refused = assertThrows<ApplicationException> {
            checkoutCoordinator.checkout(command(intruder, "mock:success", key))
        }

        // A conflict, not the owner's order: the response must not leak the address,
        // the items, or even that the key belongs to someone.
        assertThat(refused.errorCode).isEqualTo(ApiErrorCode.PAYMENT_IDEMPOTENCY_CONFLICT)
        assertThat(refused.message).doesNotContain(SHIPPING_ADDRESS.recipientName)
        assertThat(refused.message).doesNotContain(SHIPPING_ADDRESS.phoneNumber)
        assertThat(orderCountFor(intruder)).isZero()

        cleanup(owner, productId)
    }

    @Test
    fun `a changed shipping address on the same key is refused`() {
        val userId = newUser()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val key = "addr-${UUID.randomUUID()}"

        checkoutCoordinator.checkout(command(userId, "mock:timeout", key))

        val moved = CheckoutCommand(
            userId = userId,
            shippingAddress = SHIPPING_ADDRESS.copy(addressLine1 = "千代田9-9"),
            paymentMethodId = "mock:timeout",
            idempotencyKey = key
        )
        val refused = assertThrows<ApplicationException> { checkoutCoordinator.checkout(moved) }

        assertThat(refused.errorCode).isEqualTo(ApiErrorCode.PAYMENT_IDEMPOTENCY_CONFLICT)

        cleanup(userId, productId)
    }

    @Test
    fun `a changed payment method on the same key is refused`() {
        val userId = newUser()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val key = "method-${UUID.randomUUID()}"

        checkoutCoordinator.checkout(command(userId, "mock:timeout", key))

        val refused = assertThrows<ApplicationException> {
            checkoutCoordinator.checkout(command(userId, "mock:success", key))
        }

        assertThat(refused.errorCode).isEqualTo(ApiErrorCode.PAYMENT_IDEMPOTENCY_CONFLICT)

        cleanup(userId, productId)
    }

    @Test
    fun `a changed cart alone still resumes, because the order snapshot decides`() {
        val userId = newUser()
        val productId = newProduct(stock = 10)
        val otherProductId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val key = "cart-${UUID.randomUUID()}"

        val first = checkoutCoordinator.checkout(command(userId, "mock:timeout", key))
        assertThat(first.outcome).isEqualTo(CheckoutOutcome.PENDING_CONFIRMATION)

        cartRepository.clear(userId)
        cartRepository.increment(userId, otherProductId, 7)

        val resumed = checkoutCoordinator.checkout(command(userId, "mock:timeout", key))

        assertThat(resumed.outcome).isEqualTo(CheckoutOutcome.PENDING_CONFIRMATION)
        assertThat(resumed.order.id).isEqualTo(first.order.id)

        cleanup(userId, productId)
        deleteProduct(otherProductId)
    }

    // --- G. SUCCESS invariant ----------------------------------------------------

    @Test
    fun `the database refuses a success without a provider reference`() {
        val userId = newUser()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 1)
        val orderId = requireNotNull(reserveOrFail(command(userId, "mock:success")).order.id)
        val attempt = paymentAttemptRepository.createPending(
            "invariant-${UUID.randomUUID()}", FINGERPRINT, 10_000L, orderId
        )

        assertThrows<DataIntegrityViolationException> {
            jdbcTemplate.update(
                "UPDATE payment_attempts SET status = 'SUCCESS', external_payment_id = NULL WHERE id = ?",
                attempt.id
            )
        }
        assertThrows<DataIntegrityViolationException> {
            jdbcTemplate.update(
                "UPDATE payment_attempts SET status = 'SUCCESS', external_payment_id = '  ' WHERE id = ?",
                attempt.id
            )
        }

        cleanup(userId, productId)
    }

    // --- H. cart delete then re-add ----------------------------------------------

    @Test
    fun `cleanup leaves a re-added line alone rather than deleting it`() {
        val userId = newUser()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)

        // The customer empties the line and puts two back while the payment runs.
        cartRepository.remove(userId, productId)
        cartRepository.increment(userId, productId, 2)

        val remaining = cartRepository.removeSnapshotQuantity(userId, productId, 3)

        // The two units were chosen after checkout and must survive. A stale line is
        // the lesser evil; deleting a customer's items is not recoverable by them.
        assertThat(remaining).isEqualTo(2)
        assertThat(cartRepository.findAll(userId)).containsExactly(CartItem(productId, 2))

        cleanup(userId, productId)
    }

    // --- I. legacy unpaid orders ---------------------------------------------------

    @Test
    fun `V11 moved pre-checkout orders out of the paid lifecycle`() {
        val applied = jdbcTemplate.queryForList(
            "SELECT version, success FROM flyway_schema_history WHERE version = '11'"
        )
        assertThat(applied).hasSize(1)
        assertThat(applied.single()["success"].toString()).isIn("1", "true")

        // A legacy order: PENDING with no payment attempt behind it.
        val userId = newUser()
        jdbcTemplate.update(
            "INSERT INTO orders (user_id, status, total_amount) VALUES (?, 'LEGACY_UNPAID', ?)",
            userId,
            10_000L
        )
        val orderId = requireNotNull(
            jdbcTemplate.queryForObject("SELECT LAST_INSERT_ID()", Long::class.java)
        )

        // It must never reach the shipping pipeline.
        assertThat(OrderStatus.LEGACY_UNPAID.canTransitionTo(OrderStatus.PREPARING)).isFalse()
        assertThat(OrderStatus.LEGACY_UNPAID.canTransitionTo(OrderStatus.CANCELLED)).isTrue()
        // No payment was taken, so no refund is owed.
        assertThat(OrderStatus.LEGACY_UNPAID.isPaid()).isFalse()
        assertThat(OrderStatus.LEGACY_UNPAID.isUserCancellable()).isTrue()

        assertThat(orderRepository.findById(orderId)?.status).isEqualTo(OrderStatus.LEGACY_UNPAID)

        jdbcTemplate.update("DELETE FROM orders WHERE id = ?", orderId)
    }

    // --- idempotency is decided from the key, never from cart state ---------------

    /** One call's observable result, including the failure it produced if any. */
    private data class CheckoutCallResult(
        val outcome: CheckoutOutcome?,
        val orderId: Long?,
        val error: ApiErrorCode?,
        val thrown: Throwable? = null
    )

    private fun callCheckout(command: CheckoutCommand): CheckoutCallResult = try {
        val result = checkoutCoordinator.checkout(command)
        CheckoutCallResult(result.outcome, result.order.id, null)
    } catch (exception: ApplicationException) {
        CheckoutCallResult(null, null, exception.errorCode, exception)
    } catch (exception: RuntimeException) {
        CheckoutCallResult(null, null, null, exception)
    }

    @Test
    fun `reserve re-reads the key under the lock instead of trusting a stale lookup`() {
        // This is the stale state from the race, made deterministic.
        //
        // The coordinator looks the key up before queuing on the user lock. A request
        // that finds nothing there, then waits, reaches reserve() holding an answer
        // that is already wrong: whoever held the lock may have created the attempt or
        // carried it to a settled outcome. Calling reserve() directly is exactly that
        // situation -- it is the state the coordinator's fast path would have skipped.
        //
        // Before the fix, reserve() only asked for *unsettled* attempts, so a settled
        // same-key attempt was invisible and the request walked into a fresh checkout,
        // failing on the cart the first request had already cleared.
        val userId = newUser()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val command = command(userId, "mock:success")

        val first = checkoutCoordinator.checkout(command)
        assertThat(first.outcome).isEqualTo(CheckoutOutcome.PAID)
        assertThat(cartRepository.findAll(userId)).isEmpty()
        assertThat(attemptFor(first.order.id).status).isEqualTo(PaymentAttemptStatus.SUCCESS)

        val outcome = reservationService.reserve(command)

        assertThat(outcome).isInstanceOf(ReserveOutcome.Existing::class.java)
        assertThat((outcome as ReserveOutcome.Existing).attempt.idempotencyKey)
            .isEqualTo(command.idempotencyKey)
        assertThat(outcome.attempt.orderId).isEqualTo(first.order.id)
        // No second reservation: the stock stays where the first checkout left it.
        assertThat(orderCountFor(userId)).isEqualTo(1)
        assertThat(attemptCountFor(command.idempotencyKey)).isEqualTo(1)
        assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(7)

        cleanup(userId, productId)
    }

    @Test
    fun `a refilled cart does not turn a duplicate submit into a second order`() {
        val userId = newUser()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val command = command(userId, "mock:success")

        val first = checkoutCoordinator.checkout(command)
        assertThat(first.outcome).isEqualTo(CheckoutOutcome.PAID)

        // The customer puts the product back in the basket, then the original request
        // is retried. A non-empty cart must not make the key look new either.
        cartRepository.increment(userId, productId, 2)

        // Directly, again: a non-empty cart must not make a known key look new.
        val outcome = reservationService.reserve(command)
        assertThat(outcome).isInstanceOf(ReserveOutcome.Existing::class.java)

        assertThat((outcome as ReserveOutcome.Existing).attempt.orderId).isEqualTo(first.order.id)
        assertThat(orderCountFor(userId)).isEqualTo(1)
        assertThat(attemptCountFor(command.idempotencyKey)).isEqualTo(1)
        // Only the original three units left the shelf, and the new line survives.
        assertThat(productRepository.findById(productId)?.stockQuantity).isEqualTo(7)
        assertThat(cartRepository.findAll(userId)).containsExactly(CartItem(productId, 2))

        cleanup(userId, productId)
    }

    // --- helpers ------------------------------------------------------------------

    /** Unwraps the happy path of the guarded reservation. */
    private fun reserveOrFail(command: CheckoutCommand): ReservedCheckout =
        when (val outcome = reservationService.reserve(command)) {
            is ReserveOutcome.Reserved -> outcome.reservation
            is ReserveOutcome.Existing -> error("Expected a fresh reservation")
        }

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
        jdbcTemplate.update("DELETE FROM users WHERE id = ?", userId)
        deleteProduct(productId)
    }

    private fun deleteProduct(productId: Long) {
        jdbcTemplate.update("DELETE FROM products WHERE id = ?", productId)
    }

    /**
     * A real users row. Checkout locks the user FOR UPDATE, so a synthetic id would
     * skip the serialisation the active-checkout guard depends on.
     */
    private fun uniqueUserId(): Long = newUser()

    private fun newUser(): Long {
        val email = "checkout-${UUID.randomUUID()}@example.test"
        jdbcTemplate.update(
            "INSERT INTO users (email, password_hash, name, role) VALUES (?, 'x', 'Test', 'USER')",
            email
        )
        return requireNotNull(jdbcTemplate.queryForObject("SELECT LAST_INSERT_ID()", Long::class.java))
    }

    /**
     * How many charges the gateway has settled. Counting recorded attempts is the
     * closest observable proxy: every charge that returns writes exactly one.
     */
    private fun chargeCount(): Int = requireNotNull(
        jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM payment_attempts WHERE status <> 'PENDING'", Int::class.java
        )
    )

    companion object {
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
