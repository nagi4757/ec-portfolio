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