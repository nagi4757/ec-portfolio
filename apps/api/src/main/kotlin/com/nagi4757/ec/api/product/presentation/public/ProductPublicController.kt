package com.nagi4757.ec.api.product.presentation.public

import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.presentation.shared.ProductResponse
import com.nagi4757.ec.api.product.presentation.shared.toResponse
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/public/products")
class ProductPublicController(
    private val productService: ProductService
) {
    @GetMapping
    fun list(): List<ProductResponse> =
        productService.listAll().map { it.toResponse() }

    @GetMapping("/{id}")
    fun get(@PathVariable id: Long): ProductResponse =
        productService.get(id)?.toResponse() ?: error("Product($id) not found")
}