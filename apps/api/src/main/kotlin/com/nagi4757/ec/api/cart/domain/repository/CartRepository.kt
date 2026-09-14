package com.nagi4757.ec.api.cart.domain.repository

import com.nagi4757.ec.api.cart.domain.model.CartItem

interface CartRepository {
    fun findAll(userId: Long): List<CartItem>
    fun increment(userId: Long, productId: Long, quantity: Int): Int
    fun setQuantity(userId: Long, productId: Long, quantity: Int)
    fun remove(userId: Long, productId: Long)
    fun clear(userId: Long)

    /**
     * Subtracts exactly the quantity a checkout reserved, leaving anything the
     * customer added afterwards.
     *
     * A blanket clear would discard items added while the payment was in flight,
     * and a read-then-write would race with a concurrent add. The subtraction is
     * therefore a single atomic operation.
     *
     * If the line now holds fewer units than were reserved, nothing is subtracted:
     * the customer replaced or reduced that line after checking out, and taking the
     * reserved amount would delete units they chose to have. A stale line is left
     * instead, which they can remove themselves.
     *
     * @return the quantity left on the line; 0 when the line was removed.
     */
    fun removeSnapshotQuantity(userId: Long, productId: Long, quantity: Int): Int
}

