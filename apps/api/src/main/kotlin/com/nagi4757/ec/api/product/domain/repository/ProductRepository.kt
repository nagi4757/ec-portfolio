package com.nagi4757.ec.api.product.domain.repository

import com.nagi4757.ec.api.product.domain.model.Product

interface ProductRepository {
    fun findById(id: Long): Product?
    fun findAll(): List<Product>
    fun create(product: Product): Long
    fun update(product: Product): Boolean
    fun delete(id: Long): Boolean
}