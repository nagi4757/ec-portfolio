package com.nagi4757.ec.api.refund.domain.repository

import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.refund.domain.model.RefundAttempt
import com.nagi4757.ec.api.refund.domain.model.RefundAttemptStatus

interface RefundAttemptRepository {
    fun createPending(
        idempotencyKey: String,
        requestFingerprint: String,
        orderId: Long,
        paymentAttemptId: Long,
        amountJpy: Long,
        orderStatusBefore: OrderStatus
    ): RefundAttempt

    fun findByIdempotencyKey(idempotencyKey: String): RefundAttempt?

    /**
     * The order's unsettled refund, if any.
     *
     * PENDING and UNKNOWN both mean a refund may be in flight. Only meaningful while
     * the caller holds the order row lock taken in R1; without it two requests can
     * both read "no refund in progress" and each start one.
     */
    fun findActiveByOrderId(orderId: Long): RefundAttempt?

    /**
     * Records a provider outcome against a non-terminal attempt and returns the
     * attempt as it now stands. [AppliedRefundResult.applied] reports whether this
     * call wrote it; a concurrent retry that loses gets `false` plus the winner's
     * attempt rather than an error.
     */
    fun applyResult(
        id: Long,
        status: RefundAttemptStatus,
        externalRefundId: String?
    ): AppliedRefundResult
}

data class AppliedRefundResult(
    val attempt: RefundAttempt,
    val applied: Boolean
)
