package com.nagi4757.ec.api.product.presentation.admin

import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.application.command.CreateProductCommand
import com.nagi4757.ec.api.product.application.command.UpdateProductCommand
import com.nagi4757.ec.api.product.presentation.shared.ProductRequest
import com.nagi4757.ec.api.product.presentation.shared.ProductResponse
import com.nagi4757.ec.api.product.presentation.shared.toResponse
import jakarta.validation.Valid
import org.springframework.web.bind.annotation.DeleteMapping
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PatchMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/admin/products")
class ProductAdminController(
    private val productService: ProductService
) {
    @GetMapping
    fun list(): List<ProductResponse> =
        productService.listAll().map { it.toResponse() }

    @GetMapping("/{id}")
    fun get(@PathVariable id: Long): ProductResponse =
        productService.get(id)?.toResponse() ?: error("Product($id) not found")

    @PostMapping
    fun create(
        @Valid @RequestBody req: ProductRequest.Create
    ): ProductResponse {
        val saved = productService.create(
            CreateProductCommand(
                name = req.name,
                price = req.price,
                imageUrl = req.imageUrl,
                description = req.description
            )
        )
        return saved.toResponse()
    }

    @PatchMapping("/{id}")
    fun update(
        @PathVariable id: Long,
        @Valid @RequestBody req: ProductRequest.Update
    ): ProductResponse {
        val saved = productService.update(
            id,
            UpdateProductCommand(
                name = req.name,
                price = req.price,
                imageUrl = req.imageUrl,
                description = req.description
            )
        )
        return saved.toResponse()
    }

    @DeleteMapping("/{id}")
    fun delete(@PathVariable id: Long) {
        productService.delete(id)
    }
}