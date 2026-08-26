package com.nagi4757.ec.api.order.infra

import com.nagi4757.ec.api.order.application.query.OrderQueryRepository
import com.nagi4757.ec.api.order.application.query.OrderSummary
import com.nagi4757.ec.api.order.application.query.OrderSummaryPage
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.infra.mapper.OrderMapper
import com.nagi4757.ec.api.order.infra.mapper.OrderSummaryRecord
import org.springframework.stereotype.Repository

@Repository
class MyBatisOrderQueryRepository(
    private val mapper: OrderMapper
) : OrderQueryRepository {
    override fun findSummariesByUserId(userId: Long): List<OrderSummary> =
        mapper.selectOrderSummariesByUserId(userId).map { it.toSummary() }

    override fun findSummaryPage(page: Int, size: Int): OrderSummaryPage {
        val safePage = page.coerceAtLeast(1)
        val safeSize = size.coerceIn(1, 100)
        val total = mapper.countAllOrders()
        val items = if (total == 0L) {
            emptyList()
        } else {
            mapper.selectOrderSummaryPage((safePage - 1) * safeSize, safeSize).map { it.toSummary() }
        }
        val totalPages = if (total == 0L) 0 else ((total + safeSize - 1) / safeSize).toInt()

        return OrderSummaryPage(items, safePage, safeSize, total, totalPages)
    }

    private fun OrderSummaryRecord.toSummary() = OrderSummary(
        id = id,
        userId = userId,
        status = OrderStatus.valueOf(status),
        totalAmount = totalAmount,
        createdAt = createdAt
    )
}
