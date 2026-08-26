package com.nagi4757.ec.api.auth.presentation.user

import com.nagi4757.ec.api.auth.application.AuthService
import com.nagi4757.ec.api.auth.presentation.shared.AuthUserResponse
import com.nagi4757.ec.api.auth.presentation.shared.toAuthUserResponse
import com.nagi4757.ec.api.common.config.ApiErrorCodes
import com.nagi4757.ec.api.common.config.OpenApiConfig
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.security.JwtUserClaims
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import org.springframework.http.HttpStatus
import org.springframework.security.core.annotation.AuthenticationPrincipal
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.server.ResponseStatusException

@RestController
@RequestMapping("/api/user/auth")
@Tag(name = "User - Auth")
@SecurityRequirement(name = OpenApiConfig.BEARER_AUTH_NAME)
@ApiErrorCodes(ApiErrorCode.UNAUTHORIZED)
class AuthUserController(
    private val authService: AuthService
) {
    @GetMapping("/me")
    @Operation(summary = "Get the currently authenticated user")
    @ApiErrorCodes(ApiErrorCode.RESOURCE_NOT_FOUND)
    fun me(@AuthenticationPrincipal principal: JwtUserClaims): AuthUserResponse {
        val user = authService.getById(principal.userId)
            ?: throw ResponseStatusException(HttpStatus.NOT_FOUND, "User not found")

        return user.toAuthUserResponse()
    }
}
