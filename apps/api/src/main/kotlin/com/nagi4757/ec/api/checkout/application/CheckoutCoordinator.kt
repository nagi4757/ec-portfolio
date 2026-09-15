package com.nagi4757.ec.api.checkout.application

import com.nagi4757.ec.api.common.error.PaymentIdempotencyConflictException
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.payment.application.ChargePaymentRequest
import com.nagi4757.ec.api.payment.application.ChargePaymentResult
import com.nagi4757.ec.api.payment.application.ChargePaymentStatus
import com.nagi4757.ec.api.payment.application.PaymentGateway
import com.nagi4757.ec.api.payment.domain.model.PaymentAttempt
import com.nagi4757.ec.api.payment.domain.model.PaymentAttemptStatus
import com.nagi4757.ec.api.payment.domain.repository.PaymentAttemptRepository
import org.slf4j.LoggerFactory
import org.springframework.dao.DuplicateKeyException
import org.springframework.stereotype.Service

/**
 * Drives a checkout across three transactions and one external call.
 *
 * This class holds no transaction of its own. The gateway call must not sit inside
 * one, and the three steps must commit independently so that a later failure cannot
 * roll back an earlier fact. Each step lives in its own bean so the boundaries go
 * through the Spring proxy rather than being lost to self-invocation.
 *
 *   T1 reserve  -> locks the customer, holds stock, writes the order and attempt
 *   charge      -> no transaction
 *   T2 record   -> the payment outcome is made durable on its own
 *   T3 finalize -> the order leaves PAYMENT_PENDING
 *   T4 cleanup  -> the reserved cart lines are subtracted, best effort
 *
 * Every checkout goes through T1, including a retry, because T1 holds the per-user
 * lock that decides whether a charge may start at all. A client-side guard cannot
 * do that job: a second tab, a browser without session storage, or a direct API call
 * would all bypass it.
 *
 * ## Known limitation: a crash between T3 and T4 leaves a stale cart
 *
 * T4 runs only when T3 was the call that moved the order, because subtracting cart
 * quantities is not idempotent. If the process dies after T3 commits but before T4
 * runs, a retry finds the order already finalised, skips T4, and the reserved lines
 * stay in the cart.
 *
 * Payment and order correctness are unaffected: the charge is recorded, the order is
 * confirmed, and the stock is right. Only the customer's cart shows lines they have
 * already bought, which they can remove.
 *
 * This is preferred over the alternative. Running T4 on every retry would subtract
 * the same quantities twice and silently delete items the customer added after
 * checking out. Closing the gap properly needs a cleanup marker or an outbox, which
 * is deliberately out of scope for this phase and recorded as future work.
 */
@Service
class CheckoutCoordinator(
    private val reservationService: CheckoutReservationService,
    private val paymentResultService: PaymentResultService,
    private val finalizeService: CheckoutFinalizeService,
    private val cartSnapshotCleaner: CartSnapshotCleaner,
    private val paymentAttemptRepository: PaymentAttemptRepository,
    private val orderRepository: OrderRepository,
    private val paymentGateway: PaymentGateway
) {
    private val log = LoggerFactory.getLogger(javaClass)

    fun checkout(command: CheckoutCommand): CheckoutResult {
        val existing = paymentAttemptRepository.findByIdempotencyKey(command.idempotencyKey)
        if (existing != null) {
            return resume(command, existing)
        }

        val outcome = try {
            reservationService.reserve(command)
        } catch (conflict: DuplicateKeyException) {
            // A concurrent first request won the unique constraint. Our whole
            // reservation rolled back, including the stock it took, so the only thing
            // left to do is adopt the winner's attempt. The reload happens here,
            // outside any transaction, rather than being papered over inside T1.
            log.info("Idempotency key {} was claimed concurrently; adopting stored attempt", command.idempotencyKey)
            val winner = paymentAttemptRepository.findByIdempotencyKey(command.idempotencyKey)
                ?: throw conflict
            return resume(command, winner)
        }

        return when (outcome) {
            // T1 found this customer's own unsettled attempt under the lock. It is the
            // same key, so this request continues it instead of starting a second one.
            is ReserveOutcome.Existing -> resume(command, outcome.attempt)
            is ReserveOutcome.Reserved -> drive(
                command = command,
                attemptId = outcome.reservation.paymentAttemptId,
                amountJpy = outcome.reservation.amountJpy,
                order = outcome.reservation.order
            )
        }
    }

    /**
     * Continues a checkout that already has an attempt.
     *
     * The line items are taken from the stored order snapshot, never from the live
     * cart: by this point the cart may have been trimmed by a successful checkout, or
     * changed by the customer while the payment was in flight, so it no longer
     * describes the request this key stands for.
     *
     * The payment method and shipping address come from the incoming request. A
     * change to either is a different purchase, and reusing the key for it must be
     * refused rather than quietly charged against the original order.
     */
    private fun resume(command: CheckoutCommand, attempt: PaymentAttempt): CheckoutResult {
        val orderId = requireNotNull(attempt.orderId) {
            "Payment attempt ${attempt.id} has no order; it was not created by checkout"
        }
        val order = orderRepository.findById(orderId)
            ?: error("Order $orderId referenced by attempt ${attempt.id} is missing")

        // Ownership is checked before anything about the order is read into a
        // response. An idempotency key is guessable, and a key belonging to another
        // customer must never expose their order, address or items. This is reported
        // as a plain conflict so the response cannot be used to probe for valid keys.
        if (order.userId != command.userId) {
            log.warn(
                "User {} presented idempotency key belonging to another account; refusing",
                command.userId
            )
            throw PaymentIdempotencyConflictException()
        }

        val fingerprint = CheckoutRequestFingerprint.from(
            userId = command.userId,
            currency = CHECKOUT_CURRENCY,
            paymentMethodId = command.paymentMethodId,
            shippingAddress = command.shippingAddress,
            lines = order.toLineSnapshots()
        )
        if (fingerprint != attempt.requestFingerprint) {
            throw PaymentIdempotencyConflictException()
        }

        if (attempt.status.isTerminal()) {
            // The charge is settled, so the gateway is not called again. Finalisation
            // still runs: a previous call may have died between T2 and T3, leaving a
            // paid order stuck in PAYMENT_PENDING. It is idempotent, so on an ordinary
            // replay it changes nothing and the cart is left alone.
            return finalizeAndReport(order, attempt.status)
        }

        // PENDING or TIMEOUT. The gateway is idempotent for this key, so re-driving
        // it replays the original result rather than charging again. This is the only
        // way a payment that was charged but never recorded gets resolved.
        return drive(
            command = command,
            attemptId = requireNotNull(attempt.id),
            amountJpy = attempt.amountJpy,
            order = order
        )
    }

    private fun drive(
        command: CheckoutCommand,
        attemptId: Long,
        amountJpy: Long,
        order: Order
    ): CheckoutResult {
        val chargeResult = paymentGateway.charge(
            ChargePaymentRequest(
                amountJpy = amountJpy,
                paymentMethodId = command.paymentMethodId,
                idempotencyKey = command.idempotencyKey
            )
        )

        val applied = paymentResultService.record(attemptId, usableResult(chargeResult, attemptId))

        return finalizeAndReport(order, applied.attempt.status)
    }

    /**
     * A SUCCESS without the provider's reference is not something we can act on: there
     * would be nothing to reconcile against and nothing to refund. Rather than record
     * an untraceable success, the attempt is left unsettled so the same key can
     * resolve it later. The stock stays held and the order stays reserved, which is
     * the same position a timeout leaves us in.
     */
    private fun usableResult(result: ChargePaymentResult, attemptId: Long): ChargePaymentResult {
        if (result.status == ChargePaymentStatus.SUCCESS && result.externalPaymentId.isNullOrBlank()) {
            log.error(
                "Gateway reported SUCCESS without an external payment id for attempt {}; " +
                    "treating the charge as unresolved so it can be reconciled",
                attemptId
            )
            return ChargePaymentResult(ChargePaymentStatus.TIMEOUT)
        }
        return result
    }

    /**
     * T3, and T4 when T3 was the call that moved the order.
     *
     * Cleanup hangs off [FinalizeOutcome.changed] rather than off the payment result,
     * because subtracting cart quantities is not idempotent: running it on a replay
     * would take the same quantities twice and remove lines the customer added after
     * checking out.
     */
    private fun finalizeAndReport(order: Order, settledStatus: PaymentAttemptStatus): CheckoutResult {
        val finalized = finalizeService.finalize(
            orderId = requireNotNull(order.id),
            attemptStatus = settledStatus
        )

        if (finalized.changed && settledStatus == PaymentAttemptStatus.SUCCESS) {
            cartSnapshotCleaner.removeReservedLines(order)
        }

        return CheckoutResult(order = finalized.order, outcome = settledStatus.toOutcome())
    }

    private fun PaymentAttemptStatus.toOutcome(): CheckoutOutcome = when (this) {
        PaymentAttemptStatus.SUCCESS -> CheckoutOutcome.PAID
        PaymentAttemptStatus.DECLINED -> CheckoutOutcome.DECLINED
        PaymentAttemptStatus.FAILED -> CheckoutOutcome.FAILED
        PaymentAttemptStatus.TIMEOUT, PaymentAttemptStatus.PENDING -> CheckoutOutcome.PENDING_CONFIRMATION
    }
}
