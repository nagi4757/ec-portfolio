package com.nagi4757.ec.api.integration

import com.nagi4757.ec.api.cart.domain.repository.CartRepository
import com.nagi4757.ec.api.checkout.application.CheckoutCommand
import com.nagi4757.ec.api.checkout.application.CheckoutCoordinator
import com.nagi4757.ec.api.checkout.application.CheckoutOutcome
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApplicationException
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.model.ShippingAddress
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.payment.application.RefundPaymentResult
import com.nagi4757.ec.api.payment.application.RefundPaymentStatus
import com.nagi4757.ec.api.payment.domain.repository.PaymentAttemptRepository
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import com.nagi4757.ec.api.refund.application.RefundCommand
import com.nagi4757.ec.api.refund.application.RefundCoordinator
import com.nagi4757.ec.api.refund.application.RefundFinalizeService
import com.nagi4757.ec.api.refund.application.RefundOutcome
import com.nagi4757.ec.api.refund.application.RefundRequestService
import com.nagi4757.ec.api.refund.application.RefundResultService
import com.nagi4757.ec.api.refund.application.RefundStartOutcome
import com.nagi4757.ec.api.refund.domain.model.RefundAttemptStatus
import com.nagi4757.ec.api.refund.domain.repository.RefundAttemptRepository
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.testcontainers.service.connection.ServiceConnection
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

/**
 * The refund contract against real MariaDB and Redis.
 *
 * The invariants here only hold if the database enforces them: the order row lock
 * that serialises customer and operator, the unique refund key, the conditional
 * transitions that make stock restoration exactly-once, and the CHECK that a
 * completed refund carries a provider reference.
 */
@Tag("integration")
@Testcontainers
@SpringBootTest
@ActiveProfiles("integration-test")
class RefundOrchestrationIntegrationTest @Autowired constructor(
    private val jdbcTemplate: JdbcTemplate,
    private val productRepository: ProductRepository,
    private val orderRepository: OrderRepository,
    private val paymentAttemptRepository: PaymentAttemptRepository,
    private val refundAttemptRepository: RefundAttemptRepository,
    private val cartRepository: CartRepository,
    private val checkoutCoordinator: CheckoutCoordinator,
    private val refundCoordinator: RefundCoordinator,
    private val refundRequestService: RefundRequestService,
    private val refundResultService: RefundResultService,
    private val refundFinalizeService: RefundFinalizeService
) {
    // --- 1. refund SUCCESS --------------------------------------------------------

    @Test
    fun `a successful refund cancels the order and restores stock exactly once`() {
        val fixture = paidOrder(stock = 10, quantity = 3)

        val result = refundCoordinator.refund(refundCommand(fixture))

        assertThat(result.outcome).isEqualTo(RefundOutcome.REFUNDED)
        assertThat(result.order.status).isEqualTo(OrderStatus.CANCELLED)
        assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(10)

        val attempt = requireNotNull(refundAttemptRepository.findActiveByOrderId(fixture.orderId)
            ?: refundAttemptRepository.findByIdempotencyKey(fixture.refundKey))
        assertThat(attempt.status).isEqualTo(RefundAttemptStatus.REFUNDED)
        assertThat(attempt.externalRefundId).isNotBlank()
        // The refunded amount came from the settled charge, not from any request.
        assertThat(attempt.amountJpy).isEqualTo(fixture.chargedAmount)

        cleanup(fixture)
    }

    // --- 2. refund FAILED ---------------------------------------------------------

    @Test
    fun `a refused refund puts the order back and leaves stock alone`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        forceFailedRefund(fixture)

        // The coordinator reports the outcome; turning FAILED into a 409 is the
        // controller's job, the same split checkout uses.
        val result = refundCoordinator.refund(refundCommand(fixture))

        assertThat(result.outcome).isEqualTo(RefundOutcome.FAILED)
        // Back to exactly where it was, not cancelled, and the goods stay committed.
        assertThat(result.order.status).isEqualTo(OrderStatus.PENDING)
        assertThat(orderRepository.findById(fixture.orderId)?.status).isEqualTo(OrderStatus.PENDING)
        assertThat(attemptFor(fixture).status).isEqualTo(RefundAttemptStatus.FAILED)
        assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(7)

        cleanup(fixture)
    }

    // --- 3. refund TIMEOUT / unknown ----------------------------------------------

    @Test
    fun `an unresolved refund holds the order instead of cancelling it`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        forceUnknownRefund(fixture)

        val result = refundCoordinator.refund(refundCommand(fixture))

        assertThat(result.outcome).isEqualTo(RefundOutcome.PENDING_CONFIRMATION)
        // Never cancelled on a guess: the money may not have moved.
        assertThat(result.order.status).isEqualTo(OrderStatus.REFUND_PENDING)
        assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(7)
        assertThat(attemptFor(fixture).status).isEqualTo(RefundAttemptStatus.UNKNOWN)

        cleanup(fixture)
    }

    // --- 4. same key retry ---------------------------------------------------------

    @Test
    fun `replaying a settled refund changes nothing and does not restore stock twice`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        val command = refundCommand(fixture)

        val first = refundCoordinator.refund(command)
        assertThat(first.outcome).isEqualTo(RefundOutcome.REFUNDED)
        assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(10)

        val replay = refundCoordinator.refund(command)

        assertThat(replay.outcome).isEqualTo(RefundOutcome.REFUNDED)
        assertThat(replay.order.status).isEqualTo(OrderStatus.CANCELLED)
        assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(10)
        assertThat(refundCountFor(fixture.refundKey)).isEqualTo(1)

        cleanup(fixture)
    }

    // --- 5. refund succeeded, finalisation failed ---------------------------------

    @Test
    fun `a recorded refund with an unfinalised order is durable and recovered by a retry`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        val command = refundCommand(fixture)

        // R1 and R2 run; R3 is skipped, which is what a crash between them looks like.
        val started = refundRequestService.start(command) as RefundStartOutcome.Started
        refundResultService.record(
            requireNotNull(started.attempt.id),
            RefundPaymentResult(RefundPaymentStatus.REFUNDED, "mock-refund:crash-window")
        )

        // The evidence that money went back survives on its own.
        val stranded = jdbcTemplate.queryForMap(
            """
            SELECT r.status AS refund_status, r.external_refund_id, o.status AS order_status
            FROM refund_attempts r JOIN orders o ON o.id = r.order_id
            WHERE r.id = ?
            """.trimIndent(),
            started.attempt.id
        )
        assertThat(stranded["refund_status"]).isEqualTo("REFUNDED")
        assertThat(stranded["external_refund_id"]).isEqualTo("mock-refund:crash-window")
        assertThat(stranded["order_status"]).isEqualTo("REFUND_PENDING")
        assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(7)

        val chargesBefore = refundCallCount()
        val recovered = refundCoordinator.refund(command)

        // The provider is not called again: the attempt is terminal, so the retry only
        // finishes the business side.
        assertThat(refundCallCount()).isEqualTo(chargesBefore)
        assertThat(recovered.outcome).isEqualTo(RefundOutcome.REFUNDED)
        assertThat(recovered.order.status).isEqualTo(OrderStatus.CANCELLED)
        assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(10)

        // And a further retry must not restore the stock a second time.
        refundCoordinator.refund(command)
        assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(10)

        cleanup(fixture)
    }

    // --- 6. concurrent cancel / refund --------------------------------------------

    @Test
    fun `customer and operator refunds contend for one order and only one runs`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(4)

        try {
            val futures = List(4) { index ->
                executor.submit<ApiErrorCode?> {
                    start.await()
                    try {
                        refundCoordinator.refund(
                            RefundCommand(
                                orderId = fixture.orderId,
                                // Half act as the customer, half as an operator; both
                                // paths must contend for the same order row.
                                userId = if (index % 2 == 0) fixture.userId else null,
                                idempotencyKey = "concurrent-${index}-${UUID.randomUUID()}"
                            )
                        )
                        null
                    } catch (exception: ApplicationException) {
                        exception.errorCode
                    }
                }
            }
            start.countDown()
            val results = futures.map { it.get(30, TimeUnit.SECONDS) }

            // Exactly one refund may run. A loser is told either that a refund is in
            // progress, or -- if the winner already settled and cancelled the order
            // before this thread took the lock -- that the order is no longer
            // refundable. Both are correct refusals; which one depends on timing.
            assertThat(results.count { it == null }).isEqualTo(1)
            assertThat(results.filterNotNull()).allMatch {
                it == ApiErrorCode.REFUND_ATTEMPT_IN_PROGRESS || it == ApiErrorCode.REFUND_NOT_ELIGIBLE
            }
            assertThat(results.filterNotNull()).hasSize(3)
            // One refund, one restoration.
            assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(10)
            assertThat(refundCountForOrder(fixture.orderId)).isEqualTo(1)
        } finally {
            executor.shutdownNow()
            cleanup(fixture)
        }
    }

    // --- 7. already cancelled ------------------------------------------------------

    @Test
    fun `an already cancelled order cannot be refunded again`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        refundCoordinator.refund(refundCommand(fixture))

        val refused = assertThrows<ApplicationException> {
            refundCoordinator.refund(
                RefundCommand(fixture.orderId, fixture.userId, "second-${UUID.randomUUID()}")
            )
        }

        assertThat(refused.errorCode).isEqualTo(ApiErrorCode.REFUND_NOT_ELIGIBLE)
        assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(10)

        cleanup(fixture)
    }

    // --- 8 and 9. states with no settled charge ------------------------------------

    @Test
    fun `a reserved order cannot be refunded because its payment is unresolved`() {
        val userId = newUser()
        val productId = newProduct(stock = 10)
        cartRepository.increment(userId, productId, 3)
        val reserved = checkoutCoordinator.checkout(
            CheckoutCommand(userId, SHIPPING_ADDRESS, "mock:timeout", "reserve-${UUID.randomUUID()}")
        )
        assertThat(reserved.order.status).isEqualTo(OrderStatus.PAYMENT_PENDING)

        val refused = assertThrows<ApplicationException> {
            refundCoordinator.refund(
                RefundCommand(requireNotNull(reserved.order.id), userId, "r-${UUID.randomUUID()}")
            )
        }

        assertThat(refused.errorCode).isEqualTo(ApiErrorCode.REFUND_NOT_ELIGIBLE)
        assertThat(orderRepository.findById(requireNotNull(reserved.order.id))?.status)
            .isEqualTo(OrderStatus.PAYMENT_PENDING)

        cleanupOrder(userId, productId)
    }

    @Test
    fun `a legacy unpaid order is not refundable because no money was taken`() {
        val userId = newUser()
        jdbcTemplate.update(
            "INSERT INTO orders (user_id, status, total_amount) VALUES (?, 'LEGACY_UNPAID', ?)",
            userId,
            10_000L
        )
        val orderId = requireNotNull(jdbcTemplate.queryForObject("SELECT LAST_INSERT_ID()", Long::class.java))

        val refused = assertThrows<ApplicationException> {
            refundCoordinator.refund(RefundCommand(orderId, userId, "legacy-${UUID.randomUUID()}"))
        }

        assertThat(refused.errorCode).isEqualTo(ApiErrorCode.REFUND_NOT_ELIGIBLE)
        assertThat(OrderStatus.LEGACY_UNPAID.isRefundable()).isFalse()
        // It is cancellable directly instead: there is nothing to refund.
        assertThat(OrderStatus.LEGACY_UNPAID.isUserCancellable()).isTrue()

        jdbcTemplate.update("DELETE FROM orders WHERE id = ?", orderId)
        jdbcTemplate.update("DELETE FROM users WHERE id = ?", userId)
    }

    // --- 10. operator path ----------------------------------------------------------

    @Test
    fun `an operator can refund without owning the order`() {
        val fixture = paidOrder(stock = 10, quantity = 3)

        val result = refundCoordinator.refund(
            RefundCommand(fixture.orderId, userId = null, idempotencyKey = fixture.refundKey)
        )

        assertThat(result.outcome).isEqualTo(RefundOutcome.REFUNDED)
        assertThat(result.order.status).isEqualTo(OrderStatus.CANCELLED)

        cleanup(fixture)
    }

    @Test
    fun `another customer cannot refund an order or learn anything about it`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        val intruder = newUser()

        val refused = assertThrows<ApplicationException> {
            refundCoordinator.refund(
                RefundCommand(fixture.orderId, intruder, "intruder-${UUID.randomUUID()}")
            )
        }

        assertThat(refused.errorCode).isEqualTo(ApiErrorCode.ORDER_NOT_FOUND)
        assertThat(refused.message).doesNotContain(SHIPPING_ADDRESS.recipientName)
        assertThat(orderRepository.findById(fixture.orderId)?.status).isEqualTo(OrderStatus.PENDING)

        jdbcTemplate.update("DELETE FROM users WHERE id = ?", intruder)
        cleanup(fixture)
    }

    // --- eligibility limits ---------------------------------------------------------

    @Test
    fun `shipped and delivered orders are refused, because the goods are not back`() {
        listOf(OrderStatus.SHIPPED, OrderStatus.DELIVERED).forEach { status ->
            val fixture = paidOrder(stock = 10, quantity = 3)
            jdbcTemplate.update("UPDATE orders SET status = ? WHERE id = ?", status.name, fixture.orderId)

            val refused = assertThrows<ApplicationException> {
                refundCoordinator.refund(refundCommand(fixture))
            }

            assertThat(refused.errorCode).isEqualTo(ApiErrorCode.REFUND_NOT_ELIGIBLE)
            // Restoring stock here would claim goods are on the shelf while a customer
            // holds them; returning those needs a return workflow.
            assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(7)

            cleanup(fixture)
        }
    }

    @Test
    fun `a refund in progress blocks shipping`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        forceUnknownRefund(fixture)
        refundCoordinator.refund(refundCommand(fixture))

        assertThat(orderRepository.findById(fixture.orderId)?.status).isEqualTo(OrderStatus.REFUND_PENDING)
        assertThat(OrderStatus.REFUND_PENDING.canTransitionTo(OrderStatus.PREPARING)).isFalse()
        assertThat(OrderStatus.REFUND_PENDING.canTransitionTo(OrderStatus.SHIPPED)).isFalse()

        cleanup(fixture)
    }

    // --- schema ----------------------------------------------------------------------

    @Test
    fun `V12 applied and the database refuses a refund without a provider reference`() {
        val applied = jdbcTemplate.queryForList(
            "SELECT version, success FROM flyway_schema_history WHERE version = '12'"
        )
        assertThat(applied).hasSize(1)
        assertThat(applied.single()["success"].toString()).isIn("1", "true")

        val fixture = paidOrder(stock = 10, quantity = 3)
        val started = refundRequestService.start(refundCommand(fixture)) as RefundStartOutcome.Started

        assertThrows<org.springframework.dao.DataIntegrityViolationException> {
            jdbcTemplate.update(
                "UPDATE refund_attempts SET status = 'REFUNDED', external_refund_id = NULL WHERE id = ?",
                started.attempt.id
            )
        }

        cleanup(fixture)
    }


    // --- review findings: H-1, H-2, H-3, M-5, M-2 ---------------------------------

    @Test
    fun `an order may hold only one successful charge`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        val chargeId = requireNotNull(paymentAttemptRepository.findSuccessfulByOrderId(fixture.orderId)?.id)

        // Retries that never settled, or settled badly, are legitimate and may repeat.
        listOf("PENDING", "FAILED", "TIMEOUT", "DECLINED").forEach { status ->
            jdbcTemplate.update(
                """
                INSERT INTO payment_attempts (idempotency_key, request_fingerprint, amount_jpy, status, order_id)
                VALUES (?, ?, ?, ?, ?)
                """.trimIndent(),
                "retry-${'$'}status-${UUID.randomUUID()}", FINGERPRINT, 1_000L, status, fixture.orderId
            )
        }

        // A second settled charge is not: the refund amount and payment reference
        // would stop being well defined.
        assertThrows<org.springframework.dao.DuplicateKeyException> {
            jdbcTemplate.update(
                """
                INSERT INTO payment_attempts (idempotency_key, request_fingerprint, amount_jpy, status, order_id, external_payment_id)
                VALUES (?, ?, ?, 'SUCCESS', ?, 'mock-payment:second')
                """.trimIndent(),
                "second-success-${UUID.randomUUID()}", FINGERPRINT, 1_000L, fixture.orderId
            )
        }
        // Promoting one of the retries is refused for the same reason.
        assertThrows<org.springframework.dao.DuplicateKeyException> {
            jdbcTemplate.update(
                """
                UPDATE payment_attempts SET status = 'SUCCESS', external_payment_id = 'mock-payment:promoted'
                WHERE order_id = ? AND id <> ?
                """.trimIndent(),
                fixture.orderId, chargeId
            )
        }

        cleanup(fixture)
    }

    @Test
    fun `a refund reverses the charge it was opened against, not whatever the order holds`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        val attempt = refundRequestService.start(refundCommand(fixture)) as RefundStartOutcome.Started
        val chargeId = requireNotNull(paymentAttemptRepository.findSuccessfulByOrderId(fixture.orderId)?.id)

        // The stored link is what the refund follows.
        assertThat(attempt.attempt.paymentAttemptId).isEqualTo(chargeId)

        // Point the attempt at a charge belonging to a different order. The stored
        // fingerprint covers paymentAttemptId, so this is caught before the provider
        // is ever reached.
        val other = paidOrder(stock = 10, quantity = 1)
        val otherChargeId = requireNotNull(paymentAttemptRepository.findSuccessfulByOrderId(other.orderId)?.id)
        jdbcTemplate.update(
            "UPDATE refund_attempts SET payment_attempt_id = ? WHERE id = ?",
            otherChargeId, attempt.attempt.id
        )

        val refused = assertThrows<ApplicationException> { refundCoordinator.refund(refundCommand(fixture)) }
        assertThat(refused.errorCode).isEqualTo(ApiErrorCode.REFUND_IDEMPOTENCY_CONFLICT)
        assertThat(orderRepository.findById(fixture.orderId)?.status).isEqualTo(OrderStatus.REFUND_PENDING)

        jdbcTemplate.update(
            "UPDATE refund_attempts SET payment_attempt_id = ? WHERE id = ?",
            chargeId, attempt.attempt.id
        )
        cleanup(other)
        cleanup(fixture)
    }

    @Test
    fun `a charge that no longer belongs to the order stops the refund`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        val started = refundRequestService.start(refundCommand(fixture)) as RefundStartOutcome.Started

        // A bare order with no settled charge of its own: V13 correctly refuses to
        // give an order a second SUCCESS, so the charge is moved somewhere free.
        val strayUser = newUser()
        jdbcTemplate.update(
            "INSERT INTO orders (user_id, status, total_amount) VALUES (?, 'PENDING', ?)",
            strayUser, 1_000L
        )
        val strayOrderId = requireNotNull(
            jdbcTemplate.queryForObject("SELECT LAST_INSERT_ID()", Long::class.java)
        )

        // Move the charge itself, leaving the refund's stored id and fingerprint
        // untouched. Only resolveCharge's own consistency checks can notice this, and
        // they must stop the refund rather than return money against a payment that
        // is no longer this order's.
        jdbcTemplate.update(
            "UPDATE payment_attempts SET order_id = ? WHERE id = ?",
            strayOrderId, started.attempt.paymentAttemptId
        )

        assertThrows<IllegalStateException> { refundCoordinator.refund(refundCommand(fixture)) }
        assertThat(orderRepository.findById(fixture.orderId)?.status).isEqualTo(OrderStatus.REFUND_PENDING)

        jdbcTemplate.update(
            "UPDATE payment_attempts SET order_id = ? WHERE id = ?",
            fixture.orderId, started.attempt.paymentAttemptId
        )
        jdbcTemplate.update("DELETE FROM orders WHERE id = ?", strayOrderId)
        jdbcTemplate.update("DELETE FROM users WHERE id = ?", strayUser)
        cleanup(fixture)
    }

    @Test
    fun `a stored fingerprint that no longer matches is refused`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        val started = refundRequestService.start(refundCommand(fixture)) as RefundStartOutcome.Started

        // Tamper with the amount the refund was opened for. The fingerprint check is
        // what notices; without it the refund would proceed against a changed value.
        jdbcTemplate.update(
            "UPDATE refund_attempts SET amount_jpy = amount_jpy + 1 WHERE id = ?",
            started.attempt.id
        )

        val refused = assertThrows<ApplicationException> { refundCoordinator.refund(refundCommand(fixture)) }

        assertThat(refused.errorCode).isEqualTo(ApiErrorCode.REFUND_IDEMPOTENCY_CONFLICT)
        assertThat(orderRepository.findById(fixture.orderId)?.status).isEqualTo(OrderStatus.REFUND_PENDING)

        cleanup(fixture)
    }

    @Test
    fun `a pending refund that is refused restores the original order status`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        forceFailedRefund(fixture)

        val result = refundCoordinator.refund(refundCommand(fixture))

        assertThat(result.outcome).isEqualTo(RefundOutcome.FAILED)
        assertThat(attemptFor(fixture).status).isEqualTo(RefundAttemptStatus.FAILED)
        assertThat(orderRepository.findById(fixture.orderId)?.status).isEqualTo(OrderStatus.PENDING)
        assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(7)

        cleanup(fixture)
    }

    @Test
    fun `an unresolved refund is never turned into a failure by a later answer`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        forceUnknownRefund(fixture)
        val first = refundCoordinator.refund(refundCommand(fixture))
        assertThat(first.outcome).isEqualTo(RefundOutcome.PENDING_CONFIRMATION)

        val attemptId = requireNotNull(attemptFor(fixture).id)
        val applied = refundResultService.record(
            attemptId,
            RefundPaymentResult(RefundPaymentStatus.REFUND_FAILED)
        )

        // The money may already have gone back, so a later failure describes the
        // retry, not the original refund. Accepting it would restore a paid order
        // the customer has already been repaid for.
        assertThat(applied.applied).isFalse()
        assertThat(applied.attempt.status).isEqualTo(RefundAttemptStatus.UNKNOWN)
        assertThat(orderRepository.findById(fixture.orderId)?.status).isEqualTo(OrderStatus.REFUND_PENDING)
        assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(7)

        cleanup(fixture)
    }

    @Test
    fun `an unresolved refund can still settle as refunded`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        forceUnknownRefund(fixture)
        refundCoordinator.refund(refundCommand(fixture))
        val attemptId = requireNotNull(attemptFor(fixture).id)

        val applied = refundResultService.record(
            attemptId,
            RefundPaymentResult(RefundPaymentStatus.REFUNDED, "mock-refund:late")
        )
        assertThat(applied.applied).isTrue()

        val finalized = refundFinalizeService.finalize(applied.attempt)

        assertThat(finalized.changed).isTrue()
        assertThat(finalized.order.status).isEqualTo(OrderStatus.CANCELLED)
        assertThat(productRepository.findById(fixture.productId)?.stockQuantity).isEqualTo(10)

        cleanup(fixture)
    }

    @Test
    fun `an unresolved reply cannot erase a refund reference already recorded`() {
        val fixture = paidOrder(stock = 10, quantity = 3)
        val started = refundRequestService.start(refundCommand(fixture)) as RefundStartOutcome.Started
        val attemptId = requireNotNull(started.attempt.id)

        refundResultService.record(attemptId, RefundPaymentResult(RefundPaymentStatus.REFUND_UNKNOWN, "mock-refund:partial"))
        assertThat(attemptFor(fixture).externalRefundId).isEqualTo("mock-refund:partial")

        val applied = refundResultService.record(attemptId, RefundPaymentResult(RefundPaymentStatus.REFUND_UNKNOWN, null))

        assertThat(applied.attempt.externalRefundId).isEqualTo("mock-refund:partial")

        cleanup(fixture)
    }

    @Test
    fun `the database refuses a refund opened from a non refundable status`() {
        val fixture = paidOrder(stock = 10, quantity = 3)

        assertThrows<org.springframework.dao.DataIntegrityViolationException> {
            jdbcTemplate.update(
                """
                INSERT INTO refund_attempts
                    (idempotency_key, request_fingerprint, order_id, payment_attempt_id,
                     amount_jpy, status, order_status_before)
                VALUES (?, ?, ?, ?, ?, 'PENDING', 'SHIPPED')
                """.trimIndent(),
                "bad-before-${UUID.randomUUID()}",
                FINGERPRINT,
                fixture.orderId,
                requireNotNull(paymentAttemptRepository.findSuccessfulByOrderId(fixture.orderId)?.id),
                1_000L
            )
        }

        cleanup(fixture)
    }

    @Test
    fun `V13 applied`() {
        val applied = jdbcTemplate.queryForList(
            "SELECT version, success FROM flyway_schema_history WHERE version = '13'"
        )
        assertThat(applied).hasSize(1)
        assertThat(applied.single()["success"].toString()).isIn("1", "true")
    }

    // --- helpers ----------------------------------------------------------------------

    private class Fixture(
        val userId: Long,
        val productId: Long,
        val orderId: Long,
        val refundKey: String,
        val chargedAmount: Long
    )

    /** A paid order: the only starting point a refund accepts. */
    private fun paidOrder(
        stock: Int,
        quantity: Int,
        paymentMethod: String = "mock:success"
    ): Fixture {
        val userId = newUser()
        val productId = newProduct(stock = stock)
        cartRepository.increment(userId, productId, quantity)

        val paid = checkoutCoordinator.checkout(
            CheckoutCommand(userId, SHIPPING_ADDRESS, paymentMethod, "pay-${UUID.randomUUID()}")
        )
        check(paid.outcome == CheckoutOutcome.PAID) { "Fixture checkout did not settle: ${paid.outcome}" }
        val orderId = requireNotNull(paid.order.id)

        return Fixture(
            userId = userId,
            productId = productId,
            orderId = orderId,
            refundKey = "refund-${UUID.randomUUID()}",
            chargedAmount = requireNotNull(paymentAttemptRepository.findSuccessfulByOrderId(orderId)).amountJpy
        )
    }

    private fun refundCommand(fixture: Fixture) =
        RefundCommand(fixture.orderId, fixture.userId, fixture.refundKey)

    /**
     * Points the order's charge at the payment id the mock gateway answers with an
     * unresolved refund, so the unknown branch can be driven end to end.
     */
    private fun forceUnknownRefund(fixture: Fixture) = pointChargeAt(fixture, "mock:refund-unknown")

    /** The mock gateway refuses to refund any payment id it does not recognise. */
    private fun forceFailedRefund(fixture: Fixture) = pointChargeAt(fixture, "mock:refund-failed")

    private fun pointChargeAt(fixture: Fixture, externalPaymentId: String) {
        jdbcTemplate.update(
            "UPDATE payment_attempts SET external_payment_id = ? WHERE order_id = ?",
            externalPaymentId,
            fixture.orderId
        )
    }

    private fun attemptFor(fixture: Fixture) =
        requireNotNull(refundAttemptRepository.findByIdempotencyKey(fixture.refundKey))

    private fun refundCountFor(key: String): Int = requireNotNull(
        jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM refund_attempts WHERE idempotency_key = ?", Int::class.java, key
        )
    )

    private fun refundCountForOrder(orderId: Long): Int = requireNotNull(
        jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM refund_attempts WHERE order_id = ?", Int::class.java, orderId
        )
    )

    /**
     * Settled refund attempts, used as the observable proxy for provider calls: every
     * refund that returns writes exactly one.
     */
    private fun refundCallCount(): Int = requireNotNull(
        jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM refund_attempts WHERE status <> 'PENDING'", Int::class.java
        )
    )

    private fun newUser(): Long {
        jdbcTemplate.update(
            "INSERT INTO users (email, password_hash, name, role) VALUES (?, 'x', 'Test', 'USER')",
            "refund-${UUID.randomUUID()}@example.test"
        )
        return requireNotNull(jdbcTemplate.queryForObject("SELECT LAST_INSERT_ID()", Long::class.java))
    }

    private fun newProduct(stock: Int): Long = productRepository.create(
        Product(
            id = null,
            name = "refund-${UUID.randomUUID()}",
            price = 1_000L,
            stockQuantity = stock,
            imageUrl = null,
            description = null,
            active = true
        )
    )

    private fun cleanup(fixture: Fixture) = cleanupOrder(fixture.userId, fixture.productId)

    private fun cleanupOrder(userId: Long, productId: Long) {
        cartRepository.clear(userId)
        jdbcTemplate.update(
            "DELETE FROM refund_attempts WHERE order_id IN (SELECT id FROM orders WHERE user_id = ?)",
            userId
        )
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
        jdbcTemplate.update("DELETE FROM products WHERE id = ?", productId)
    }

    private companion object {
        /** A syntactically valid fingerprint for rows inserted directly by a test. */
        val FINGERPRINT = "c".repeat(64)

        val SHIPPING_ADDRESS = ShippingAddress(
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
