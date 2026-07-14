package com.nagi4757.ec.api.product.application

import com.nagi4757.ec.api.product.application.command.CreateProductCommand
import com.nagi4757.ec.api.product.application.command.UpdateProductCommand
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

@Service
class ProductService(
    private val productRepository: ProductRepository
) {
    @Transactional(readOnly = true)
    fun get(id: Long): Product? = productRepository.findById(id)

    @Transactional(readOnly = true)
    fun listAll(): List<Product> = productRepository.findAll()

    @Transactional(readOnly = true)
    fun search(
        keyword: String?,
        minPrice: Long?,
        maxPrice: Long?,
        sort: String?,
        page: Int,
        size: Int
    ): ProductSearchPage {
        val safePage = page.coerceAtLeast(1)
        val safeSize = size.coerceIn(1, 100)
        val normalizedKeyword = keyword?.trim()?.lowercase().orEmpty()

        val filtered = productRepository.findAll()
            .asSequence()
            .filter { product ->
                if (normalizedKeyword.isBlank()) return@filter true
                product.name.lowercase().contains(normalizedKeyword) ||
                    (product.description?.lowercase()?.contains(normalizedKeyword) == true)
            }
            .filter { product -> minPrice == null || product.price >= minPrice }
            .filter { product -> maxPrice == null || product.price <= maxPrice }
            .toList()

        val sorted = when (sort) {
            "priceAsc" -> filtered.sortedBy { it.price }
            "priceDesc" -> filtered.sortedByDescending { it.price }
            "nameAsc" -> filtered.sortedBy { it.name.lowercase() }
            else -> filtered.sortedByDescending { it.id ?: 0L } // newest
        }

        val total = sorted.size.toLong()
        val totalPages = if (total == 0L) 0 else ((total + safeSize - 1) / safeSize).toInt()

        val fromIndex = (safePage - 1) * safeSize
        val items = if (fromIndex >= sorted.size) {
            emptyList()
        } else {
            sorted.subList(fromIndex, minOf(fromIndex + safeSize, sorted.size))
        }

        return ProductSearchPage(
            items = items,
            page = safePage,
            size = safeSize,
            total = total,
            totalPages = totalPages
        )
    }

    @Transactional
    fun create(cmd: CreateProductCommand): Product {
        val product = Product(
            id = null,
            name = cmd.name,
            price = cmd.price,
            imageUrl = cmd.imageUrl,
            description = cmd.description
        )
        val newId = productRepository.create(product)
        return productRepository.findById(newId)!!
    }

    @Transactional
    fun update(id: Long, cmd: UpdateProductCommand): Product {
        val current = productRepository.findById(id) ?: error("Product($id) not found")
        val updated = current.copy(
            name = cmd.name ?: current.name,
            price = cmd.price ?: current.price,
            imageUrl = cmd.imageUrl ?: current.imageUrl,
            description = cmd.description ?: current.description
        )
        productRepository.update(updated)
        return productRepository.findById(id)!!
    }

    @Transactional
    fun delete(id: Long) {
        // 존재 확인용
        get(id)
        productRepository.delete(id)
    }
}

data class ProductSearchPage(
    val items: List<Product>,
    val page: Int,
    val size: Int,
    val total: Long,
    val totalPages: Int
)
