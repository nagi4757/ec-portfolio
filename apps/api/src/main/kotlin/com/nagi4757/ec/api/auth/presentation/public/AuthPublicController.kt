package com.nagi4757.ec.api.auth.presentation.public

import com.nagi4757.ec.api.auth.application.AuthService
import com.nagi4757.ec.api.auth.application.command.LoginCommand
import com.nagi4757.ec.api.auth.application.command.SignUpCommand
import com.nagi4757.ec.api.auth.presentation.shared.AuthRequest
import com.nagi4757.ec.api.auth.presentation.shared.AuthResponse
import com.nagi4757.ec.api.auth.presentation.shared.toAuthUserResponse
import com.nagi4757.ec.api.auth.presentation.shared.toResponse
import com.nagi4757.ec.api.common.security.JwtUserClaims
import jakarta.validation.Valid
import org.springframework.http.HttpStatus
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.ResponseStatus
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.server.ResponseStatusException

@RestController
@RequestMapping("/api/public/auth")
class AuthPublicController(
    private val authService: AuthService
) {
    @PostMapping("/signup")
    @ResponseStatus(HttpStatus.CREATED)
    fun signUp(@Valid @RequestBody req: AuthRequest.SignUp): AuthResponse =
        authService.signUp(
            SignUpCommand(
                email = req.email,
                password = req.password,
                name = req.name
            )
        ).toResponse()

    @PostMapping("/login")
    fun login(@Valid @RequestBody req: AuthRequest.Login): AuthResponse =
        authService.login(
            LoginCommand(
                email = req.email,
                password = req.password
            )
        ).toResponse()

    @GetMapping("/me")
    fun me() = run {
        val principal = SecurityContextHolder.getContext().authentication?.principal as? JwtUserClaims
            ?: throw ResponseStatusException(HttpStatus.UNAUTHORIZED, "Unauthorized")

        val user = authService.getById(principal.userId)
            ?: throw ResponseStatusException(HttpStatus.NOT_FOUND, "User not found")

        user.toAuthUserResponse()
    }
}

