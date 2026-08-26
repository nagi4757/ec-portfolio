package com.nagi4757.ec.api.cart.presentation.user

import com.nagi4757.ec.api.cart.application.CartService
import com.nagi4757.ec.api.cart.presentation.shared.CartRequest
import com.nagi4757.ec.api.cart.presentation.shared.CartResponse
import com.nagi4757.ec.api.cart.presentation.shared.toResponse
import com.nagi4757.ec.api.common.config.ApiErrorCodes
import com.nagi4757.ec.api.common.config.OpenApiConfig
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.security.JwtUserClaims
import jakarta.validation.Valid
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import org.springframework.http.HttpStatus
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.web.bind.annotation.DeleteMapping
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PatchMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.server.ResponseStatusException

@RestController
@RequestMapping("/api/user/cart")
@Tag(name = "User - Cart")
@SecurityRequirement(name = OpenApiConfig.BEARER_AUTH_NAME)
@ApiErrorCodes(ApiErrorCode.UNAUTHORIZED)
class CartUserController(
    private val cartService: CartService
) {
    @GetMapping
    fun getCart(): CartResponse =
        cartService.getCart(currentUserId()).toResponse()

    @PostMapping("/items")
    @ApiErrorCodes(
        ApiErrorCode.VALIDATION_FAILED,
        ApiErrorCode.MALFORMED_REQUEST,
        ApiErrorCode.PRODUCT_NOT_FOUND,
        ApiErrorCode.PRODUCT_NOT_AVAILABLE,
        ApiErrorCode.INSUFFICIENT_STOCK
    )
    fun addItem(@Valid @RequestBody req: CartRequest.AddItem): CartResponse =
        cartService.addItem(
            userId = currentUserId(),
            productId = req.productId,
            quantity = req.quantity
        ).toResponse()

    @PatchMapping("/items/{productId}")
    @Operation(summary = "Update a cart item quantity", description = "A quantity of zero removes the item.")
    @ApiErrorCodes(
        ApiErrorCode.VALIDATION_FAILED,
        ApiErrorCode.MALFORMED_REQUEST,
        ApiErrorCode.PRODUCT_NOT_FOUND,
        ApiErrorCode.PRODUCT_NOT_AVAILABLE,
        ApiErrorCode.INSUFFICIENT_STOCK
    )
    fun updateItem(
        @PathVariable productId: Long,
        @Valid @RequestBody req: CartRequest.UpdateItem
    ): CartResponse =
        cartService.updateItem(
            userId = currentUserId(),
            productId = productId,
            quantity = req.quantity
        ).toResponse()

    @DeleteMapping("/items/{productId}")
    fun removeItem(@PathVariable productId: Long): CartResponse =
        cartService.removeItem(currentUserId(), productId).toResponse()

    @DeleteMapping
    fun clear(): CartResponse =
        cartService.clear(currentUserId()).toResponse()

    private fun currentUserId(): Long {
        val principal = SecurityContextHolder.getContext().authentication?.principal as? JwtUserClaims
            ?: throw ResponseStatusException(HttpStatus.UNAUTHORIZED, "Unauthorized")
        return principal.userId
    }
}
