package com.nagi4757.ec.api.auth.domain.repository

import com.nagi4757.ec.api.auth.domain.model.User

interface UserRepository {
    fun findById(id: Long): User?

    /**
     * Locks the user row for the current transaction and reports whether the user
     * exists. Used to serialise checkout per customer.
     */
    fun lockForUpdate(id: Long): Boolean
    fun findByEmail(email: String): User?
    fun create(user: User): Long
}

