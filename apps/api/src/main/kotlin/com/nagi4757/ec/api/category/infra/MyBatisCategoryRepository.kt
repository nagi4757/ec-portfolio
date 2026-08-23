package com.nagi4757.ec.api.category.infra

import com.nagi4757.ec.api.category.domain.factory.CategoryFactory
import com.nagi4757.ec.api.category.domain.model.Category
import com.nagi4757.ec.api.category.domain.repository.CategoryRepository
import com.nagi4757.ec.api.category.infra.mapper.CategoryMapper
import org.springframework.stereotype.Repository
import org.springframework.transaction.annotation.Transactional

@Repository
class MyBatisCategoryRepository(
    private val mapper: CategoryMapper,
    private val factory: CategoryFactory
) : CategoryRepository {
    override fun findById(id: Long): Category? {
        val row = mapper.selectById(id)
        return row?.let(factory::fromRecord)
    }

    override fun findAll(): List<Category> {
        return mapper.selectAll().map(factory::fromRecord)
    }

    @Transactional
    override fun create(category: Category): Long {
        val row = factory.toRecord(category)
        mapper.insert(row)
        return row.id ?: error("Failed to get generated id")
    }

    @Transactional
    override fun update(category: Category): Boolean {
        requireNotNull(category.id) { "id is required for update" }
        val row = factory.toRecord(category)
        return mapper.update(row) > 0
    }

    @Transactional
    override fun delete(id: Long): Boolean {
        return mapper.delete(id) > 0
    }
}
