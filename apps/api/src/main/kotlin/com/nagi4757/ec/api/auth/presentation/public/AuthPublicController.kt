package com.nagi4757.ec.api.auth.presentation.public

import com.nagi4757.ec.api.auth.application.AuthService
import com.nagi4757.ec.api.auth.application.command.LoginCommand
import com.nagi4757.ec.api.auth.application.command.SignUpCommand
import com.nagi4757.ec.api.auth.presentation.shared.AuthRequest
import com.nagi4757.ec.api.auth.presentation.shared.AuthResponse
import com.nagi4757.ec.api.auth.presentation.shared.toResponse
import com.nagi4757.ec.api.common.config.ApiErrorCodes
import com.nagi4757.ec.api.common.error.ApiErrorCode
import io.swagger.v3.oas.annotations.tags.Tag
import jakarta.validation.Valid
import org.springframework.http.HttpStatus
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.ResponseStatus
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/public/auth")
@Tag(name = "Public - Auth")
class AuthPublicController(
    private val authService: AuthService
) {
    @PostMapping("/signup")
    @ResponseStatus(HttpStatus.CREATED)
    @ApiErrorCodes(
        ApiErrorCode.VALIDATION_FAILED,
        ApiErrorCode.MALFORMED_REQUEST,
        ApiErrorCode.EMAIL_ALREADY_EXISTS,
        ApiErrorCode.USER_CREATION_FAILED
    )
    fun signUp(@Valid @RequestBody req: AuthRequest.SignUp): AuthResponse =
        authService.signUp(
            SignUpCommand(
                email = req.email,
                password = req.password,
                name = req.name
            )
        ).toResponse()

    @PostMapping("/login")
    @ApiErrorCodes(
        ApiErrorCode.VALIDATION_FAILED,
        ApiErrorCode.MALFORMED_REQUEST,
        ApiErrorCode.INVALID_CREDENTIALS
    )
    fun login(@Valid @RequestBody req: AuthRequest.Login): AuthResponse =
        authService.login(
            LoginCommand(
                email = req.email,
                password = req.password
            )
        ).toResponse()
}
