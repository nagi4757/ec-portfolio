package com.nagi4757.ec.api.product.infra

import com.nagi4757.ec.api.infra.mbg.mapper.ProductMapper
import com.nagi4757.ec.api.infra.mbg.model.ProductExample
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
        val row = mapper.selectByPrimaryKey(id)
        return row?.let(factory::fromMb)
    }

    override fun findAll(): List<Product> {
        val example = ProductExample() // 전체 조회
        val rows = mapper.selectByExample(example)
        return rows.map(factory::fromMb)
    }

    override fun search(condition: ProductSearchCondition): ProductSearchResult {
        val safePage = condition.page.coerceAtLeast(1)
        val safeSize = condition.size.coerceIn(1, 100)
        val offset = (safePage - 1) * safeSize

        val countExample = buildSearchExample(condition)
        val total = mapper.countByExample(countExample)

        val dataExample = buildSearchExample(condition)
        dataExample.orderByClause = when (condition.sort) {
            "priceAsc" -> "price asc limit $safeSize offset $offset"
            "priceDesc" -> "price desc limit $safeSize offset $offset"
            "nameAsc" -> "name asc limit $safeSize offset $offset"
            else -> "id desc limit $safeSize offset $offset"
        }

        val rows = if (total == 0L) emptyList() else mapper.selectByExample(dataExample)
        val totalPages = if (total == 0L) 0 else ((total + safeSize - 1) / safeSize).toInt()

        return ProductSearchResult(
            items = rows.map(factory::fromMb),
            page = safePage,
            size = safeSize,
            total = total,
            totalPages = totalPages
        )
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

    private fun buildSearchExample(condition: ProductSearchCondition): ProductExample {
        val example = ProductExample()
        val keyword = condition.keyword?.trim()?.takeIf { it.isNotEmpty() }

        if (keyword == null) {
            val criteria = example.createCriteria()
            applyPriceFilter(criteria, condition)
            return example
        }

        val like = "%$keyword%"

        val nameCriteria = example.createCriteria().andNameLike(like)
        applyPriceFilter(nameCriteria, condition)

        val descCriteria = example.or().andDescriptionLike(like)
        applyPriceFilter(descCriteria, condition)

        return example
    }

    private fun applyPriceFilter(
        criteria: ProductExample.Criteria,
        condition: ProductSearchCondition
    ) {
        condition.minPrice?.let { criteria.andPriceGreaterThanOrEqualTo(it) }
        condition.maxPrice?.let { criteria.andPriceLessThanOrEqualTo(it) }
    }
}