package com.nagi4757.ec.api.refund.infra.mapper

import org.apache.ibatis.annotations.Mapper
import org.apache.ibatis.annotations.Param
import java.time.LocalDateTime

@Mapper
interface RefundAttemptMapper {
    fun insertRefundAttempt(record: RefundAttemptRecord): Int
    fun selectByIdempotencyKey(idempotencyKey: String): RefundAttemptRecord?
    fun selectById(id: Long): RefundAttemptRecord?
    fun selectActiveByOrderId(orderId: Long): RefundAttemptRecord?
    fun selectLatestByOrderId(orderId: Long): RefundAttemptRecord?
    fun updateRefundAttemptResult(
        @Param("id") id: Long,
        @Param("status") status: String,
        @Param("externalRefundId") externalRefundId: String?
    ): Int
}

data class RefundAttemptRecord(
    var id: Long? = null,
    val idempotencyKey: String = "",
    val requestFingerprint: String = "",
    val orderId: Long = 0,
    val paymentAttemptId: Long = 0,
    val amountJpy: Long = 0,
    val status: String = "PENDING",
    val externalRefundId: String? = null,
    val orderStatusBefore: String = "",
    val createdAt: LocalDateTime? = null,
    val updatedAt: LocalDateTime? = null
)
