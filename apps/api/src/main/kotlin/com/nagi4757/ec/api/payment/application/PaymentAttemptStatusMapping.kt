package com.nagi4757.ec.api.payment.application

import com.nagi4757.ec.api.payment.domain.model.PaymentAttemptStatus

fun ChargePaymentStatus.toPersistedAttemptStatus(): PaymentAttemptStatus? = when (this) {
    ChargePaymentStatus.SUCCESS -> PaymentAttemptStatus.SUCCESS
    ChargePaymentStatus.DECLINED -> PaymentAttemptStatus.DECLINED
    ChargePaymentStatus.FAILED -> PaymentAttemptStatus.FAILED
    ChargePaymentStatus.TIMEOUT -> PaymentAttemptStatus.TIMEOUT
    ChargePaymentStatus.DUPLICATE -> null
}
