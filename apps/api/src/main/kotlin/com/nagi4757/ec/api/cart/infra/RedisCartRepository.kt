package com.nagi4757.ec.api.cart.infra

import com.nagi4757.ec.api.cart.domain.model.CartItem
import com.nagi4757.ec.api.cart.domain.repository.CartRepository
import org.springframework.data.redis.core.StringRedisTemplate
import org.springframework.stereotype.Repository

@Repository
class RedisCartRepository(
    private val redis: StringRedisTemplate
) : CartRepository {
    override fun findAll(userId: Long): List<CartItem> {
        val entries = redis.opsForHash<String, String>().entries(key(userId))
        return entries.entries.mapNotNull { (k, v) ->
            val productId = k.toLongOrNull()
            val quantity = v.toIntOrNull()
            if (productId == null || quantity == null || quantity <= 0) null
            else CartItem(productId = productId, quantity = quantity)
        }.sortedBy { it.productId }
    }

    override fun increment(userId: Long, productId: Long, quantity: Int): Int {
        val result = redis.opsForHash<String, String>()
            .increment(key(userId), productId.toString(), quantity.toLong()) ?: 0L
        return result.toInt()
    }

    override fun setQuantity(userId: Long, productId: Long, quantity: Int) {
        redis.opsForHash<String, String>().put(key(userId), productId.toString(), quantity.toString())
    }

    override fun remove(userId: Long, productId: Long) {
        redis.opsForHash<String, String>().delete(key(userId), productId.toString())
    }

    override fun clear(userId: Long) {
        redis.delete(key(userId))
    }

    private fun key(userId: Long): String = "cart:$userId"
}

