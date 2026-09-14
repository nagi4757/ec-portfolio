package com.nagi4757.ec.api.refund.application

import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.RefundIdempotencyConflictException
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.payment.application.PaymentGateway
import com.nagi4757.ec.api.payment.application.RefundPaymentRequest
import com.nagi4757.ec.api.payment.domain.model.PaymentAttempt
import com.nagi4757.ec.api.payment.domain.model.PaymentAttemptStatus
import com.nagi4757.ec.api.payment.domain.repository.PaymentAttemptRepository
import com.nagi4757.ec.api.refund.domain.model.RefundAttempt
import com.nagi4757.ec.api.refund.domain.model.RefundAttemptStatus
import com.nagi4757.ec.api.refund.domain.repository.RefundAttemptRepository
import org.slf4j.LoggerFactory
import org.springframework.dao.DuplicateKeyException
import org.springframework.stereotype.Service

/**
 * Drives a refund across three transactions and one external call.
 *
 * This class holds no transaction of its own. The provider call must not sit inside
 * one, and the three steps must commit independently so a later failure cannot roll
 * back an earlier fact. Each step is its own bean so the boundaries go through the
 * Spring proxy rather than being lost to self-invocation.
 *
 *   R1 start    locks the order, checks eligibility, opens a refund attempt
 *   refund      runs outside every transaction
 *   R2 record   makes the refund outcome durable on its own
 *   R3 finalize cancels the order and restores stock, or puts it back
 *
 * Every new refund goes through R1, which holds the order lock. A customer request
 * and an operator request therefore contend for the same row, and only one of them
 * can start a refund.
 *
 * ## Known design note: unresolved refunds and a real provider
 *
 * An UNKNOWN refund is re-driven with the same idempotency key, which the mock
 * gateway answers by replaying its stored result. A real provider may behave
 * differently: it might treat the repeated call as a fresh refund, or expose the
 * outcome only through a status lookup rather than through the refund endpoint.
 * Before a PAY.JP adapter is written, its idempotency and status-query contracts
 * must be checked and this resume path revisited; until then the durable UNKNOWN
 * attempt is what an operator reconciles from.
 */
@Service
class RefundCoordinator(
    private val requestService: RefundRequestService,
    private val resultService: RefundResultService,
    private val finalizeService: RefundFinalizeService,
    private val refundAttemptRepository: RefundAttemptRepository,
    private val paymentAttemptRepository: PaymentAttemptRepository,
    private val orderRepository: OrderRepository,
    private val paymentGateway: PaymentGateway
) {
    private val log = LoggerFactory.getLogger(javaClass)

    fun refund(command: RefundCommand): RefundResult {
        val existing = refundAttemptRepository.findByIdempotencyKey(command.idempotencyKey)
        if (existing != null) {
            return resume(command, existing)
        }

        val started = try {
            requestService.start(command)
        } catch (conflict: DuplicateKeyException) {
            // A concurrent first request won the unique key. Our transaction rolled
            // back, including the REFUND_PENDING transition, so the only thing left
            // is to adopt the winner's attempt. Reloaded here, outside any
            // transaction, rather than being papered over inside R1.
            log.info("Refund for order {} was claimed concurrently; adopting stored attempt", command.orderId)
            val winner = refundAttemptRepository.findByIdempotencyKey(command.idempotencyKey)
                ?: throw conflict
            return resume(command, winner)
        }

        return when (started) {
            is RefundStartOutcome.Existing -> resume(command, started.attempt)
            is RefundStartOutcome.Started -> drive(command, started.attempt)
        }
    }

    /**
     * Continues a refund that already has an attempt.
     *
     * Ownership is checked before anything about the order is read into a response:
     * an idempotency key is guessable, and one belonging to another customer must
     * never expose their order.
     */
    private fun resume(command: RefundCommand, attempt: RefundAttempt): RefundResult {
        val order = orderRepository.findById(attempt.orderId)
            ?: error("Order ${attempt.orderId} referenced by refund ${attempt.id} is missing")

        if (command.userId != null && order.userId != command.userId) {
            log.warn("User {} presented a refund key belonging to another account; refusing", command.userId)
            throw RefundIdempotencyConflictException()
        }
        if (attempt.orderId != command.orderId) {
            throw RefundIdempotencyConflictException()
        }

        // Recompute the fingerprint from what is persisted now and compare it with
        // what was stored when the refund opened. Storing it without ever checking
        // it would document an invariant nothing enforces; this is the check that
        // makes a key describing a different charge or amount fail closed.
        val expected = RefundRequestFingerprint.from(
            orderId = attempt.orderId,
            paymentAttemptId = attempt.paymentAttemptId,
            amountJpy = attempt.amountJpy
        )
        if (expected != attempt.requestFingerprint) {
            log.warn("Refund attempt {} no longer matches its stored fingerprint; refusing", attempt.id)
            throw RefundIdempotencyConflictException()
        }

        if (attempt.status.isTerminal()) {
            // Settled, so the provider is not called again. Finalisation still runs:
            // a previous call may have died between R2 and R3, leaving a refunded
            // order stuck in REFUND_PENDING. It is idempotent, so an ordinary replay
            // changes nothing.
            return finalizeAndReport(attempt)
        }

        // PENDING or UNKNOWN: the refund may not have been issued, or its outcome was
        // never learned. Re-driving with the same key is how it gets resolved.
        return drive(command, attempt)
    }

    private fun drive(command: RefundCommand, attempt: RefundAttempt): RefundResult {
        val charge = resolveCharge(attempt)

        val result = paymentGateway.refund(
            RefundPaymentRequest(
                // Both come from the charge this refund was opened against, never
                // from the request and never from a fresh search.
                externalPaymentId = requireNotNull(charge.externalPaymentId),
                amountJpy = charge.amountJpy,
                idempotencyKey = command.idempotencyKey
            )
        )

        val applied = resultService.record(requireNotNull(attempt.id), result)

        return finalizeAndReport(applied.attempt)
    }

    /**
     * The charge this refund was opened against, resolved through the id the attempt
     * stored rather than by searching the order again.
     *
     * Searching would let the charge being reversed drift away from the one R1
     * recorded -- a different row could sort first, or the order could acquire
     * another settled charge. Every property the refund depends on is re-checked
     * here, so a mismatch stops the refund instead of returning money against the
     * wrong payment.
     */
    private fun resolveCharge(attempt: RefundAttempt): PaymentAttempt {
        val charge = paymentAttemptRepository.findById(attempt.paymentAttemptId)
            ?: throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)

        check(charge.orderId == attempt.orderId) {
            "Refund ${attempt.id} points at charge ${charge.id}, which belongs to order ${charge.orderId}"
        }
        check(charge.status == PaymentAttemptStatus.SUCCESS) {
            "Refund ${attempt.id} points at charge ${charge.id}, which is ${charge.status}"
        }
        check(!charge.externalPaymentId.isNullOrBlank()) {
            "Charge ${charge.id} is SUCCESS without an external payment id"
        }
        check(charge.amountJpy == attempt.amountJpy) {
            "Refund ${attempt.id} was opened for ${attempt.amountJpy} but charge ${charge.id} took ${charge.amountJpy}"
        }

        return charge
    }

    private fun finalizeAndReport(attempt: RefundAttempt): RefundResult {
        val finalized = finalizeService.finalize(attempt)

        return RefundResult(order = finalized.order, outcome = attempt.status.toOutcome())
    }

    private fun RefundAttemptStatus.toOutcome(): RefundOutcome = when (this) {
        RefundAttemptStatus.REFUNDED -> RefundOutcome.REFUNDED
        RefundAttemptStatus.FAILED -> RefundOutcome.FAILED
        RefundAttemptStatus.UNKNOWN, RefundAttemptStatus.PENDING -> RefundOutcome.PENDING_CONFIRMATION
    }
}
