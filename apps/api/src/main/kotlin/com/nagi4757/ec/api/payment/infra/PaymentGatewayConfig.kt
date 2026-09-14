package com.nagi4757.ec.api.payment.infra

import com.nagi4757.ec.api.payment.application.PaymentGateway
import org.springframework.beans.factory.ObjectProvider
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration

/**
 * Selects the payment gateway from explicit configuration.
 *
 * The mock gateway is bound only when `app.payment.provider` is set to `mock`. It is
 * deliberately not a default: a gateway that approves payments on demand must never
 * become active because a property was forgotten. An environment with no provider
 * configured fails to start, which is a loud, early failure rather than a service
 * that silently takes no money.
 */
@Configuration
class PaymentGatewayConfig {
    @Bean
    @ConditionalOnProperty(prefix = "app.payment", name = ["provider"], havingValue = MOCK_PROVIDER)
    fun mockPaymentGateway(): PaymentGateway = MockPaymentGateway()

    /**
     * Turns a missing or unknown provider into a message that says what to fix.
     * Without it the context still fails, but only with an unresolved dependency on
     * [PaymentGateway] further down the graph.
     */
    @Bean
    fun paymentGatewayPresenceCheck(
        gateways: ObjectProvider<PaymentGateway>
    ): PaymentGatewayPresenceCheck = PaymentGatewayPresenceCheck(gateways)
}

class PaymentGatewayPresenceCheck(gateways: ObjectProvider<PaymentGateway>) {
    init {
        gateways.ifAvailable ?: error(
            "No PaymentGateway is configured. Set app.payment.provider=$MOCK_PROVIDER to use the " +
                "deterministic mock gateway, or register a real PaymentGateway bean. " +
                "Checkout will not start without one."
        )
    }
}

internal const val MOCK_PROVIDER = "mock"
