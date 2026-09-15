package com.nagi4757.ec.api.order.domain.model

enum class OrderStatus {
    /**
     * An order created before checkout existed, when orders could be placed without
     * paying. It is not part of the paid lifecycle: it must never be prepared or
     * shipped, and because no payment was ever taken, cancelling one owes nobody a
     * refund.
     */
    LEGACY_UNPAID,

    /**
     * Reserved: stock is held and a payment attempt exists, but the payment outcome
     * is not yet established. An order must never be prepared or shipped from here.
     */
    PAYMENT_PENDING,

    /** Paid. Awaiting seller handling. */
    PENDING,
    PREPARING,
    SHIPPED,
    DELIVERED,
    CANCELLED;

    /**
     * Operator and customer facing transitions.
     *
     * Cancellation of a paid order is deliberately absent: money has already been
     * captured, so cancelling without a refund would leave the customer charged for
     * nothing. Refund orchestration is a separate phase, and until it exists the
     * paid states fail closed.
     *
     * PAYMENT_PENDING is absent for the opposite reason: the payment outcome is
     * unresolved, so no operator decision can be correct yet.
     */
    fun canTransitionTo(target: OrderStatus): Boolean = when (this) {
        // Never shippable: nobody paid for it.
        LEGACY_UNPAID -> target == CANCELLED
        PAYMENT_PENDING -> false
        PENDING -> target == PREPARING
        PREPARING -> target == SHIPPED
        SHIPPED -> target == DELIVERED
        DELIVERED, CANCELLED -> false
    }

    /**
     * Internal compensation, used when a charge did not succeed. Expressed as its
     * own rule rather than bypassing [canTransitionTo], so the one case where an
     * order may still be cancelled stays visible and testable.
     *
     * No refund is required here: the payment was never established.
     */
    fun canCompensateTo(target: OrderStatus): Boolean =
        this == PAYMENT_PENDING && target == CANCELLED

    /**
     * True once money has been captured for this order.
     *
     * LEGACY_UNPAID is excluded on purpose: those orders predate checkout and carry
     * no payment attempt, so the refund-required rule does not apply to them.
     */
    fun isPaid(): Boolean = this == PENDING ||
        this == PREPARING ||
        this == SHIPPED ||
        this == DELIVERED

    /**
     * Direct customer cancellation is only possible for an unpaid legacy order. A
     * reserved order has an unresolved payment, and a paid order needs a refund.
     */
    fun isUserCancellable(): Boolean = this == LEGACY_UNPAID
}
