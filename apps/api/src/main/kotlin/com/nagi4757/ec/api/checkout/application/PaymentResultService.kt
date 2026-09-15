package com.nagi4757.ec.api.checkout.application

import com.nagi4757.ec.api.payment.application.ChargePaymentResult
import com.nagi4757.ec.api.payment.application.ChargePaymentStatus
import com.nagi4757.ec.api.payment.application.toPersistedAttemptStatus
import com.nagi4757.ec.api.payment.domain.repository.AppliedPaymentResult
import com.nagi4757.ec.api.payment.domain.repository.PaymentAttemptRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Propagation
import org.springframework.transaction.annotation.Transactional

/**
 * T2. Records what the gateway said, and nothing else.
 *
 * This transaction is kept deliberately small and separate from the business
 * finalisation that follows. If confirming the order later fails, the fact that
 * money was taken is already committed, leaving a SUCCESS attempt against a
 * still-reserved order -- a state an operator can find and reconcile. Folding both
 * into one transaction would roll the payment record back and lose that evidence.
 *
 * It is a separate bean rather than a private method so the transaction boundary
 * goes through the Spring proxy. A self-invoked @Transactional call would silently
 * join the caller's context and defeat the whole arrangement.
 */
@Service
class PaymentResultService(
    private val paymentAttemptRepository: PaymentAttemptRepository
) {
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    fun record(paymentAttemptId: Long, result: ChargePaymentResult): AppliedPaymentResult {
        val status = result.status.toPersistedAttemptStatus()
            ?: error("Gateway reported ${ChargePaymentStatus.DUPLICATE}, which has no persisted status")

        return paymentAttemptRepository.applyResult(
            id = paymentAttemptId,
            status = status,
            externalPaymentId = result.externalPaymentId
        )
    }
}
