package com.nagi4757.ec.api.order.domain.repository

import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderStatus

interface OrderRepository {
    fun save(order: Order): Order
    fun findById(id: Long): Order?

    /**
     * Locks the order row for the current transaction and returns it.
     *
     * Refund serialises on this rather than on the customer: an admin and the
     * customer can both ask to cancel the same order, and both paths must contend
     * for the same lock so only one refund is ever started.
     */
    fun lockForUpdate(id: Long): Order?
    fun findByIdAndUserId(id: Long, userId: Long): Order?
    fun findByUserId(userId: Long): List<Order>
    fun findAll(page: Int, size: Int): OrderPage
    fun transitionStatus(id: Long, expectedStatus: OrderStatus, targetStatus: OrderStatus): Boolean
    fun transitionStatusForUser(
        id: Long,
        userId: Long,
        expectedStatus: OrderStatus,
        targetStatus: OrderStatus
    ): Boolean
}

data class OrderPage(
    val items: List<Order>,
    val page: Int,
    val size: Int,
    val total: Long,
    val totalPages: Int
)
