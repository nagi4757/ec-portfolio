package com.nagi4757.ec.api.category.domain.repository

import com.nagi4757.ec.api.category.domain.model.Category

interface CategoryRepository {
    fun findById(id: Long): Category?
    fun findAll(): List<Category>
    fun create(category: Category): Long
    fun update(category: Category): Boolean
    fun delete(id: Long): Boolean
}

