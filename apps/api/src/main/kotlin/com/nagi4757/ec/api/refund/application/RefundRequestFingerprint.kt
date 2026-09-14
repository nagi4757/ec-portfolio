package com.nagi4757.ec.api.refund.application

import java.nio.charset.StandardCharsets
import java.security.MessageDigest

/**
 * Identity of a refund request, used to decide whether a reused idempotency key
 * describes the same refund or a different one.
 *
 * Every input is server-side state: the order, the charge being reversed, and the
 * amount that charge actually took. Nothing here comes from the request body, so a
 * client cannot vary the fingerprint to make a different refund look like a retry.
 */
object RefundRequestFingerprint {
    private const val FORMAT_VERSION = "v1"

    fun from(orderId: Long, paymentAttemptId: Long, amountJpy: Long): String {
        val canonical = buildString {
            append(FORMAT_VERSION)
            append("|orderId:").append(orderId)
            append("|paymentAttemptId:").append(paymentAttemptId)
            append("|amountJpy:").append(amountJpy)
        }

        return MessageDigest.getInstance("SHA-256")
            .digest(canonical.toByteArray(StandardCharsets.UTF_8))
            .joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }
}
