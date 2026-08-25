package com.nagi4757.ec.api.product.application

import com.nagi4757.ec.api.product.application.command.CreateProductCommand
import com.nagi4757.ec.api.product.application.command.UpdateProductCommand
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import com.nagi4757.ec.api.product.domain.repository.ProductSearchCondition
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
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
        val result = productRepository.search(
            ProductSearchCondition(
                keyword = keyword,
                minPrice = minPrice,
                maxPrice = maxPrice,
                sort = sort ?: "newest",
                page = page,
                size = size
            )
        )

        return ProductSearchPage(
            items = result.items,
            page = result.page,
            size = result.size,
            total = result.total,
            totalPages = result.totalPages
        )
    }

    @Transactional
    fun create(cmd: CreateProductCommand): Product {
        val product = Product(
            id = null,
            name = cmd.name,
            price = cmd.price,
            stockQuantity = cmd.stockQuantity,
            imageUrl = cmd.imageUrl,
            description = cmd.description
        )
        val newId = productRepository.create(product)
        return getRequired(newId)
    }

    @Transactional
    fun update(id: Long, cmd: UpdateProductCommand): Product {
        val current = productRepository.findById(id)
            ?: throw ResourceNotFoundException(ApiErrorCode.PRODUCT_NOT_FOUND)
        val updated = current.copy(
            name = cmd.name ?: current.name,
            price = cmd.price ?: current.price,
            stockQuantity = cmd.stockQuantity ?: current.stockQuantity,
            imageUrl = cmd.imageUrl ?: current.imageUrl,
            description = cmd.description ?: current.description
        )
        productRepository.update(updated)
        return getRequired(id)
    }

    @Transactional
    fun delete(id: Long) {
        if (productRepository.findById(id) == null) {
            throw ResourceNotFoundException(ApiErrorCode.PRODUCT_NOT_FOUND)
        }
        productRepository.delete(id)
    }

    private fun getRequired(id: Long): Product =
        productRepository.findById(id)
            ?: throw ResourceNotFoundException(ApiErrorCode.PRODUCT_NOT_FOUND)
}

data class ProductSearchPage(
    val items: List<Product>,
    val page: Int,
    val size: Int,
    val total: Long,
    val totalPages: Int
)
