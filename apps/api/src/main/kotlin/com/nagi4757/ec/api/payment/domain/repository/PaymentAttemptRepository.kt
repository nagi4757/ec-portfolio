package com.nagi4757.ec.api.payment.domain.repository

import com.nagi4757.ec.api.payment.domain.model.PaymentAttempt
import com.nagi4757.ec.api.payment.domain.model.PaymentAttemptStatus

interface PaymentAttemptRepository {
    fun createPending(
        idempotencyKey: String,
        requestFingerprint: String,
        amountJpy: Long
    ): PaymentAttempt

    fun findByIdempotencyKey(idempotencyKey: String): PaymentAttempt?

    fun updateResult(
        id: Long,
        status: PaymentAttemptStatus,
        externalPaymentId: String?
    ): Boolean
}
