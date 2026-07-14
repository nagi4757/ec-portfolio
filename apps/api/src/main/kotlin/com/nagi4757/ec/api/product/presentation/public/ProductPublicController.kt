package com.nagi4757.ec.api.product.presentation.public

import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.presentation.shared.ProductListResponse
import com.nagi4757.ec.api.product.presentation.shared.ProductResponse
import com.nagi4757.ec.api.product.presentation.shared.toResponse
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/public/products")
class ProductPublicController(
    private val productService: ProductService
) {
    @GetMapping
    fun list(
        @RequestParam(required = false) keyword: String?,
        @RequestParam(required = false) minPrice: Long?,
        @RequestParam(required = false) maxPrice: Long?,
        @RequestParam(required = false, defaultValue = "newest") sort: String?,
        @RequestParam(required = false, defaultValue = "1") page: Int,
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
    fun get(@PathVariable id: Long): ProductResponse =
        productService.get(id)?.toResponse() ?: error("Product($id) not found")
}