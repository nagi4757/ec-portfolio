package com.nagi4757.ec.api.order.application.query

interface OrderQueryRepository {
    fun findSummariesByUserId(userId: Long): List<OrderSummary>
    fun findSummaryPage(page: Int, size: Int): OrderSummaryPage
}
