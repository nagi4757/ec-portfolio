package com.nagi4757.ec.api.product.application

import com.nagi4757.ec.api.product.application.command.CreateProductCommand
import com.nagi4757.ec.api.product.application.command.UpdateProductCommand
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductFieldChanges
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import com.nagi4757.ec.api.product.domain.repository.ProductSearchCondition
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.IncompleteStockChangeException
import com.nagi4757.ec.api.common.error.ProductStockConflictException
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
    fun getByIds(ids: Collection<Long>): List<Product> = productRepository.findByIds(ids)

    @Transactional(readOnly = true)
    fun getActive(id: Long): Product? = productRepository.findActiveById(id)

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

    /**
     * Writes only what the request carries. Copying the product as read and writing it
     * back whole would undo whatever committed in between: a deactivation, another
     * admin's edit, or the stock that checkout and refunds move. A stock change applies
     * only while the stock is still the one the admin saw, and otherwise fails the
     * whole edit.
     */
    @Transactional
    fun update(id: Long, cmd: UpdateProductCommand): Product {
        val target = cmd.stockQuantity
        val expected = cmd.expectedStockQuantity
        if ((target == null) != (expected == null)) throw IncompleteStockChangeException()

        if (productRepository.findById(id) == null) {
            throw ResourceNotFoundException(ApiErrorCode.PRODUCT_NOT_FOUND)
        }
        val changes = ProductFieldChanges(
            name = cmd.name,
            price = cmd.price,
            imageUrl = cmd.imageUrl,
            description = cmd.description,
            active = cmd.active
        )
        // A stock-only edit has nothing else to write.
        if (!changes.isEmpty) {
            productRepository.updateFields(id, changes)
        }

        // Sending back the stock the form was loaded with is not a change, whatever
        // the stock has become since.
        if (target != null && expected != null && target != expected &&
            !productRepository.compareAndSetStock(id, expected, target)
        ) {
            // Thrown out of this transaction, it rolls back the field update above too.
            throw ProductStockConflictException()
        }
        return getRequired(id)
    }

    @Transactional
    fun deactivate(id: Long) {
        val product = productRepository.findById(id)
        if (product == null) {
            throw ResourceNotFoundException(ApiErrorCode.PRODUCT_NOT_FOUND)
        }
        if (product.active) {
            productRepository.deactivate(id)
        }
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
