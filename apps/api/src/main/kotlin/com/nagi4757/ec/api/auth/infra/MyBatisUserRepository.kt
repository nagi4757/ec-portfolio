package com.nagi4757.ec.api.auth.infra

import com.nagi4757.ec.api.auth.domain.factory.UserFactory
import com.nagi4757.ec.api.auth.domain.model.User
import com.nagi4757.ec.api.auth.domain.repository.UserRepository
import com.nagi4757.ec.api.infra.mbg.mapper.UserMapper
import com.nagi4757.ec.api.infra.mbg.model.UserExample
import org.springframework.stereotype.Repository
import org.springframework.transaction.annotation.Transactional

@Repository
class MyBatisUserRepository(
    private val mapper: UserMapper,
    private val factory: UserFactory
) : UserRepository {
    override fun findById(id: Long): User? =
        mapper.selectByPrimaryKey(id)?.let(factory::fromMb)

    override fun findByEmail(email: String): User? {
        val example = UserExample().apply {
            createCriteria().andEmailEqualTo(email)
            orderByClause = "id desc"
        }
        return mapper.selectByExample(example).firstOrNull()?.let(factory::fromMb)
    }

    @Transactional
    override fun create(user: User): Long {
        val row = factory.toMb(user)
        mapper.insertSelective(row)
        return row.id ?: error("Failed to get generated id")
    }
}

