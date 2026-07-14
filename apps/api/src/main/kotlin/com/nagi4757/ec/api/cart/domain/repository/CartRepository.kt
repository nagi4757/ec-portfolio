package com.nagi4757.ec.api.cart.domain.repository

import com.nagi4757.ec.api.cart.domain.model.CartItem

interface CartRepository {
    fun findAll(userId: Long): List<CartItem>
    fun increment(userId: Long, productId: Long, quantity: Int): Int
    fun setQuantity(userId: Long, productId: Long, quantity: Int)
    fun remove(userId: Long, productId: Long)
    fun clear(userId: Long)
}

