package com.nagi4757.ec.api.payment.application

interface PaymentGateway {
    fun charge(request: ChargePaymentRequest): ChargePaymentResult

    /**
     * Returns money against a settled charge.
     *
     * **Contract the callers rely on:** an implementation must treat a repeated call
     * carrying the same `idempotencyKey` as the same refund, and answer with the
     * original outcome rather than returning the money again. Refund retries are not
     * exceptional here -- an unconfirmed result is re-driven, and reconciliation
     * resumes an attempt with the key stored on it -- so an implementation that
     * cannot honour this would refund a customer more than once.
     *
     * A real provider that does not offer that guarantee needs an authoritative
     * status lookup instead, and this resume path has to be revisited against it
     * before the adapter ships. The mock replays its stored result, so the guarantee
     * holds today but is not yet proven against anything external.
     */
    fun refund(request: RefundPaymentRequest): RefundPaymentResult
}
