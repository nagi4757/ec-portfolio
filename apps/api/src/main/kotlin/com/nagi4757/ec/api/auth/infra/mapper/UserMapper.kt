package com.nagi4757.ec.api.auth.infra.mapper

import org.apache.ibatis.annotations.Insert
import org.apache.ibatis.annotations.Mapper
import org.apache.ibatis.annotations.Options
import org.apache.ibatis.annotations.Select
import java.util.Date

@Mapper
interface UserMapper {
    @Select(
        """
        SELECT id, email, password_hash, name, role, created_at
        FROM users
        WHERE id = #{id}
        """
    )
    fun selectById(id: Long): UserRecord?

    @Select(
        """
        SELECT id, email, password_hash, name, role, created_at
        FROM users
        WHERE email = #{email}
        LIMIT 1
        """
    )
    fun selectByEmail(email: String): UserRecord?

    @Insert(
        """
        INSERT INTO users (email, password_hash, name, role, created_at)
        VALUES (#{email}, #{passwordHash}, #{name}, #{role}, #{createdAt})
        """
    )
    @Options(useGeneratedKeys = true, keyProperty = "id")
    fun insert(record: UserRecord): Int
}

data class UserRecord(
    var id: Long? = null,
    var email: String? = null,
    var passwordHash: String? = null,
    var name: String? = null,
    var role: String? = null,
    var createdAt: Date? = null
)
