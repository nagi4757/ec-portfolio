package com.nagi4757.ec.api.auth.domain.factory

import com.nagi4757.ec.api.auth.domain.model.User
import com.nagi4757.ec.api.auth.domain.model.UserRole
import com.nagi4757.ec.api.auth.infra.mapper.UserRecord
import org.springframework.stereotype.Component
import java.time.Instant

@Component
class UserFactory {
    fun fromRecord(src: UserRecord): User =
        User(
            id = src.id,
            email = src.email ?: "",
            passwordHash = src.passwordHash ?: "",
            name = src.name ?: "",
            role = src.role?.let { runCatching { UserRole.valueOf(it) }.getOrDefault(UserRole.USER) } ?: UserRole.USER,
            createdAt = src.createdAt?.toInstant()
        )

    fun toRecord(src: User): UserRecord =
        UserRecord().apply {
            id = src.id
            email = src.email
            passwordHash = src.passwordHash
            name = src.name
            role = src.role.name
            createdAt = src.createdAt?.let { java.util.Date.from(it) } ?: java.util.Date.from(Instant.now())
        }
}
