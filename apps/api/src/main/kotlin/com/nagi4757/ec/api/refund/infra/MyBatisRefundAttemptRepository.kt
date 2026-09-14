package com.nagi4757.ec.api.refund.infra

import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.refund.domain.model.RefundAttempt
import com.nagi4757.ec.api.refund.domain.model.RefundAttemptStatus
import com.nagi4757.ec.api.refund.domain.repository.AppliedRefundResult
import com.nagi4757.ec.api.refund.domain.repository.RefundAttemptRepository
import com.nagi4757.ec.api.refund.infra.mapper.RefundAttemptMapper
import com.nagi4757.ec.api.refund.infra.mapper.RefundAttemptRecord
import org.springframework.stereotype.Repository

@Repository
class MyBatisRefundAttemptRepository(
    private val mapper: RefundAttemptMapper
) : RefundAttemptRepository {
    override fun createPending(
        idempotencyKey: String,
        requestFingerprint: String,
        orderId: Long,
        paymentAttemptId: Long,
        amountJpy: Long,
        orderStatusBefore: OrderStatus
    ): RefundAttempt {
        val record = RefundAttemptRecord(
            idempotencyKey = idempotencyKey,
            requestFingerprint = requestFingerprint,
            orderId = orderId,
            paymentAttemptId = paymentAttemptId,
            amountJpy = amountJpy,
            status = RefundAttemptStatus.PENDING.name,
            externalRefundId = null,
            orderStatusBefore = orderStatusBefore.name
        )
        check(mapper.insertRefundAttempt(record) == 1) { "Failed to create refund attempt" }

        return mapper.selectByIdempotencyKey(idempotencyKey)?.toDomain()
            ?: error("Created refund attempt could not be reloaded")
    }

    override fun findByIdempotencyKey(idempotencyKey: String): RefundAttempt? =
        mapper.selectByIdempotencyKey(idempotencyKey)?.toDomain()

    override fun findActiveByOrderId(orderId: Long): RefundAttempt? =
        mapper.selectActiveByOrderId(orderId)?.toDomain()

    override fun applyResult(
        id: Long,
        status: RefundAttemptStatus,
        externalRefundId: String?
    ): AppliedRefundResult {
        require(status != RefundAttemptStatus.PENDING) { "Refund result status must not be PENDING" }

        // The statement only matches a non-terminal attempt. Zero rows means another
        // writer settled it first, so the stored outcome wins and this caller adopts
        // it rather than overwriting it or failing.
        val applied = mapper.updateRefundAttemptResult(id, status.name, externalRefundId) == 1
        val attempt = mapper.selectById(id)?.toDomain()
            ?: error("Refund attempt $id could not be reloaded")

        return AppliedRefundResult(attempt = attempt, applied = applied)
    }

    private fun RefundAttemptRecord.toDomain() = RefundAttempt(
        id = id,
        idempotencyKey = idempotencyKey,
        requestFingerprint = requestFingerprint,
        orderId = orderId,
        paymentAttemptId = paymentAttemptId,
        amountJpy = amountJpy,
        status = RefundAttemptStatus.valueOf(status),
        externalRefundId = externalRefundId,
        orderStatusBefore = OrderStatus.valueOf(orderStatusBefore),
        createdAt = createdAt,
        updatedAt = updatedAt
    )
}
