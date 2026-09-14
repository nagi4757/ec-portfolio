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
