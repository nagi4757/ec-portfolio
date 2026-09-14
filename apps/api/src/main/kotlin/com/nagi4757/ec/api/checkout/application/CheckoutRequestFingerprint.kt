package com.nagi4757.ec.api.checkout.application

import com.nagi4757.ec.api.order.domain.model.ShippingAddress
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

/**
 * Identity of a checkout request, used to decide whether a reused idempotency key
 * describes the same request or a different one.
 *
 * Amount alone cannot identify a checkout: two carts with different products,
 * quantities or shipping addresses can total the same yen. The fingerprint
 * therefore covers everything that decides what the customer is buying and where
 * it goes.
 *
 * Every variable length field is length prefixed. Without that, "ab|c" and "a|bc"
 * would canonicalise identically and two different requests would share a
 * fingerprint. This is the same defence [com.nagi4757.ec.api.payment.application.PaymentRequestFingerprint]
 * applies at the gateway level.
 *
 * Line items are sorted by product id so that cart iteration order, which is not
 * guaranteed, cannot change the result. The same ordering must be used whether the
 * lines come from a live cart or from a stored order, because a retry recomputes
 * this value from the persisted order snapshot.
 */
object CheckoutRequestFingerprint {
    private const val FORMAT_VERSION = "v1"

    fun from(
        userId: Long,
        currency: String,
        paymentMethodId: String,
        shippingAddress: ShippingAddress,
        lines: List<CheckoutLineSnapshot>
    ): String {
        val canonical = buildString {
            append(FORMAT_VERSION)
            append("|userId:").append(userId)
            append("|currency:").appendLengthPrefixed(currency)
            append("|paymentMethodId:").appendLengthPrefixed(paymentMethodId)
            append("|ship:")
            appendLengthPrefixed(shippingAddress.recipientName)
            appendLengthPrefixed(shippingAddress.postalCode)
            appendLengthPrefixed(shippingAddress.prefecture)
            appendLengthPrefixed(shippingAddress.city)
            appendLengthPrefixed(shippingAddress.addressLine1)
            appendLengthPrefixed(shippingAddress.addressLine2 ?: "")
            appendLengthPrefixed(shippingAddress.phoneNumber)
            append("|items:").append(lines.size)
            lines.sortedBy { it.productId }.forEach { line ->
                append('|')
                append(line.productId)
                append(':')
                append(line.unitPrice)
                append(':')
                append(line.quantity)
            }
        }

        return MessageDigest.getInstance("SHA-256")
            .digest(canonical.toByteArray(StandardCharsets.UTF_8))
            .joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }

    /** Byte length, not character length: the digest is taken over UTF-8. */
    private fun StringBuilder.appendLengthPrefixed(value: String) {
        append(value.toByteArray(StandardCharsets.UTF_8).size)
        append(':')
        append(value)
        append('|')
    }
}

/**
 * One purchased line as the server resolved it. Prices come from the product
 * snapshot, never from the client.
 */
data class CheckoutLineSnapshot(
    val productId: Long,
    val unitPrice: Long,
    val quantity: Int
)
