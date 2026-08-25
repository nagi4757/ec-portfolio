package com.nagi4757.ec.api.common.config

import org.apache.ibatis.mapping.Environment
import org.apache.ibatis.session.Configuration
import org.apache.ibatis.session.SqlSessionFactory
import org.apache.ibatis.transaction.jdbc.JdbcTransactionFactory
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.beans.factory.annotation.Qualifier
import org.springframework.boot.actuate.health.Health
import org.springframework.boot.actuate.health.HealthIndicator
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.context.TestConfiguration
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Import
import org.springframework.test.context.ActiveProfiles
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get
import javax.sql.DataSource

@ActiveProfiles("test")
@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.MOCK,
    properties = [
        "management.endpoint.health.group.readiness.include=readinessState,db,redis"
    ]
)
@AutoConfigureMockMvc
@Import(ActuatorHealthPolicyTest.TestHealthConfig::class)
class ActuatorHealthPolicyTest @Autowired constructor(
    private val mockMvc: MockMvc,
    @Qualifier("db") private val dbHealthIndicator: TestHealthIndicator,
    @Qualifier("redis") private val redisHealthIndicator: TestHealthIndicator
) {
    @BeforeEach
    fun setUp() {
        dbHealthIndicator.currentHealth = Health.up().build()
        redisHealthIndicator.currentHealth = Health.up().build()
    }

    @Test
    fun `database down makes readiness unavailable while liveness stays up`() {
        dbHealthIndicator.currentHealth = Health.down().build()

        expectReadinessDownAndLivenessUp()
    }

    @Test
    fun `redis down makes readiness unavailable while liveness stays up`() {
        redisHealthIndicator.currentHealth = Health.down().build()

        expectReadinessDownAndLivenessUp()
    }

    private fun expectReadinessDownAndLivenessUp() {
        mockMvc.get("/actuator/health/readiness")
            .andExpect {
                status { isServiceUnavailable() }
                jsonPath("$.status") { value("DOWN") }
                jsonPath("$.components") { doesNotExist() }
                jsonPath("$.details") { doesNotExist() }
                jsonPath("$.db") { doesNotExist() }
                jsonPath("$.redis") { doesNotExist() }
            }

        mockMvc.get("/actuator/health/liveness")
            .andExpect {
                status { isOk() }
                jsonPath("$.status") { value("UP") }
                jsonPath("$.components") { doesNotExist() }
            }
    }

    @TestConfiguration
    class TestHealthConfig {
        @Bean("db")
        fun dbHealthIndicator(): TestHealthIndicator = TestHealthIndicator()

        @Bean("redis")
        fun redisHealthIndicator(): TestHealthIndicator = TestHealthIndicator()

        @Bean
        fun sqlSessionFactory(): SqlSessionFactory =
            mock(SqlSessionFactory::class.java).apply {
                val cfg = Configuration().apply {
                    environment = Environment("test", JdbcTransactionFactory(), mock(DataSource::class.java))
                }
                `when`(configuration).thenReturn(cfg)
            }
    }

    class TestHealthIndicator : HealthIndicator {
        var currentHealth: Health = Health.up().build()

        override fun health(): Health = currentHealth
    }
}
