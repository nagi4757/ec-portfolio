package com.nagi4757.ec.api.product.presentation.public

import com.nagi4757.ec.api.common.config.ApiErrorCodes
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.presentation.shared.ProductListResponse
import com.nagi4757.ec.api.product.presentation.shared.ProductResponse
import com.nagi4757.ec.api.product.presentation.shared.toResponse
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.Parameter
import io.swagger.v3.oas.annotations.tags.Tag
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/public/products")
@Tag(name = "Public - Products")
class ProductPublicController(
    private val productService: ProductService
) {
    @GetMapping
    @Operation(
        operationId = "searchPublicProducts",
        summary = "Search active products",
        description = "Unknown sort values use the same newest-first ordering as the newest value."
    )
    @ApiErrorCodes(ApiErrorCode.BAD_REQUEST)
    fun list(
        @RequestParam(required = false) keyword: String?,
        @RequestParam(required = false) minPrice: Long?,
        @RequestParam(required = false) maxPrice: Long?,
        @Parameter(description = "Sort order: newest, priceAsc, priceDesc, or nameAsc. Unknown values use newest.")
        @RequestParam(required = false, defaultValue = "newest") sort: String?,
        @Parameter(description = "One-based page number. Values below 1 are normalized to 1.")
        @RequestParam(required = false, defaultValue = "1") page: Int,
        @Parameter(description = "Page size. Values are normalized to the range 1 through 100.")
        @RequestParam(required = false, defaultValue = "12") size: Int
    ): ProductListResponse =
        productService.search(
            keyword = keyword,
            minPrice = minPrice,
            maxPrice = maxPrice,
            sort = sort,
            page = page,
            size = size
        ).toResponse()

    @GetMapping("/{id}")
    @Operation(
        operationId = "getPublicProduct",
        summary = "Get an active product",
        description = "Inactive products are treated as not found."
    )
    @ApiErrorCodes(ApiErrorCode.PRODUCT_NOT_FOUND)
    fun get(@PathVariable id: Long): ProductResponse =
        productService.getActive(id)?.toResponse()
            ?: throw ResourceNotFoundException(ApiErrorCode.PRODUCT_NOT_FOUND)
}
