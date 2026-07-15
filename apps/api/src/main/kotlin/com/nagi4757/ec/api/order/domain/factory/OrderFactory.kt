package com.nagi4757.ec.api.order.domain.factory

import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderItem
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.infra.mapper.OrderItemRecord
import com.nagi4757.ec.api.order.infra.mapper.OrderRecord
import org.springframework.stereotype.Component

@Component
class OrderFactory {
    fun toOrderRecord(src: Order): OrderRecord = OrderRecord(
        id = src.id,
        userId = src.userId,
        status = src.status.name,
        totalAmount = src.totalAmount,
        createdAt = src.createdAt
    )

    fun toOrderItemRecord(orderId: Long, src: OrderItem): OrderItemRecord = OrderItemRecord(
        id = src.id,
        orderId = orderId,
        productId = src.productId,
        name = src.name,
        price = src.price,
        quantity = src.quantity,
        lineAmount = src.lineAmount
    )

    fun fromOrderRecord(src: OrderRecord, items: List<OrderItemRecord>): Order = Order(
        id = src.id,
        userId = src.userId,
        status = OrderStatus.valueOf(src.status),
        items = items.map(::fromOrderItemRecord),
        totalAmount = src.totalAmount,
        createdAt = src.createdAt
    )

    fun fromOrderItemRecord(src: OrderItemRecord): OrderItem = OrderItem(
        id = src.id,
        orderId = src.orderId,
        productId = src.productId,
        name = src.name,
        price = src.price,
        quantity = src.quantity,
        lineAmount = src.lineAmount
    )
}

