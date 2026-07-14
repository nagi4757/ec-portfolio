package com.nagi4757.ec.api.auth.presentation.shared

import com.nagi4757.ec.api.auth.application.dto.AuthResult
import com.nagi4757.ec.api.auth.domain.model.User
import jakarta.validation.constraints.Email
import jakarta.validation.constraints.NotBlank
import jakarta.validation.constraints.Size

object AuthRequest {
    data class SignUp(
        @field:Email @field:NotBlank val email: String,
        @field:Size(min = 8, max = 100) val password: String,
        @field:NotBlank @field:Size(max = 100) val name: String
    )

    data class Login(
        @field:Email @field:NotBlank val email: String,
        @field:NotBlank val password: String
    )
}

data class AuthUserResponse(
    val id: Long,
    val email: String,
    val name: String,
    val role: String
)

data class AuthResponse(
    val accessToken: String,
    val tokenType: String,
    val user: AuthUserResponse
)

fun User.toAuthUserResponse() = AuthUserResponse(
    id = requireNotNull(id),
    email = email,
    name = name,
    role = role.name
)

fun AuthResult.toResponse() = AuthResponse(
    accessToken = accessToken,
    tokenType = "Bearer",
    user = user.toAuthUserResponse()
)

