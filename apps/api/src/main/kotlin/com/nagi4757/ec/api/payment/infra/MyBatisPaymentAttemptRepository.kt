package com.nagi4757.ec.api.payment.infra

import com.nagi4757.ec.api.payment.domain.model.PaymentAttempt
import com.nagi4757.ec.api.payment.domain.model.PaymentAttemptStatus
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
        amountJpy: Long
    ): PaymentAttempt {
        val pending = PaymentAttempt(
            id = null,
            idempotencyKey = idempotencyKey,
            requestFingerprint = requestFingerprint,
            amountJpy = amountJpy,
            status = PaymentAttemptStatus.PENDING,
            externalPaymentId = null,
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

    override fun updateResult(
        id: Long,
        status: PaymentAttemptStatus,
        externalPaymentId: String?
    ): Boolean {
        require(status != PaymentAttemptStatus.PENDING) { "Payment result status must not be PENDING" }
        return mapper.updatePaymentAttemptResult(id, status.name, externalPaymentId) == 1
    }

    private fun PaymentAttempt.toRecord() = PaymentAttemptRecord(
        id = id,
        idempotencyKey = idempotencyKey,
        requestFingerprint = requestFingerprint,
        amountJpy = amountJpy,
        status = status.name,
        externalPaymentId = externalPaymentId,
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
        createdAt = createdAt,
        updatedAt = updatedAt
    )
}
