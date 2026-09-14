package com.nagi4757.ec.api.payment.infra

import com.nagi4757.ec.api.payment.domain.model.PaymentAttempt
import com.nagi4757.ec.api.payment.domain.model.PaymentAttemptStatus
import com.nagi4757.ec.api.payment.domain.repository.AppliedPaymentResult
import com.nagi4757.ec.api.payment.domain.repository.PaymentAttemptRepository
import com.nagi4757.ec.api.payment.infra.mapper.PaymentAttemptMapper
import com.nagi4757.ec.api.payment.infra.mapper.PaymentAttemptRecord
import org.springframework.stereotype.Repository

@Repository
class MyBatisPaymentAttemptRepository(
    private val mapper: PaymentAttemptMapper
) : PaymentAttemptRepository {
    override fun createPending(
        idempotencyKey: String,
        requestFingerprint: String,
        amountJpy: Long,
        orderId: Long
    ): PaymentAttempt {
        val pending = PaymentAttempt(
            id = null,
            idempotencyKey = idempotencyKey,
            requestFingerprint = requestFingerprint,
            amountJpy = amountJpy,
            status = PaymentAttemptStatus.PENDING,
            externalPaymentId = null,
            orderId = orderId,
            createdAt = null,
            updatedAt = null
        )
        val record = pending.toRecord()
        check(mapper.insertPaymentAttempt(record) == 1) { "Failed to create payment attempt" }

        return mapper.selectByIdempotencyKey(idempotencyKey)?.toDomain()
            ?: error("Created payment attempt could not be reloaded")
    }

    override fun findByIdempotencyKey(idempotencyKey: String): PaymentAttempt? =
        mapper.selectByIdempotencyKey(idempotencyKey)?.toDomain()

    override fun findActiveByUserId(userId: Long): PaymentAttempt? =
        mapper.selectActiveByUserId(userId)?.toDomain()

    override fun findSuccessfulByOrderId(orderId: Long): PaymentAttempt? =
        mapper.selectSuccessfulByOrderId(orderId)?.toDomain()

    override fun applyResult(
        id: Long,
        status: PaymentAttemptStatus,
        externalPaymentId: String?
    ): AppliedPaymentResult {
        require(status != PaymentAttemptStatus.PENDING) { "Payment result status must not be PENDING" }

        // The statement only matches a non-terminal attempt. Zero rows therefore
        // means another writer settled it first, so the stored outcome wins and this
        // caller adopts it rather than overwriting it or failing.
        val applied = mapper.updatePaymentAttemptResult(id, status.name, externalPaymentId) == 1
        val attempt = mapper.selectById(id)?.toDomain()
            ?: error("Payment attempt $id could not be reloaded")

        return AppliedPaymentResult(attempt = attempt, applied = applied)
    }

    private fun PaymentAttempt.toRecord() = PaymentAttemptRecord(
        id = id,
        idempotencyKey = idempotencyKey,
        requestFingerprint = requestFingerprint,
        amountJpy = amountJpy,
        status = status.name,
        externalPaymentId = externalPaymentId,
        orderId = orderId,
        createdAt = createdAt,
        updatedAt = updatedAt
    )

    private fun PaymentAttemptRecord.toDomain() = PaymentAttempt(
        id = id,
        idempotencyKey = idempotencyKey,
        requestFingerprint = requestFingerprint,
        amountJpy = amountJpy,
        status = PaymentAttemptStatus.valueOf(status),
        externalPaymentId = externalPaymentId,
        orderId = orderId,
        createdAt = createdAt,
        updatedAt = updatedAt
    )
}
