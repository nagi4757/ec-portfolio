package com.nagi4757.ec.api.order.domain.model

enum class OrderStatus {
    PENDING,
    PREPARING,
    SHIPPED,
    DELIVERED,
    CANCELLED;

    fun canTransitionTo(target: OrderStatus): Boolean = when (this) {
        PENDING -> target == PREPARING || target == CANCELLED
        PREPARING -> target == SHIPPED || target == CANCELLED
        SHIPPED -> target == DELIVERED
        DELIVERED, CANCELLED -> false
    }

    fun isUserCancellable(): Boolean = this == PENDING
}
