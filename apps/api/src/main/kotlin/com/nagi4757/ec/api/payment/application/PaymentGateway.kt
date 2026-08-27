package com.nagi4757.ec.api.payment.application

interface PaymentGateway {
    fun charge(request: ChargePaymentRequest): ChargePaymentResult
    fun refund(request: RefundPaymentRequest): RefundPaymentResult
}
