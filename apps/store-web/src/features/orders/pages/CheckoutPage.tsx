import { useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate } from 'react-router-dom'
import { CartAPI } from '@/features/cart/api'
import { CheckoutAPI } from '@/features/checkout/api'
import { cartSignature, clearIdempotencyKey, resolveIdempotencyKey } from '@/features/checkout/idempotency'
import { isApiErrorCode } from '@/lib/api'
import { authStore } from '@/lib/authStore'
import { cartStore } from '@/lib/cartStore'
import type { CartResponse } from '@/types/cart'
import { DEMO_PAYMENT_METHODS, DEMO_PAYMENT_METHOD_TRANSLATION_KEY } from '@/types/checkout'
import type { DemoPaymentMethodId } from '@/types/checkout'
import type { ShippingAddress } from '@/types/order'

const EMPTY_ADDRESS: ShippingAddress = {
    recipientName: '',
    postalCode: '',
    prefecture: '',
    city: '',
    addressLine1: '',
    addressLine2: '',
    phoneNumber: '',
}

export default function CheckoutPage() {
    const { t } = useTranslation()
    const navigate = useNavigate()
    const [cart, setCart] = useState<CartResponse | null>(null)
    const [address, setAddress] = useState<ShippingAddress>(EMPTY_ADDRESS)
    const [loading, setLoading] = useState(true)
    const [submitting, setSubmitting] = useState(false)
    const [errorKey, setErrorKey] = useState<string | null>(null)
    const [paymentMethodId, setPaymentMethodId] = useState<DemoPaymentMethodId>('mock:success')
    // An unconfirmed charge is not an error and not a success. It gets its own state
    // so the page can offer a re-check without pretending the order is paid.
    const [pendingConfirmation, setPendingConfirmation] = useState(false)

    useEffect(() => {
        if (!authStore.isLoggedIn()) {
            setLoading(false)
            return
        }

        CartAPI.get()
            .then((data) => {
                setCart(data)
                cartStore.setTotalQuantity(data.totalQuantity)
            })
            .catch(() => setErrorKey('store.checkout.loadFailed'))
            .finally(() => setLoading(false))
    }, [])

    function updateAddress(field: keyof ShippingAddress, value: string) {
        setAddress((current) => ({ ...current, [field]: value }))
    }

    async function submitCheckout(event: FormEvent<HTMLFormElement>) {
        event.preventDefault()
        if (!cart) return

        setSubmitting(true)
        setErrorKey(null)

        const shippingAddress: ShippingAddress = {
            ...address,
            addressLine2: address.addressLine2?.trim() || null,
        }
        // The same key is reused for every retry of this attempt. A new one is only
        // minted when the purchase itself changes, which resolveIdempotencyKey
        // decides from the payment method, address and cart lines.
        const idempotencyKey = resolveIdempotencyKey({
            paymentMethodId,
            shippingAddress,
            cartSignature: cartSignature(cart.items),
        })

        try {
            const result = await CheckoutAPI.submit(
                { shippingAddress, paymentMethodId },
                idempotencyKey,
            )

            if (result.outcome === 'PENDING_CONFIRMATION') {
                // Not a success. The order is reserved, the charge is unresolved, and
                // the key is kept so a re-check continues the same attempt.
                setPendingConfirmation(true)
                return
            }

            clearIdempotencyKey()
            cartStore.setTotalQuantity(0)
            navigate(`/orders/${result.order.id}`, { replace: true })
        } catch (cause) {
            // Declined and failed are terminal: the next attempt is a new payment and
            // must not reuse this key.
            if (isApiErrorCode(cause, 'PAYMENT_DECLINED')) {
                clearIdempotencyKey()
                setPendingConfirmation(false)
                setErrorKey('store.checkout.declined')
            } else if (isApiErrorCode(cause, 'PAYMENT_FAILED')) {
                clearIdempotencyKey()
                setPendingConfirmation(false)
                setErrorKey('store.checkout.failed')
            } else if (isApiErrorCode(cause, 'PAYMENT_IDEMPOTENCY_CONFLICT')) {
                // The key was reused for a different purchase. Minting a new one here
                // would hide that from the customer, so the change is surfaced instead.
                setErrorKey('store.checkout.idempotencyConflict')
            } else if (isApiErrorCode(cause, 'PRODUCT_NOT_AVAILABLE')) {
                setErrorKey('store.errors.api.productNotAvailable')
            } else if (isApiErrorCode(cause, 'INSUFFICIENT_STOCK')) {
                setErrorKey('store.stock.insufficient')
            } else {
                // Network failures and unknown errors leave the key in place: the
                // charge may have reached the server, so a retry must be the same
                // attempt rather than a second payment.
                setErrorKey('store.checkout.submitFailed')
            }
        } finally {
            setSubmitting(false)
        }
    }

    if (!authStore.isLoggedIn()) {
        return (
            <main style={pageStyle}>
                <h1>{t('store.checkout.title')}</h1>
                <p>{t('store.checkout.loginRequired')}</p>
                <button type="button" onClick={() => navigate('/login')}>{t('actions.login')}</button>
            </main>
        )
    }
    if (loading) return <main style={pageStyle}>Loading...</main>
    if (!cart) {
        return (
            <main style={pageStyle}>
                <h1>{t('store.checkout.title')}</h1>
                <p role="alert" style={{ color: 'crimson' }}>{t(errorKey ?? 'store.checkout.loadFailed')}</p>
                <Link to="/cart">{t('store.checkout.backToCart')}</Link>
            </main>
        )
    }
    if (cart.items.length === 0) {
        return (
            <main style={pageStyle}>
                <h1>{t('store.checkout.title')}</h1>
                <p>{t('store.checkout.emptyCart')}</p>
                <Link to="/cart">{t('store.checkout.backToCart')}</Link>
            </main>
        )
    }
    const hasUnavailableItems = cart.items.some((item) => !item.available)

    return (
        <main style={pageStyle}>
            <Link to="/cart" style={{ display: 'inline-block', marginBottom: 16 }}>
                ← {t('store.checkout.backToCart')}
            </Link>
            <h1 style={{ marginTop: 0 }}>{t('store.checkout.title')}</h1>

            <section style={summaryStyle}>
                <h2 style={{ marginTop: 0 }}>{t('store.checkout.orderSummary')}</h2>
                {cart.items.map((item) => (
                    <div key={item.productId} style={summaryRowStyle}>
                        <span>{item.name} × {item.quantity}</span>
                        <strong>{t('store.money.amount', { amount: item.lineAmount })}</strong>
                    </div>
                ))}
                <div style={{ ...summaryRowStyle, borderTop: '1px solid #e5e7eb', paddingTop: 12 }}>
                    <strong>{t('store.checkout.total')}</strong>
                    <strong>{t('store.money.amount', { amount: cart.totalAmount })}</strong>
                </div>
            </section>

            <form onSubmit={submitCheckout} style={formStyle}>
                <h2 style={{ margin: 0 }}>{t('store.shipping.title')}</h2>
                <AddressField
                    label={t('store.shipping.recipientName')}
                    value={address.recipientName}
                    onChange={(value) => updateAddress('recipientName', value)}
                    maxLength={100}
                    autoComplete="name"
                />
                <AddressField
                    label={t('store.shipping.postalCode')}
                    value={address.postalCode}
                    onChange={(value) => updateAddress('postalCode', value)}
                    maxLength={8}
                    pattern="[0-9]{3}-?[0-9]{4}"
                    placeholder="100-0001"
                    autoComplete="postal-code"
                />
                <AddressField
                    label={t('store.shipping.prefecture')}
                    value={address.prefecture}
                    onChange={(value) => updateAddress('prefecture', value)}
                    maxLength={50}
                    autoComplete="address-level1"
                />
                <AddressField
                    label={t('store.shipping.city')}
                    value={address.city}
                    onChange={(value) => updateAddress('city', value)}
                    maxLength={100}
                    autoComplete="address-level2"
                />
                <AddressField
                    label={t('store.shipping.addressLine1')}
                    value={address.addressLine1}
                    onChange={(value) => updateAddress('addressLine1', value)}
                    maxLength={200}
                    autoComplete="address-line1"
                />
                <AddressField
                    label={t('store.shipping.addressLine2')}
                    value={address.addressLine2 ?? ''}
                    onChange={(value) => updateAddress('addressLine2', value)}
                    maxLength={200}
                    required={false}
                    autoComplete="address-line2"
                />
                <AddressField
                    label={t('store.shipping.phoneNumber')}
                    value={address.phoneNumber}
                    onChange={(value) => updateAddress('phoneNumber', value)}
                    maxLength={20}
                    pattern={'[0-9+\\(\\) \\-]+'}
                    autoComplete="tel"
                />

                <fieldset style={demoPaymentStyle}>
                    <legend style={{ fontWeight: 700 }}>{t('store.checkout.demoPayment.title')}</legend>
                    <p style={demoNoticeStyle}>{t('store.checkout.demoPayment.notice')}</p>
                    {DEMO_PAYMENT_METHODS.map((method) => (
                        <label key={method} style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                            <input
                                type="radio"
                                name="paymentMethodId"
                                value={method}
                                checked={paymentMethodId === method}
                                onChange={() => setPaymentMethodId(method)}
                            />
                            <span>{t(DEMO_PAYMENT_METHOD_TRANSLATION_KEY[method])}</span>
                            <code style={{ color: '#64748b', fontSize: 13 }}>{method}</code>
                        </label>
                    ))}
                </fieldset>

                {pendingConfirmation && (
                    <div role="status" style={pendingStyle}>
                        <strong>{t('store.checkout.pendingConfirmation.title')}</strong>
                        <p style={{ margin: '6px 0 0' }}>{t('store.checkout.pendingConfirmation.description')}</p>
                    </div>
                )}
                {hasUnavailableItems && (
                    <div role="alert" style={{ color: 'crimson' }}>{t('store.checkout.unavailableItems')}</div>
                )}
                {errorKey && <div role="alert" style={{ color: 'crimson' }}>{t(errorKey)}</div>}
                <button type="submit" disabled={submitting || hasUnavailableItems} style={submitStyle}>
                    {submitting
                        ? t('store.checkout.submitting')
                        : pendingConfirmation
                            ? t('store.checkout.pendingConfirmation.retry')
                            : t('store.checkout.submit')}
                </button>
            </form>
        </main>
    )
}

type AddressFieldProps = {
    label: string
    value: string
    onChange: (value: string) => void
    maxLength: number
    required?: boolean
    pattern?: string
    placeholder?: string
    autoComplete?: string
}

function AddressField({
    label,
    value,
    onChange,
    maxLength,
    required = true,
    pattern,
    placeholder,
    autoComplete,
}: AddressFieldProps) {
    return (
        <label style={{ display: 'grid', gap: 5 }}>
            <span style={{ fontWeight: 600 }}>{label}{required ? ' *' : ''}</span>
            <input
                value={value}
                onChange={(event) => onChange(event.target.value)}
                required={required}
                maxLength={maxLength}
                pattern={pattern}
                placeholder={placeholder}
                autoComplete={autoComplete}
                style={inputStyle}
            />
        </label>
    )
}

const pageStyle: React.CSSProperties = {
    padding: 'clamp(12px, 4vw, 24px)',
    maxWidth: 760,
    margin: '0 auto',
}

const summaryStyle: React.CSSProperties = {
    border: '1px solid #e5e7eb',
    borderRadius: 10,
    padding: 16,
    marginBottom: 20,
    background: '#fff',
}

const summaryRowStyle: React.CSSProperties = {
    display: 'flex',
    justifyContent: 'space-between',
    gap: 12,
    padding: '6px 0',
}

const formStyle: React.CSSProperties = {
    display: 'grid',
    gap: 14,
    border: '1px solid #e5e7eb',
    borderRadius: 10,
    padding: 16,
    background: '#fff',
}

const inputStyle: React.CSSProperties = {
    border: '1px solid #cbd5e1',
    borderRadius: 6,
    padding: '9px 10px',
    fontSize: 15,
}

const demoPaymentStyle: React.CSSProperties = {
    display: 'grid',
    gap: 8,
    border: '1px dashed #f59e0b',
    borderRadius: 8,
    padding: 12,
    background: '#fffbeb',
}

const demoNoticeStyle: React.CSSProperties = {
    margin: 0,
    fontSize: 13,
    color: '#92400e',
}

const pendingStyle: React.CSSProperties = {
    border: '1px solid #0ea5e9',
    borderRadius: 8,
    padding: 12,
    background: '#f0f9ff',
    color: '#075985',
}

const submitStyle: React.CSSProperties = {
    border: 'none',
    borderRadius: 6,
    padding: '10px 16px',
    background: '#2b6cb0',
    color: '#fff',
    cursor: 'pointer',
    fontWeight: 700,
}
