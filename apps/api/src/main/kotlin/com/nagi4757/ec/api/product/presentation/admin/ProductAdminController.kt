package com.nagi4757.ec.api.product.presentation.admin

import com.nagi4757.ec.api.common.config.ApiErrorCodes
import com.nagi4757.ec.api.common.config.OpenApiConfig
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.application.command.CreateProductCommand
import com.nagi4757.ec.api.product.application.command.UpdateProductCommand
import com.nagi4757.ec.api.product.presentation.shared.ProductRequest
import com.nagi4757.ec.api.product.presentation.shared.ProductResponse
import com.nagi4757.ec.api.product.presentation.shared.toResponse
import jakarta.validation.Valid
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
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
@Tag(name = "Admin - Products")
@SecurityRequirement(name = OpenApiConfig.BEARER_AUTH_NAME)
@ApiErrorCodes(ApiErrorCode.UNAUTHORIZED, ApiErrorCode.ACCESS_DENIED)
class ProductAdminController(
    private val productService: ProductService
) {
    @GetMapping
    @Operation(operationId = "listAdminProducts")
    fun list(): List<ProductResponse> =
        productService.listAll().map { it.toResponse() }

    @GetMapping("/{id}")
    @Operation(operationId = "getAdminProduct")
    @ApiErrorCodes(ApiErrorCode.PRODUCT_NOT_FOUND)
    fun get(@PathVariable id: Long): ProductResponse =
        productService.get(id)?.toResponse()
            ?: throw ResourceNotFoundException(ApiErrorCode.PRODUCT_NOT_FOUND)

    @PostMapping
    @Operation(operationId = "createProduct")
    @ApiErrorCodes(ApiErrorCode.VALIDATION_FAILED, ApiErrorCode.MALFORMED_REQUEST)
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
    @Operation(operationId = "updateProduct")
    @ApiErrorCodes(
        ApiErrorCode.VALIDATION_FAILED,
        ApiErrorCode.MALFORMED_REQUEST,
        ApiErrorCode.PRODUCT_NOT_FOUND
    )
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
    @Operation(operationId = "deactivateProduct", summary = "Deactivate a product")
    @ApiErrorCodes(ApiErrorCode.PRODUCT_NOT_FOUND)
    fun delete(@PathVariable id: Long) {
        productService.deactivate(id)
    }
}
