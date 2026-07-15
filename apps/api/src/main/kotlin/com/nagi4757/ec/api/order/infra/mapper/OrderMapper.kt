package com.nagi4757.ec.api.order.infra.mapper

import org.apache.ibatis.annotations.Mapper
import org.apache.ibatis.annotations.Param
import java.time.LocalDateTime

@Mapper
interface OrderMapper {
    fun insertOrder(record: OrderRecord): Int
    fun insertOrderItem(record: OrderItemRecord): Int
    fun selectOrderById(id: Long): OrderRecord?
    fun selectOrderByIdAndUserId(@Param("id") id: Long, @Param("userId") userId: Long): OrderRecord?
    fun selectOrdersByUserId(userId: Long): List<OrderRecord>
    fun selectAllOrders(@Param("offset") offset: Int, @Param("limit") limit: Int): List<OrderRecord>
    fun countAllOrders(): Long
    fun selectItemsByOrderId(orderId: Long): List<OrderItemRecord>
    fun updateOrderStatus(@Param("id") id: Long, @Param("status") status: String): Int
}

data class OrderRecord(
    var id: Long? = null,
    val userId: Long = 0,
    val status: String = "PENDING",
    val totalAmount: Long = 0,
    val createdAt: LocalDateTime? = null,
    val updatedAt: LocalDateTime? = null
)

data class OrderItemRecord(
    var id: Long? = null,
    val orderId: Long = 0,
    val productId: Long = 0,
    val name: String = "",
    val price: Long = 0,
    val quantity: Int = 0,
    val lineAmount: Long = 0
)

