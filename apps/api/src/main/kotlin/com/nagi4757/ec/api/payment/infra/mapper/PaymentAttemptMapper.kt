package com.nagi4757.ec.api.payment.infra.mapper

import org.apache.ibatis.annotations.Mapper
import org.apache.ibatis.annotations.Param
import java.time.LocalDateTime

@Mapper
interface PaymentAttemptMapper {
    fun insertPaymentAttempt(record: PaymentAttemptRecord): Int
    fun selectByIdempotencyKey(idempotencyKey: String): PaymentAttemptRecord?
    fun updatePaymentAttemptResult(
        @Param("id") id: Long,
        @Param("status") status: String,
        @Param("externalPaymentId") externalPaymentId: String?
    ): Int
}

data class PaymentAttemptRecord(
    var id: Long? = null,
    val idempotencyKey: String = "",
    val requestFingerprint: String = "",
    val amountJpy: Long = 0,
    val status: String = "PENDING",
    val externalPaymentId: String? = null,
    val createdAt: LocalDateTime? = null,
    val updatedAt: LocalDateTime? = null
)
