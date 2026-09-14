package com.nagi4757.ec.api.cart.infra

import com.nagi4757.ec.api.cart.domain.model.CartItem
import com.nagi4757.ec.api.cart.domain.repository.CartRepository
import org.springframework.data.redis.core.StringRedisTemplate
import org.springframework.data.redis.core.script.RedisScript
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

    override fun removeSnapshotQuantity(userId: Long, productId: Long, quantity: Int): Int {
        require(quantity > 0) { "Snapshot quantity must be positive" }

        val remaining = redis.execute(
            REMOVE_SNAPSHOT_QUANTITY,
            listOf(key(userId)),
            productId.toString(),
            quantity.toString()
        ) ?: 0L

        return remaining.toInt()
    }

    private fun key(userId: Long): String = "cart:$userId"

    private companion object {
        /**
         * Read, subtract and write in one atomic step.
         *
         * Splitting this into HINCRBY followed by a conditional HDEL would let a
         * concurrent add land between the two commands, and the delete would then
         * discard the quantity the customer had just added.
         *
         * The subtraction is skipped when the line holds fewer units than were
         * reserved. That case means the line is no longer the one that was paid for:
         * the customer removed it and put the product back, or reduced it, while the
         * payment was in flight. Subtracting then would delete units they added after
         * checking out. Leaving a stale line is recoverable by the customer; silently
         * deleting items they chose is not, so the conservative branch wins.
         */
        val REMOVE_SNAPSHOT_QUANTITY: RedisScript<Long> = RedisScript.of(
            """
            local current = redis.call('HGET', KEYS[1], ARGV[1])
            if not current then
                return 0
            end
            local held = tonumber(current)
            local reserved = tonumber(ARGV[2])
            if held < reserved then
                return held
            end
            local remaining = held - reserved
            if remaining <= 0 then
                redis.call('HDEL', KEYS[1], ARGV[1])
                return 0
            end
            redis.call('HSET', KEYS[1], ARGV[1], remaining)
            return remaining
            """.trimIndent(),
            Long::class.java
        )
    }
}

