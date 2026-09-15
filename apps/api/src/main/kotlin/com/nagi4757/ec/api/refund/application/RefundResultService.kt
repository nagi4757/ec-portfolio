package com.nagi4757.ec.api.refund.application

import com.nagi4757.ec.api.payment.application.RefundPaymentResult
import com.nagi4757.ec.api.payment.application.RefundPaymentStatus
import com.nagi4757.ec.api.refund.domain.model.RefundAttemptStatus
import com.nagi4757.ec.api.refund.domain.repository.AppliedRefundResult
import com.nagi4757.ec.api.refund.domain.repository.RefundAttemptRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Propagation
import org.springframework.transaction.annotation.Transactional

/**
 * R2. Records what the provider said about the refund, and nothing else.
 *
 * Kept small and separate from the business finalisation that follows: if cancelling
 * the order later fails, the fact that money was returned is already committed,
 * leaving a REFUNDED attempt against an order still in REFUND_PENDING for an
 * operator to reconcile. One combined transaction would roll that record back and
 * lose the only evidence of the refund.
 *
 * A separate bean so the boundary goes through the Spring proxy.
 */
@Service
class RefundResultService(
    private val refundAttemptRepository: RefundAttemptRepository
) {
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    fun record(refundAttemptId: Long, result: RefundPaymentResult): AppliedRefundResult {
        val status = when (result.status) {
            RefundPaymentStatus.REFUNDED -> RefundAttemptStatus.REFUNDED
            RefundPaymentStatus.REFUND_FAILED -> RefundAttemptStatus.FAILED
            RefundPaymentStatus.REFUND_UNKNOWN -> RefundAttemptStatus.UNKNOWN
        }

        return refundAttemptRepository.applyResult(
            id = refundAttemptId,
            status = status,
            externalRefundId = result.externalRefundId
        )
    }
}
