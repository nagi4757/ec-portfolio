package com.nagi4757.ec.api.category.infra

import com.nagi4757.ec.api.category.domain.factory.CategoryFactory
import com.nagi4757.ec.api.category.domain.model.Category
import com.nagi4757.ec.api.category.domain.repository.CategoryRepository
import com.nagi4757.ec.api.infra.mbg.mapper.CategoryMapper
import com.nagi4757.ec.api.infra.mbg.model.CategoryExample
import org.springframework.stereotype.Repository
import org.springframework.transaction.annotation.Transactional

@Repository
class MyBatisCategoryRepository(
    private val mapper: CategoryMapper,
    private val factory: CategoryFactory
) : CategoryRepository {
    override fun findById(id: Long): Category? {
        val row = mapper.selectByPrimaryKey(id)
        return row?.let(factory::fromMb)
    }

    override fun findAll(): List<Category> {
        val example = CategoryExample().apply { orderByClause = "id desc" }
        val rows = mapper.selectByExample(example)
        return rows.map(factory::fromMb)
    }

    @Transactional
    override fun create(category: Category): Long {
        val row = factory.toMb(category)
        mapper.insertSelective(row)
        return row.id ?: error("Failed to get generated id")
    }

    @Transactional
    override fun update(category: Category): Boolean {
        requireNotNull(category.id) { "id is required for update" }
        val row = factory.toMb(category)
        return mapper.updateByPrimaryKeySelective(row) > 0
    }

    @Transactional
    override fun delete(id: Long): Boolean {
        return mapper.deleteByPrimaryKey(id) > 0
    }
}

