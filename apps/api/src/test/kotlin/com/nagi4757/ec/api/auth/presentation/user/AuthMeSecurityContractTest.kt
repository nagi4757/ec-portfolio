package com.nagi4757.ec.api.auth.presentation.user

import com.nagi4757.ec.api.auth.application.AuthService
import com.nagi4757.ec.api.auth.domain.model.User
import com.nagi4757.ec.api.auth.domain.model.UserRole
import com.nagi4757.ec.api.common.logging.CorrelationIdContext
import com.nagi4757.ec.api.common.security.JwtTokenProvider
import org.apache.ibatis.mapping.Environment
import org.apache.ibatis.session.Configuration
import org.apache.ibatis.session.SqlSessionFactory
import org.apache.ibatis.transaction.jdbc.JdbcTransactionFactory
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.context.TestConfiguration
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Import
import org.springframework.http.MediaType
import org.springframework.test.context.ActiveProfiles
import org.springframework.test.context.bean.override.mockito.MockitoBean
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get
import javax.sql.DataSource

@ActiveProfiles("test")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK)
@AutoConfigureMockMvc
@Import(AuthMeSecurityContractTest.TestApiConfig::class)
class AuthMeSecurityContractTest(
    @Autowired private val mockMvc: MockMvc,
    @Autowired private val jwtTokenProvider: JwtTokenProvider
) {
    @MockitoBean
    private lateinit var authService: AuthService

    @Test
    fun `missing authorization returns the common unauthorized response`() {
        assertUnauthorized()
    }

    @Test
    fun `malformed JWT returns unauthorized`() {
        assertUnauthorized("malformed-jwt")
    }

    @Test
    fun `JWT with an invalid signature returns unauthorized`() {
        val token = JwtTokenProvider(INVALID_SIGNATURE_SECRET, TOKEN_EXPIRATION_SECONDS)
            .createAccessToken(USER_ID, USER_EMAIL, UserRole.USER.name)

        assertUnauthorized(token)
    }

    @Test
    fun `expired JWT returns unauthorized`() {
        val token = JwtTokenProvider(TEST_SECRET, EXPIRED_TOKEN_SECONDS)
            .createAccessToken(USER_ID, USER_EMAIL, UserRole.USER.name)

        assertUnauthorized(token)
    }

    @Test
    fun `USER JWT with an existing user returns the authenticated user`() {
        assertAuthenticatedUser(UserRole.USER, USER_ID, USER_EMAIL)
    }

    @Test
    fun `ADMIN JWT with an existing admin user returns the authenticated admin`() {
        assertAuthenticatedUser(UserRole.ADMIN, ADMIN_ID, ADMIN_EMAIL)
    }

    @Test
    fun `valid JWT with a missing database user returns not found`() {
        val token = jwtTokenProvider.createAccessToken(
            userId = MISSING_USER_ID,
            email = "missing@example.test",
            role = UserRole.USER.name
        )

        mockMvc.get(CANONICAL_PATH) {
            header("Authorization", bearerToken(token))
            header(CorrelationIdContext.HEADER_NAME, CORRELATION_ID)
        }.andExpect {
            status { isNotFound() }
            content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
            jsonPath("$.status") { value(404) }
            jsonPath("$.code") { value("RESOURCE_NOT_FOUND") }
            jsonPath("$.path") { value(CANONICAL_PATH) }
            jsonPath("$.correlationId") { value(CORRELATION_ID) }
            header { string(CorrelationIdContext.HEADER_NAME, CORRELATION_ID) }
        }
    }

    @Test
    fun `old public auth path is no longer a business endpoint`() {
        mockMvc.get(OLD_PATH) {
            header(CorrelationIdContext.HEADER_NAME, CORRELATION_ID)
        }.andExpect {
            status { isNotFound() }
            content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
            jsonPath("$.status") { value(404) }
            jsonPath("$.code") { value("RESOURCE_NOT_FOUND") }
            jsonPath("$.path") { value(OLD_PATH) }
            jsonPath("$.correlationId") { value(CORRELATION_ID) }
            header { string(CorrelationIdContext.HEADER_NAME, CORRELATION_ID) }
        }
    }

    private fun assertUnauthorized(token: String? = null) {
        mockMvc.get(CANONICAL_PATH) {
            token?.let { header("Authorization", bearerToken(it)) }
            header(CorrelationIdContext.HEADER_NAME, CORRELATION_ID)
        }.andExpect {
            status { isUnauthorized() }
            content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
            jsonPath("$.status") { value(401) }
            jsonPath("$.code") { value("UNAUTHORIZED") }
            jsonPath("$.message") { value("Authentication is required") }
            jsonPath("$.path") { value(CANONICAL_PATH) }
            jsonPath("$.correlationId") { value(CORRELATION_ID) }
            jsonPath("$.fieldErrors") { isArray() }
            header { string(CorrelationIdContext.HEADER_NAME, CORRELATION_ID) }
        }
    }

    private fun assertAuthenticatedUser(role: UserRole, userId: Long, email: String) {
        val user = User(
            id = userId,
            email = email,
            passwordHash = "test-only-password-hash",
            name = role.name,
            role = role
        )
        `when`(authService.getById(userId)).thenReturn(user)
        val token = jwtTokenProvider.createAccessToken(userId, email, role.name)

        mockMvc.get(CANONICAL_PATH) {
            header("Authorization", bearerToken(token))
        }.andExpect {
            status { isOk() }
            content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
            jsonPath("$.id") { value(userId) }
            jsonPath("$.email") { value(email) }
            jsonPath("$.name") { value(role.name) }
            jsonPath("$.role") { value(role.name) }
            header { exists(CorrelationIdContext.HEADER_NAME) }
        }
    }

    private fun bearerToken(token: String): String = "Bearer $token"

    @TestConfiguration
    class TestApiConfig {
        @Bean
        fun sqlSessionFactory(): SqlSessionFactory =
            mock(SqlSessionFactory::class.java).apply {
                val configuration = Configuration().apply {
                    environment = Environment("test", JdbcTransactionFactory(), mock(DataSource::class.java))
                }
                `when`(this.configuration).thenReturn(configuration)
            }
    }

    companion object {
        private const val CANONICAL_PATH = "/api/user/auth/me"
        private const val OLD_PATH = "/api/public/auth/me"
        private const val USER_ID = 100L
        private const val ADMIN_ID = 200L
        private const val MISSING_USER_ID = 999L
        private const val USER_EMAIL = "user@example.test"
        private const val ADMIN_EMAIL = "admin@example.test"
        private const val CORRELATION_ID = "9f25a986-9864-4fc2-a9ec-42e1c439c8bc"
        private const val TEST_SECRET = "test-only-dummy-jwt-secret-at-least-32-bytes-long"
        private const val INVALID_SIGNATURE_SECRET = "different-test-only-jwt-secret-at-least-32-bytes-long"
        private const val TOKEN_EXPIRATION_SECONDS = 3_600L
        private const val EXPIRED_TOKEN_SECONDS = -1L
    }
}
