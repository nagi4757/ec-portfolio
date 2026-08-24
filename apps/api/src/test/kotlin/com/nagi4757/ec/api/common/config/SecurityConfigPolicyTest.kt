package com.nagi4757.ec.api.common.config

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
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get
import org.springframework.test.web.servlet.options
import org.springframework.test.context.ActiveProfiles
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RestController
import javax.sql.DataSource

@ActiveProfiles("test")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK)
@AutoConfigureMockMvc
@Import(SecurityConfigPolicyTest.TestApiConfig::class)
class SecurityConfigPolicyTest(
    @Autowired private val mockMvc: MockMvc,
    @Autowired private val jwtTokenProvider: JwtTokenProvider
) {
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
        mockMvc.get("/api/user/ping")
            .andExpect {
                status { isUnauthorized() }
                content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
                jsonPath("$.status") { value(401) }
                jsonPath("$.code") { value("UNAUTHORIZED") }
                jsonPath("$.message") { value("Authentication is required") }
                jsonPath("$.path") { value("/api/user/ping") }
                jsonPath("$.fieldErrors") { isArray() }
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
        }.andExpect {
            status { isForbidden() }
            content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
            jsonPath("$.status") { value(403) }
            jsonPath("$.code") { value("ACCESS_DENIED") }
            jsonPath("$.message") { value("Access is denied") }
            jsonPath("$.path") { value("/api/admin/ping") }
            jsonPath("$.fieldErrors") { isArray() }
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
}
