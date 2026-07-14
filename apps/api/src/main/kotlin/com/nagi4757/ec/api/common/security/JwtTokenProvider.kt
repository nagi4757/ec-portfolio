package com.nagi4757.ec.api.common.security

import io.jsonwebtoken.Claims
import io.jsonwebtoken.Jwts
import io.jsonwebtoken.security.Keys
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Component
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.Date
import javax.crypto.SecretKey

data class JwtUserClaims(
    val userId: Long,
    val email: String,
    val role: String
)

@Component
class JwtTokenProvider(
    @Value("\${app.auth.jwt.secret}") secret: String,
    @Value("\${app.auth.jwt.access-token-expiration-seconds}")
    private val accessTokenExpirationSeconds: Long
) {
    private val key: SecretKey = Keys.hmacShaKeyFor(secret.toByteArray(StandardCharsets.UTF_8))

    fun createAccessToken(userId: Long, email: String, role: String): String {
        val now = Instant.now()
        val expiresAt = now.plusSeconds(accessTokenExpirationSeconds)

        return Jwts.builder()
            .subject(userId.toString())
            .claim("email", email)
            .claim("role", role)
            .issuedAt(Date.from(now))
            .expiration(Date.from(expiresAt))
            .signWith(key)
            .compact()
    }

    fun parseAccessToken(token: String): JwtUserClaims? =
        runCatching {
            val claims = parseClaims(token)
            JwtUserClaims(
                userId = claims.subject.toLong(),
                email = claims["email"]?.toString() ?: "",
                role = claims["role"]?.toString() ?: "USER"
            )
        }.getOrNull()

    private fun parseClaims(token: String): Claims =
        Jwts.parser()
            .verifyWith(key)
            .build()
            .parseSignedClaims(token)
            .payload
}

