package com.nagi4757.ec.api.auth.infra

import com.nagi4757.ec.api.auth.domain.factory.UserFactory
import com.nagi4757.ec.api.auth.domain.model.User
import com.nagi4757.ec.api.auth.domain.repository.UserRepository
import com.nagi4757.ec.api.auth.infra.mapper.UserMapper
import org.springframework.stereotype.Repository
import org.springframework.transaction.annotation.Transactional

@Repository
class MyBatisUserRepository(
    private val mapper: UserMapper,
    private val factory: UserFactory
) : UserRepository {
    override fun findById(id: Long): User? =
        mapper.selectById(id)?.let(factory::fromRecord)

    override fun findByEmail(email: String): User? =
        mapper.selectByEmail(email)?.let(factory::fromRecord)

    @Transactional
    override fun create(user: User): Long {
        val row = factory.toRecord(user)
        mapper.insert(row)
        return row.id ?: error("Failed to get generated id")
    }
}
