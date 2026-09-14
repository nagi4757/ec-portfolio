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

    /**
     * A refund has been requested and its outcome is not yet known. The order holds
     * here so a concurrent cancellation cannot start a second refund, and so an
     * unresolved refund never silently becomes a cancellation.
     */
    REFUND_PENDING,

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
        // Shipping an order whose refund is in flight would send goods that are
        // being paid back for.
        REFUND_PENDING -> false
        PENDING -> target == PREPARING
        PREPARING -> target == SHIPPED
        SHIPPED -> target == DELIVERED
        DELIVERED, CANCELLED -> false
    }

    /**
     * Whether a full refund and cancellation may be started from this state.
     *
     * Limited to the states where nothing has left the warehouse. Refunding a
     * SHIPPED or DELIVERED order and immediately restoring stock would claim goods
     * are back on the shelf when they are in a customer's hands; returning those
     * needs a return workflow that receives the goods first, which is out of scope
     * here.
     */
    fun isRefundable(): Boolean = this == PENDING || this == PREPARING

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
     * Where an order may go once its refund outcome is known. A refused refund puts
     * the order back where it came from; only a completed refund cancels it.
     *
     * An unknown outcome has no entry here on purpose: the order stays in
     * REFUND_PENDING for reconciliation rather than being cancelled on a guess.
     */
    fun canSettleRefundTo(target: OrderStatus): Boolean =
        this == REFUND_PENDING && (target == CANCELLED || target.isRefundable())

    /**
     * True once money has been captured for this order.
     *
     * LEGACY_UNPAID is excluded on purpose: those orders predate checkout and carry
     * no payment attempt, so the refund-required rule does not apply to them.
     */
    fun isPaid(): Boolean = this == PENDING ||
        this == PREPARING ||
        this == REFUND_PENDING ||
        this == SHIPPED ||
        this == DELIVERED

    /**
     * Direct customer cancellation is only possible for an unpaid legacy order. A
     * reserved order has an unresolved payment, and a paid order needs a refund.
     */
    fun isUserCancellable(): Boolean = this == LEGACY_UNPAID
}
