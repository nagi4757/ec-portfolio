package com.nagi4757.ec.api.order.domain.repository

import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderStatus

interface OrderRepository {
    fun save(order: Order): Order
    fun findById(id: Long): Order?
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
