import { useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate } from 'react-router-dom'
import { CartAPI } from '@/features/cart/api'
import { OrderAPI } from '@/features/orders/api'
import { isApiErrorCode } from '@/lib/api'
import { authStore } from '@/lib/authStore'
import { cartStore } from '@/lib/cartStore'
import type { CartResponse } from '@/types/cart'
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

    async function submitOrder(event: FormEvent<HTMLFormElement>) {
        event.preventDefault()
        setSubmitting(true)
        setErrorKey(null)
        try {
            const order = await OrderAPI.place({
                shippingAddress: {
                    ...address,
                    addressLine2: address.addressLine2?.trim() || null,
                },
            })
            cartStore.setTotalQuantity(0)
            navigate(`/orders/${order.id}`, { replace: true })
        } catch (cause) {
            if (isApiErrorCode(cause, 'PRODUCT_NOT_AVAILABLE')) {
                setErrorKey('store.errors.api.productNotAvailable')
            } else if (isApiErrorCode(cause, 'INSUFFICIENT_STOCK')) {
                setErrorKey('store.stock.insufficient')
            } else {
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

            <form onSubmit={submitOrder} style={formStyle}>
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

                {hasUnavailableItems && (
                    <div role="alert" style={{ color: 'crimson' }}>{t('store.checkout.unavailableItems')}</div>
                )}
                {errorKey && <div role="alert" style={{ color: 'crimson' }}>{t(errorKey)}</div>}
                <button type="submit" disabled={submitting || hasUnavailableItems} style={submitStyle}>
                    {submitting ? t('store.checkout.submitting') : t('store.checkout.submit')}
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

const submitStyle: React.CSSProperties = {
    border: 'none',
    borderRadius: 6,
    padding: '10px 16px',
    background: '#2b6cb0',
    color: '#fff',
    cursor: 'pointer',
    fontWeight: 700,
}
