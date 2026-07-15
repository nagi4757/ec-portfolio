package com.nagi4757.ec.api.order.infra

import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.factory.OrderFactory
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.repository.OrderPage
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.order.infra.mapper.OrderMapper
import org.springframework.stereotype.Repository
import org.springframework.transaction.annotation.Transactional

@Repository
class MyBatisOrderRepository(
    private val mapper: OrderMapper,
    private val orderFactory: OrderFactory
) : OrderRepository {

    @Transactional
    override fun save(order: Order): Order {
        val record = orderFactory.toOrderRecord(order)
        mapper.insertOrder(record)
        val orderId = record.id ?: error("Failed to get generated order id")

        order.items.forEach { item ->
            mapper.insertOrderItem(orderFactory.toOrderItemRecord(orderId, item))
        }

        return findById(orderId)!!
    }

    override fun findById(id: Long): Order? {
        val record = mapper.selectOrderById(id) ?: return null
        return orderFactory.fromOrderRecord(record, mapper.selectItemsByOrderId(id))
    }

    override fun findByIdAndUserId(id: Long, userId: Long): Order? {
        val record = mapper.selectOrderByIdAndUserId(id, userId) ?: return null
        return orderFactory.fromOrderRecord(record, mapper.selectItemsByOrderId(id))
    }

    override fun findByUserId(userId: Long): List<Order> =
        mapper.selectOrdersByUserId(userId).map { record ->
            orderFactory.fromOrderRecord(record, mapper.selectItemsByOrderId(record.id!!))
        }

    override fun findAll(page: Int, size: Int): OrderPage {
        val safePage = page.coerceAtLeast(1)
        val safeSize = size.coerceIn(1, 100)
        val total = mapper.countAllOrders()
        val records = if (total == 0L) emptyList()
                      else mapper.selectAllOrders((safePage - 1) * safeSize, safeSize)
        val totalPages = if (total == 0L) 0 else ((total + safeSize - 1) / safeSize).toInt()

        return OrderPage(
            items = records.map { r -> orderFactory.fromOrderRecord(r, mapper.selectItemsByOrderId(r.id!!)) },
            page = safePage,
            size = safeSize,
            total = total,
            totalPages = totalPages
        )
    }

    override fun updateStatus(id: Long, status: OrderStatus): Boolean =
        mapper.updateOrderStatus(id, status.name) > 0
}

