package com.nagi4757.ec.api.payment.infra

import com.nagi4757.ec.api.payment.application.ChargePaymentRequest
import com.nagi4757.ec.api.payment.application.ChargePaymentResult
import com.nagi4757.ec.api.payment.application.ChargePaymentStatus
import com.nagi4757.ec.api.payment.application.PaymentGateway
import com.nagi4757.ec.api.payment.application.RefundPaymentRequest
import com.nagi4757.ec.api.payment.application.RefundPaymentResult
import com.nagi4757.ec.api.payment.application.RefundPaymentStatus
import org.springframework.context.annotation.Profile
import org.springframework.stereotype.Component
import java.util.concurrent.ConcurrentHashMap

@Component
@Profile("local")
class MockPaymentGateway : PaymentGateway {
    private val chargesByIdempotencyKey = ConcurrentHashMap<String, StoredCharge>()
    private val refundsByIdempotencyKey = ConcurrentHashMap<String, StoredRefund>()

    override fun charge(request: ChargePaymentRequest): ChargePaymentResult {
        val fingerprint = ChargeFingerprint(request.amountJpy, request.paymentMethodId)
        var resolved: ChargePaymentResult? = null

        chargesByIdempotencyKey.compute(request.idempotencyKey) { _, existing ->
            when {
                existing == null -> StoredCharge(fingerprint, chargeResult(request))
                    .also { resolved = it.result }
                existing.fingerprint == fingerprint -> existing.also { resolved = it.result }
                else -> existing.also {
                    resolved = ChargePaymentResult(ChargePaymentStatus.DUPLICATE)
                }
            }
        }

        return requireNotNull(resolved)
    }

    override fun refund(request: RefundPaymentRequest): RefundPaymentResult {
        val fingerprint = RefundFingerprint(request.externalPaymentId, request.amountJpy)
        var resolved: RefundPaymentResult? = null

        refundsByIdempotencyKey.compute(request.idempotencyKey) { _, existing ->
            when {
                existing == null -> StoredRefund(fingerprint, refundResult(request))
                    .also { resolved = it.result }
                existing.fingerprint == fingerprint -> existing.also { resolved = it.result }
                else -> existing.also {
                    resolved = RefundPaymentResult(RefundPaymentStatus.REFUND_FAILED)
                }
            }
        }

        return requireNotNull(resolved)
    }

    private fun chargeResult(request: ChargePaymentRequest): ChargePaymentResult = when (request.paymentMethodId) {
        MOCK_SUCCESS_PAYMENT_METHOD -> ChargePaymentResult(
            status = ChargePaymentStatus.SUCCESS,
            externalPaymentId = "mock-payment:${request.idempotencyKey}"
        )
        MOCK_DECLINED_PAYMENT_METHOD -> ChargePaymentResult(ChargePaymentStatus.DECLINED)
        MOCK_FAILED_PAYMENT_METHOD -> ChargePaymentResult(ChargePaymentStatus.FAILED)
        MOCK_TIMEOUT_PAYMENT_METHOD -> ChargePaymentResult(ChargePaymentStatus.TIMEOUT)
        MOCK_DUPLICATE_PAYMENT_METHOD -> ChargePaymentResult(ChargePaymentStatus.DUPLICATE)
        else -> ChargePaymentResult(ChargePaymentStatus.FAILED)
    }

    private fun refundResult(request: RefundPaymentRequest): RefundPaymentResult = when {
        request.externalPaymentId == MOCK_REFUNDED_PAYMENT_ID ||
            request.externalPaymentId.startsWith("mock-payment:") ->
            RefundPaymentResult(RefundPaymentStatus.REFUNDED)
        else -> RefundPaymentResult(RefundPaymentStatus.REFUND_FAILED)
    }

    private data class ChargeFingerprint(val amountJpy: Long, val paymentMethodId: String)
    private data class RefundFingerprint(val externalPaymentId: String, val amountJpy: Long)
    private data class StoredCharge(val fingerprint: ChargeFingerprint, val result: ChargePaymentResult)
    private data class StoredRefund(val fingerprint: RefundFingerprint, val result: RefundPaymentResult)
}

internal const val MOCK_SUCCESS_PAYMENT_METHOD = "mock:success"
internal const val MOCK_DECLINED_PAYMENT_METHOD = "mock:declined"
internal const val MOCK_FAILED_PAYMENT_METHOD = "mock:failed"
internal const val MOCK_TIMEOUT_PAYMENT_METHOD = "mock:timeout"
internal const val MOCK_DUPLICATE_PAYMENT_METHOD = "mock:duplicate"
internal const val MOCK_REFUNDED_PAYMENT_ID = "mock:refunded"
internal const val MOCK_REFUND_FAILED_PAYMENT_ID = "mock:refund-failed"
