package com.nagi4757.ec.api.common.security

import io.jsonwebtoken.Jwts
import io.jsonwebtoken.security.Keys
import org.junit.jupiter.api.Test
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.Date
import kotlin.test.assertEquals
import kotlin.test.assertNull

class JwtTokenProviderTest {
    private val provider = JwtTokenProvider(TEST_SECRET, 3600)
    private val key = Keys.hmacShaKeyFor(TEST_SECRET.toByteArray(StandardCharsets.UTF_8))

    @Test
    fun `parses user role`() {
        val claims = provider.parseAccessToken(createToken("USER"))

        assertEquals("USER", claims?.role)
    }

    @Test
    fun `parses admin role`() {
        val claims = provider.parseAccessToken(createToken("ADMIN"))

        assertEquals("ADMIN", claims?.role)
    }

    @Test
    fun `rejects missing role`() {
        assertNull(provider.parseAccessToken(createToken()))
    }

    @Test
    fun `rejects blank role`() {
        assertNull(provider.parseAccessToken(createToken(" ")))
    }

    @Test
    fun `rejects unknown role`() {
        assertNull(provider.parseAccessToken(createToken("SUPER_ADMIN")))
    }

    private fun createToken(role: String? = null): String {
        val now = Instant.now()
        val builder = Jwts.builder()
            .subject("1")
            .claim("email", "user@example.com")
            .issuedAt(Date.from(now))
            .expiration(Date.from(now.plusSeconds(3600)))

        if (role != null) {
            builder.claim("role", role)
        }

        return builder.signWith(key).compact()
    }

    private companion object {
        const val TEST_SECRET = "test-only-dummy-jwt-secret-at-least-32-bytes-long"
    }
}
