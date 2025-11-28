package com.nagi4757.ec.api.product.infra

import com.nagi4757.ec.api.infra.mbg.mapper.ProductMapper
import com.nagi4757.ec.api.infra.mbg.model.ProductExample
import com.nagi4757.ec.api.product.domain.factory.ProductFactory
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.springframework.stereotype.Repository
import org.springframework.transaction.annotation.Transactional

@Repository
class MyBatisProductRepository(
    private val mapper: ProductMapper,
    private val factory: ProductFactory
) : ProductRepository {
    override fun findById(id: Long): Product? {
        val row = mapper.selectByPrimaryKey(id)
        return row?.let(factory::fromMb)
    }

    override fun findAll(): List<Product> {
        val example = ProductExample() // 전체 조회
        val rows = mapper.selectByExample(example)
        return rows.map(factory::fromMb)
    }

    @Transactional
    override fun create(product: Product): Long {
        val row = factory.toMb(product)
        // MBG가 useGeneratedKeys 설정 시 id 채워짐
        mapper.insertSelective(row)
        return row.id ?: error("Failed to get generated id")
    }

    @Transactional
    override fun update(product: Product): Boolean {
        requireNotNull(product.id) { "id is required for update" }
        val row = factory.toMb(product)
        return mapper.updateByPrimaryKeySelective(row) > 0
    }

    @Transactional
    override fun delete(id: Long): Boolean {
        return mapper.deleteByPrimaryKey(id) > 0
    }
}