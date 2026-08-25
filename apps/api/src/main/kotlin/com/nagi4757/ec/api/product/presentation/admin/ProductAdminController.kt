package com.nagi4757.ec.api.product.presentation.admin

import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.application.command.CreateProductCommand
import com.nagi4757.ec.api.product.application.command.UpdateProductCommand
import com.nagi4757.ec.api.product.presentation.shared.ProductRequest
import com.nagi4757.ec.api.product.presentation.shared.ProductResponse
import com.nagi4757.ec.api.product.presentation.shared.toResponse
import jakarta.validation.Valid
import org.springframework.http.HttpStatus
import org.springframework.web.bind.annotation.DeleteMapping
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PatchMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.bind.annotation.ResponseStatus

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
        productService.get(id)?.toResponse()
            ?: throw ResourceNotFoundException(ApiErrorCode.PRODUCT_NOT_FOUND)

    @PostMapping
    fun create(
        @Valid @RequestBody req: ProductRequest.Create
    ): ProductResponse {
        val saved = productService.create(
            CreateProductCommand(
                name = req.name,
                price = req.price,
                stockQuantity = requireNotNull(req.stockQuantity),
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
                stockQuantity = req.stockQuantity,
                imageUrl = req.imageUrl,
                description = req.description,
                active = req.active
            )
        )
        return saved.toResponse()
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    fun delete(@PathVariable id: Long) {
        productService.deactivate(id)
    }
}
