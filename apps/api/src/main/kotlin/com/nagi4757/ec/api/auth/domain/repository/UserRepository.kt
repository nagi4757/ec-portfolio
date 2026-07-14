package com.nagi4757.ec.api.auth.domain.repository

import com.nagi4757.ec.api.auth.domain.model.User

interface UserRepository {
    fun findById(id: Long): User?
    fun findByEmail(email: String): User?
    fun create(user: User): Long
}

