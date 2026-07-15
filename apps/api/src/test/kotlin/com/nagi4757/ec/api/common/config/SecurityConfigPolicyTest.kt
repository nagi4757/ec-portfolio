package com.nagi4757.ec.api.common.config

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
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RestController
import javax.sql.DataSource

@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.MOCK,
    properties = [
        "spring.autoconfigure.exclude=" +
            "org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration",
        "spring.flyway.enabled=false",
        "spring.main.lazy-initialization=true"
    ]
)
@AutoConfigureMockMvc
@Import(SecurityConfigPolicyTest.TestApiConfig::class)
class SecurityConfigPolicyTest(
    @Autowired private val mockMvc: MockMvc
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
    fun `user endpoint requires authentication`() {
        mockMvc.get("/api/user/ping")
            .andExpect {
                status { isUnauthorized() }
            }
    }

    @Test
    fun `admin endpoint requires authentication`() {
        mockMvc.get("/api/admin/ping")
            .andExpect {
                status { isUnauthorized() }
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




