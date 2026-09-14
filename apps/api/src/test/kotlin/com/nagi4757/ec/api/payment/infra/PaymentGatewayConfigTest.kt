package com.nagi4757.ec.api.payment.infra

import com.nagi4757.ec.api.payment.application.PaymentGateway
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.boot.test.context.runner.ApplicationContextRunner

/**
 * A gateway that approves payments on request must never be reachable by accident.
 * These tests pin the binding to explicit configuration.
 */
class PaymentGatewayConfigTest {
    private val runner = ApplicationContextRunner()
        .withUserConfiguration(PaymentGatewayConfig::class.java)

    @Test
    fun `binds the mock gateway only when the provider is explicitly set to mock`() {
        runner.withPropertyValues("app.payment.provider=mock").run { context ->
            assertThat(context).hasSingleBean(PaymentGateway::class.java)
            assertThat(context.getBean(PaymentGateway::class.java)).isInstanceOf(MockPaymentGateway::class.java)
        }
    }

    @Test
    fun `fails to start when no payment provider is configured`() {
        // The important case: a forgotten property must stop the application rather
        // than silently fall back to a gateway that takes no money.
        runner.run { context ->
            assertThat(context).hasFailed()
            assertThat(context.startupFailure)
                .hasRootCauseMessage(
                    "No PaymentGateway is configured. Set app.payment.provider=mock to use the " +
                        "deterministic mock gateway, or register a real PaymentGateway bean. " +
                        "Checkout will not start without one."
                )
        }
    }

    @Test
    fun `fails to start when the provider is set to something unknown`() {
        runner.withPropertyValues("app.payment.provider=payjp").run { context ->
            assertThat(context).hasFailed()
            assertThat(context.startupFailure).rootCause()
                .hasMessageContaining("No PaymentGateway is configured")
        }
    }

    @Test
    fun `the mock binding is gated on a property rather than on bean absence`() {
        // ConditionalOnMissingBean would make the mock the default for every
        // environment, which is the failure mode this guards against.
        val condition = PaymentGatewayConfig::class.java
            .getDeclaredMethod("mockPaymentGateway")
            .getAnnotation(ConditionalOnProperty::class.java)

        assertThat(condition).isNotNull
        assertThat(condition.prefix).isEqualTo("app.payment")
        assertThat(condition.name).containsExactly("provider")
        assertThat(condition.havingValue).isEqualTo("mock")
        // matchIfMissing defaults to false: an absent property must not bind the mock.
        assertThat(condition.matchIfMissing).isFalse()
    }

    @Test
    fun `production configuration does not enable the mock gateway`() {
        val production = PaymentGatewayConfigTest::class.java
            .getResourceAsStream("/application-prod.properties")
            ?.bufferedReader()
            ?.readText()
            ?: error("application-prod.properties is missing")

        assertThat(production).doesNotContain("app.payment.provider=mock")
    }
}
