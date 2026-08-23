package com.nagi4757.ec.api.product.infra

import com.nagi4757.ec.api.product.infra.mapper.ProductMapper
import com.nagi4757.ec.api.product.domain.factory.ProductFactory
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import com.nagi4757.ec.api.product.domain.repository.ProductSearchCondition
import com.nagi4757.ec.api.product.domain.repository.ProductSearchResult
import org.springframework.stereotype.Repository
import org.springframework.transaction.annotation.Transactional

@Repository
class MyBatisProductRepository(
    private val mapper: ProductMapper,
    private val factory: ProductFactory
) : ProductRepository {
    override fun findById(id: Long): Product? {
        val row = mapper.selectById(id)
        return row?.let(factory::fromRecord)
    }

    override fun findAll(): List<Product> {
        return mapper.selectAll().map(factory::fromRecord)
    }

    override fun search(condition: ProductSearchCondition): ProductSearchResult {
        val safePage = condition.page.coerceAtLeast(1)
        val safeSize = condition.size.coerceIn(1, 100)
        val offset = (safePage - 1) * safeSize

        val keyword = condition.keyword?.trim()?.takeIf(String::isNotEmpty)
        val total = mapper.countSearch(keyword, condition.minPrice, condition.maxPrice)
        val rows = if (total == 0L) {
            emptyList()
        } else {
            mapper.search(
                keyword = keyword,
                minPrice = condition.minPrice,
                maxPrice = condition.maxPrice,
                sort = condition.sort,
                offset = offset,
                limit = safeSize
            )
        }
        val totalPages = if (total == 0L) 0 else ((total + safeSize - 1) / safeSize).toInt()

        return ProductSearchResult(
            items = rows.map(factory::fromRecord),
            page = safePage,
            size = safeSize,
            total = total,
            totalPages = totalPages
        )
    }

    @Transactional
    override fun create(product: Product): Long {
        val row = factory.toRecord(product)
        mapper.insert(row)
        return row.id ?: error("Failed to get generated id")
    }

    @Transactional
    override fun update(product: Product): Boolean {
        requireNotNull(product.id) { "id is required for update" }
        val row = factory.toRecord(product)
        return mapper.update(row) > 0
    }

    @Transactional
    override fun delete(id: Long): Boolean {
        return mapper.delete(id) > 0
    }
}
