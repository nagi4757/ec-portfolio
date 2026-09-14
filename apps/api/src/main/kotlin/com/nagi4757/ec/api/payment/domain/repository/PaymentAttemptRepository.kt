package com.nagi4757.ec.api.payment.domain.repository

import com.nagi4757.ec.api.payment.domain.model.PaymentAttempt
import com.nagi4757.ec.api.payment.domain.model.PaymentAttemptStatus

interface PaymentAttemptRepository {
    /**
     * Inserts a pending attempt. The unique constraint on the idempotency key is the
     * authority for concurrent first requests: the loser's insert fails and its
     * surrounding transaction rolls back, leaving exactly one attempt.
     */
    fun createPending(
        idempotencyKey: String,
        requestFingerprint: String,
        amountJpy: Long,
        orderId: Long
    ): PaymentAttempt

    fun findByIdempotencyKey(idempotencyKey: String): PaymentAttempt?

    /**
     * The charge a refund recorded when it started.
     *
     * A refund resolves its charge through this stored id rather than by searching
     * the order again, so the charge it reverses is always the one it was opened
     * against.
     */
    fun findById(id: Long): PaymentAttempt?

    /**
     * The user's unsettled attempt, if any.
     *
     * PENDING and TIMEOUT both mean "a charge may be in flight". Starting a second
     * checkout while one exists risks charging the customer twice, so callers use
     * this to refuse or resume instead.
     *
     * Only meaningful while the caller holds the user lock taken in T1; without it
     * two requests can both read "no active attempt".
     */
    fun findActiveByUserId(userId: Long): PaymentAttempt?

    /**
     * The settled successful charge for an order, if one exists.
     *
     * The refund amount and the provider's payment reference are read from here and
     * never from the request: a client must not be able to choose how much it is
     * refunded, or which charge is reversed.
     */
    fun findSuccessfulByOrderId(orderId: Long): PaymentAttempt?

    /**
     * Records a gateway outcome against a non-terminal attempt and returns the
     * attempt as it now stands.
     *
     * [AppliedPaymentResult.applied] reports whether this call is the one that wrote
     * the outcome. A concurrent retry that loses the race gets `false` along with the
     * winner's attempt rather than an error, so both callers go on to act on the same
     * settled fact.
     */
    fun applyResult(
        id: Long,
        status: PaymentAttemptStatus,
        externalPaymentId: String?
    ): AppliedPaymentResult
}

data class AppliedPaymentResult(
    val attempt: PaymentAttempt,
    val applied: Boolean
)
