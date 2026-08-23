package com.nagi4757.ec.api.auth.application

import com.nagi4757.ec.api.auth.application.command.LoginCommand
import com.nagi4757.ec.api.auth.application.command.SignUpCommand
import com.nagi4757.ec.api.auth.application.dto.AuthResult
import com.nagi4757.ec.api.auth.domain.model.User
import com.nagi4757.ec.api.auth.domain.model.UserRole
import com.nagi4757.ec.api.auth.domain.repository.UserRepository
import com.nagi4757.ec.api.common.security.JwtTokenProvider
import com.nagi4757.ec.api.common.error.EmailAlreadyExistsException
import com.nagi4757.ec.api.common.error.InvalidCredentialsException
import com.nagi4757.ec.api.common.error.UserCreationFailedException
import org.springframework.security.crypto.password.PasswordEncoder
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

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
            throw EmailAlreadyExistsException()
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
            ?: throw UserCreationFailedException()

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
            ?: throw InvalidCredentialsException()

        if (!passwordEncoder.matches(cmd.password, user.passwordHash)) {
            throw InvalidCredentialsException()
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
