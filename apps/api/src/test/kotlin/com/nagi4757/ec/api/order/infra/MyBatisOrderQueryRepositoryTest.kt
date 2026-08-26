package com.nagi4757.ec.api.order.infra

import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.infra.mapper.OrderMapper
import com.nagi4757.ec.api.order.infra.mapper.OrderSummaryRecord
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.mockito.ArgumentMatchers.anyLong
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import java.time.LocalDateTime

class MyBatisOrderQueryRepositoryTest {
    private val mapper = mock(OrderMapper::class.java)
    private val repository = MyBatisOrderQueryRepository(mapper)

    @Test
    fun `findSummariesByUserId executes one summary query without loading items`() {
        val createdAt = LocalDateTime.of(2026, 8, 26, 12, 30)
        `when`(mapper.selectOrderSummariesByUserId(7L)).thenReturn(
            listOf(record(id = 2L, status = "SHIPPED", createdAt = createdAt), record(id = 1L))
        )

        val result = repository.findSummariesByUserId(7L)

        assertEquals(listOf(2L, 1L), result.map { it.id })
        assertEquals(OrderStatus.SHIPPED, result.first().status)
        assertEquals(createdAt, result.first().createdAt)
        verify(mapper).selectOrderSummariesByUserId(7L)
        verify(mapper, never()).selectItemsByOrderId(anyLong())
    }

    @Test
    fun `findSummaryPage executes count and one page query without loading items`() {
        `when`(mapper.countAllOrders()).thenReturn(101L)
        `when`(mapper.selectOrderSummaryPage(100, 100)).thenReturn(listOf(record(id = 1L)))

        val result = repository.findSummaryPage(page = 2, size = 200)

        assertEquals(2, result.page)
        assertEquals(100, result.size)
        assertEquals(101L, result.total)
        assertEquals(2, result.totalPages)
        assertEquals(listOf(1L), result.items.map { it.id })
        verify(mapper).countAllOrders()
        verify(mapper).selectOrderSummaryPage(100, 100)
        verify(mapper, never()).selectItemsByOrderId(anyLong())
    }

    @Test
    fun `findSummaryPage skips page and item queries when total is zero`() {
        `when`(mapper.countAllOrders()).thenReturn(0L)

        val result = repository.findSummaryPage(page = 0, size = 0)

        assertEquals(1, result.page)
        assertEquals(1, result.size)
        assertEquals(0L, result.total)
        assertEquals(0, result.totalPages)
        assertTrue(result.items.isEmpty())
        verify(mapper).countAllOrders()
        verify(mapper, never()).selectOrderSummaryPage(org.mockito.ArgumentMatchers.anyInt(), org.mockito.ArgumentMatchers.anyInt())
        verify(mapper, never()).selectItemsByOrderId(anyLong())
    }

    private fun record(
        id: Long,
        status: String = "PENDING",
        createdAt: LocalDateTime? = LocalDateTime.of(2026, 8, 26, 10, 0)
    ) = OrderSummaryRecord(
        id = id,
        userId = 7L,
        status = status,
        totalAmount = 10_000L,
        createdAt = createdAt
    )
}
