package com.nagi4757.ec.api.payment.application

import java.nio.charset.StandardCharsets
import java.security.MessageDigest

object PaymentRequestFingerprint {
    private const val FORMAT_VERSION = "v1"

    fun from(request: ChargePaymentRequest): String {
        val paymentMethodBytes = request.paymentMethodId.toByteArray(StandardCharsets.UTF_8)
        val canonicalRequest = buildString {
            append(FORMAT_VERSION)
            append('|')
            append("amountJpy:")
            append(request.amountJpy)
            append('|')
            append("paymentMethodId:")
            append(paymentMethodBytes.size)
            append(':')
            append(request.paymentMethodId)
        }
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(canonicalRequest.toByteArray(StandardCharsets.UTF_8))

        return digest.joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }
}
