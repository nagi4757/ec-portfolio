package com.nagi4757.ec.api.auth.domain.factory

import com.nagi4757.ec.api.auth.domain.model.User
import com.nagi4757.ec.api.auth.domain.model.UserRole
import com.nagi4757.ec.api.infra.mbg.model.User as MbUser
import org.springframework.stereotype.Component
import java.time.Instant

@Component
class UserFactory {
    fun fromMb(src: MbUser): User =
        User(
            id = src.id,
            email = src.email ?: "",
            passwordHash = src.passwordHash ?: "",
            name = src.name ?: "",
            role = src.role?.let { runCatching { UserRole.valueOf(it) }.getOrDefault(UserRole.USER) } ?: UserRole.USER,
            createdAt = src.createdAt?.toInstant()
        )

    fun toMb(src: User): MbUser =
        MbUser().apply {
            id = src.id
            email = src.email
            passwordHash = src.passwordHash
            name = src.name
            role = src.role.name
            createdAt = src.createdAt?.let { java.util.Date.from(it) } ?: java.util.Date.from(Instant.now())
        }
}

