package com.nagi4757.ec.api.auth.application

import com.nagi4757.ec.api.auth.application.command.LoginCommand
import com.nagi4757.ec.api.auth.application.command.SignUpCommand
import com.nagi4757.ec.api.auth.application.dto.AuthResult
import com.nagi4757.ec.api.auth.domain.model.User
import com.nagi4757.ec.api.auth.domain.model.UserRole
import com.nagi4757.ec.api.auth.domain.repository.UserRepository
import com.nagi4757.ec.api.common.security.JwtTokenProvider
import org.springframework.http.HttpStatus
import org.springframework.security.crypto.password.PasswordEncoder
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import org.springframework.web.server.ResponseStatusException

@Service
class AuthService(
    private val userRepository: UserRepository,
    private val passwordEncoder: PasswordEncoder,
    private val jwtTokenProvider: JwtTokenProvider
) {
    @Transactional
    fun signUp(cmd: SignUpCommand): AuthResult {
        val exists = userRepository.findByEmail(cmd.email)
        if (exists != null) {
            throw ResponseStatusException(HttpStatus.CONFLICT, "Email already exists")
        }

        val id = userRepository.create(
            User(
                email = cmd.email,
                passwordHash = passwordEncoder.encode(cmd.password),
                name = cmd.name,
                role = UserRole.USER
            )
        )

        val created = userRepository.findById(id)
            ?: throw ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "User creation failed")

        val token = jwtTokenProvider.createAccessToken(
            userId = requireNotNull(created.id),
            email = created.email,
            role = created.role.name
        )

        return AuthResult(accessToken = token, user = created)
    }

    @Transactional(readOnly = true)
    fun login(cmd: LoginCommand): AuthResult {
        val user = userRepository.findByEmail(cmd.email)
            ?: throw ResponseStatusException(HttpStatus.UNAUTHORIZED, "Invalid credentials")

        if (!passwordEncoder.matches(cmd.password, user.passwordHash)) {
            throw ResponseStatusException(HttpStatus.UNAUTHORIZED, "Invalid credentials")
        }

        val token = jwtTokenProvider.createAccessToken(
            userId = requireNotNull(user.id),
            email = user.email,
            role = user.role.name
        )

        return AuthResult(accessToken = token, user = user)
    }

    @Transactional(readOnly = true)
    fun getById(id: Long): User? = userRepository.findById(id)
}

