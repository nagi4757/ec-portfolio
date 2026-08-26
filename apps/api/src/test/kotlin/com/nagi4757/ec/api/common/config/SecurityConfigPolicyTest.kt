package com.nagi4757.ec.api.common.config

import com.nagi4757.ec.api.common.logging.CorrelationIdContext
import com.nagi4757.ec.api.common.security.JwtTokenProvider
import io.jsonwebtoken.Jwts
import io.jsonwebtoken.security.Keys
import org.apache.ibatis.mapping.Environment
import org.apache.ibatis.session.Configuration
import org.apache.ibatis.session.SqlSessionFactory
import org.apache.ibatis.transaction.jdbc.JdbcTransactionFactory
import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.context.TestConfiguration
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Import
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get
import org.springframework.test.web.servlet.options
import org.springframework.test.context.ActiveProfiles
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RestController
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.Date
import javax.sql.DataSource

@ActiveProfiles("test")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK)
@AutoConfigureMockMvc
@Import(SecurityConfigPolicyTest.TestApiConfig::class)
class SecurityConfigPolicyTest(
    @Autowired private val mockMvc: MockMvc,
    @Autowired private val jwtTokenProvider: JwtTokenProvider
) {
    @ParameterizedTest
    @ValueSource(strings = [
        "/actuator/health",
        "/actuator/health/liveness",
        "/actuator/health/readiness"
    ])
    fun `health endpoints are public without exposing infrastructure details`(path: String) {
        mockMvc.get(path)
            .andExpect {
                status { isOk() }
                header { exists(CorrelationIdContext.HEADER_NAME) }
                jsonPath("$.status") { value("UP") }
                jsonPath("$.components") { doesNotExist() }
                jsonPath("$.details") { doesNotExist() }
                jsonPath("$.db") { doesNotExist() }
                jsonPath("$.redis") { doesNotExist() }
            }
    }

    @ParameterizedTest
    @ValueSource(strings = [
        "/actuator",
        "/actuator/env",
        "/actuator/beans",
        "/actuator/configprops",
        "/actuator/flyway",
        "/actuator/metrics",
        "/actuator/health/db",
        "/actuator/health/redis"
    ])
    fun `non-public actuator endpoints require authentication`(path: String) {
        mockMvc.get(path)
            .andExpect {
                status { isUnauthorized() }
            }
    }

    @Test
    fun `public endpoint is allowed without authentication`() {
        mockMvc.get("/api/public/ping")
            .andExpect {
                status { isOk() }
                content { string("public-ok") }
            }
    }

    @Test
    fun `configured origin is allowed for CORS preflight request`() {
        mockMvc.options("/api/public/ping") {
            header("Origin", "https://test.example")
            header("Access-Control-Request-Method", "GET")
        }.andExpect {
            status { isOk() }
            header { string("Access-Control-Allow-Origin", "https://test.example") }
            header { string("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS") }
        }
    }

    @Test
    fun `user endpoint requires authentication`() {
        mockMvc.get("/api/user/ping") {
            header(CorrelationIdContext.HEADER_NAME, CORRELATION_ID)
        }
            .andExpect {
                status { isUnauthorized() }
                content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
                jsonPath("$.status") { value(401) }
                jsonPath("$.code") { value("UNAUTHORIZED") }
                jsonPath("$.message") { value("Authentication is required") }
                jsonPath("$.path") { value("/api/user/ping") }
                jsonPath("$.correlationId") { value(CORRELATION_ID) }
                jsonPath("$.fieldErrors") { isArray() }
                header { string(CorrelationIdContext.HEADER_NAME, CORRELATION_ID) }
            }
    }

    @Test
    fun `admin endpoint requires authentication`() {
        mockMvc.get("/api/admin/ping")
            .andExpect {
                status { isUnauthorized() }
                jsonPath("$.code") { value("UNAUTHORIZED") }
            }
    }

    @Test
    fun `user role is forbidden from admin endpoint`() {
        val token = jwtTokenProvider.createAccessToken(
            userId = 1L,
            email = "user@example.com",
            role = "USER"
        )

        mockMvc.get("/api/admin/ping") {
            header("Authorization", "Bearer $token")
            header(CorrelationIdContext.HEADER_NAME, CORRELATION_ID)
        }.andExpect {
            status { isForbidden() }
            content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
            jsonPath("$.status") { value(403) }
            jsonPath("$.code") { value("ACCESS_DENIED") }
            jsonPath("$.message") { value("Access is denied") }
            jsonPath("$.path") { value("/api/admin/ping") }
            jsonPath("$.correlationId") { value(CORRELATION_ID) }
            jsonPath("$.fieldErrors") { isArray() }
            header { string(CorrelationIdContext.HEADER_NAME, CORRELATION_ID) }
        }
    }

    @Test
    fun `user role can access user endpoint`() {
        val token = jwtTokenProvider.createAccessToken(
            userId = 1L,
            email = "user@example.com",
            role = "USER"
        )

        mockMvc.get("/api/user/ping") {
            header("Authorization", "Bearer $token")
        }.andExpect {
            status { isOk() }
            content { string("user-ok") }
        }
    }

    @Test
    fun `admin role can access admin endpoint`() {
        val token = jwtTokenProvider.createAccessToken(
            userId = 1L,
            email = "admin@example.com",
            role = "ADMIN"
        )

        mockMvc.get("/api/admin/ping") {
            header("Authorization", "Bearer $token")
        }.andExpect {
            status { isOk() }
            content { string("admin-ok") }
        }
    }

    @Test
    fun `admin role can access user endpoint`() {
        val token = jwtTokenProvider.createAccessToken(
            userId = 1L,
            email = "admin@example.com",
            role = "ADMIN"
        )

        mockMvc.get("/api/user/ping") {
            header("Authorization", "Bearer $token")
        }.andExpect {
            status { isOk() }
            content { string("user-ok") }
        }
    }

    @ParameterizedTest
    @ValueSource(strings = [MISSING_ROLE, " ", "SUPER_ADMIN"])
    fun `invalid role claim is unauthorized for protected endpoint`(role: String) {
        val token = createToken(role.takeUnless { it == MISSING_ROLE })

        expectUnauthorized(token)
    }

    @Test
    fun `token with invalid signature is unauthorized for protected endpoint`() {
        val token = createToken("USER", INVALID_SIGNATURE_SECRET)

        expectUnauthorized(token)
    }

    @Test
    fun `expired token is unauthorized for protected endpoint`() {
        val token = createToken("USER", expiration = Instant.now().minusSeconds(1))

        expectUnauthorized(token)
    }

    @Test
    fun `malformed token is unauthorized for protected endpoint`() {
        expectUnauthorized("not-a-jwt")
    }

    private fun expectUnauthorized(token: String) {
        mockMvc.get("/api/user/ping") {
            header("Authorization", "Bearer $token")
        }.andExpect {
            status { isUnauthorized() }
            jsonPath("$.code") { value("UNAUTHORIZED") }
        }
    }

    private fun createToken(
        role: String?,
        secret: String = TEST_SECRET,
        expiration: Instant = Instant.now().plusSeconds(3600)
    ): String {
        val now = Instant.now()
        val key = Keys.hmacShaKeyFor(secret.toByteArray(StandardCharsets.UTF_8))
        val builder = Jwts.builder()
            .subject("1")
            .claim("email", "user@example.com")
            .issuedAt(Date.from(now))
            .expiration(Date.from(expiration))

        if (role != null) {
            builder.claim("role", role)
        }

        return builder.signWith(key).compact()
    }

    @RestController
    class TestPingController {
        @GetMapping("/api/public/ping")
        fun publicPing(): String = "public-ok"

        @GetMapping("/api/user/ping")
        fun userPing(): String = "user-ok"

        @GetMapping("/api/admin/ping")
        fun adminPing(): String = "admin-ok"
    }

    @TestConfiguration
    class TestApiConfig {
        @Bean
        fun testPingController(): TestPingController = TestPingController()

        @Bean
        fun sqlSessionFactory(): SqlSessionFactory =
            mock(SqlSessionFactory::class.java).apply {
                val cfg = Configuration().apply {
                    environment = Environment("test", JdbcTransactionFactory(), mock(DataSource::class.java))
                }
                `when`(configuration).thenReturn(cfg)
            }
    }

    companion object {
        private const val CORRELATION_ID = "21e2a145-37da-47d0-bb27-b5c2a630446a"
        private const val TEST_SECRET = "test-only-dummy-jwt-secret-at-least-32-bytes-long"
        private const val INVALID_SIGNATURE_SECRET = "different-test-only-jwt-secret-at-least-32-bytes"
        private const val MISSING_ROLE = "__MISSING__"
    }
}
