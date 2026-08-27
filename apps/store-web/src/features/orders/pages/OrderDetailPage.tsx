import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useParams } from 'react-router-dom'
import { OrderAPI } from '@/features/orders/api'
import { isApiErrorCode } from '@/lib/api'
import { ORDER_STATUS_TRANSLATION_KEY } from '@/types/order'
import type { Order, OrderStatus } from '@/types/order'

const statusColor: Record<OrderStatus, string> = {
    PENDING: '#b7791f',
    PREPARING: '#2b6cb0',
    SHIPPED: '#6b46c1',
    DELIVERED: '#276749',
    CANCELLED: '#c53030',
}

type CancelFeedback = 'success' | 'invalidOrderTransition' | 'orderNotFound' | 'failed'

const cancelFeedbackTranslationKey: Record<CancelFeedback, string> = {
    success: 'store.order.cancel.success',
    invalidOrderTransition: 'store.errors.api.invalidOrderTransition',
    orderNotFound: 'store.errors.api.orderNotFound',
    failed: 'store.order.cancel.failed',
}

export default function OrderDetailPage() {
    const { t } = useTranslation()
    const { id } = useParams()
    const [order, setOrder] = useState<Order | null>(null)
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState<string | null>(null)
    const [cancelling, setCancelling] = useState(false)
    const [cancelFeedback, setCancelFeedback] = useState<CancelFeedback | null>(null)

    useEffect(() => {
        if (!id) return
        setLoading(true)
        setError(null)
        OrderAPI.get(Number(id))
            .then(setOrder)
            .catch((cause) => setError(
                isApiErrorCode(cause, 'ORDER_NOT_FOUND')
                    ? t('store.errors.api.orderNotFound')
                    : t('store.order.loadFailed')
            ))
            .finally(() => setLoading(false))
    }, [id, t])

    async function cancelOrder() {
        if (!id || !order || order.status !== 'PENDING') return
        if (!window.confirm(t('store.order.cancel.confirm'))) return

        setCancelling(true)
        setCancelFeedback(null)
        try {
            const updated = await OrderAPI.cancel(Number(id))
            setOrder(updated)
            setCancelFeedback('success')
        } catch (cause) {
            if (isApiErrorCode(cause, 'INVALID_ORDER_TRANSITION')) {
                setCancelFeedback('invalidOrderTransition')
                OrderAPI.get(Number(id)).then(setOrder).catch(() => undefined)
            } else if (isApiErrorCode(cause, 'ORDER_NOT_FOUND')) {
                setCancelFeedback('orderNotFound')
            } else {
                setCancelFeedback('failed')
            }
        } finally {
            setCancelling(false)
        }
    }

    if (loading) return <div style={{ padding: 24 }}>Loading...</div>
    if (error)   return <div style={{ padding: 24, color: 'crimson' }}>Error: {error}</div>
    if (!order)  return <div style={{ padding: 24 }}>주문을 찾을 수 없습니다.</div>

    return (
        <div style={{ padding: 'clamp(12px, 4vw, 24px)', maxWidth: 800, margin: '0 auto' }}>
            <Link to="/orders" style={{ display: 'inline-block', marginBottom: 16 }}>← 주문 내역</Link>

            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16, gap: 10, flexWrap: 'wrap' }}>
                <h1 style={{ margin: 0 }}>주문 #{order.id}</h1>
                <span style={{
                    display: 'inline-block',
                    padding: '4px 14px',
                    borderRadius: 9999,
                    background: statusColor[order.status] ?? '#555',
                    color: '#fff',
                    fontSize: 13,
                    fontWeight: 600,
                }}>
                    {t(ORDER_STATUS_TRANSLATION_KEY[order.status])}
                </span>
            </div>

            <div style={{ color: '#666', fontSize: 13, marginBottom: 20 }}>
                주문일시: {order.createdAt ?? '-'}
            </div>

            <section style={shippingStyle}>
                <h2 style={{ marginTop: 0 }}>{t('store.shipping.title')}</h2>
                {order.shippingAddress ? (
                    <address style={{ fontStyle: 'normal', lineHeight: 1.7 }}>
                        <div>{order.shippingAddress.recipientName}</div>
                        <div>〒{order.shippingAddress.postalCode}</div>
                        <div>
                            {order.shippingAddress.prefecture} {order.shippingAddress.city}
                        </div>
                        <div>{order.shippingAddress.addressLine1}</div>
                        {order.shippingAddress.addressLine2 && <div>{order.shippingAddress.addressLine2}</div>}
                        <div>{order.shippingAddress.phoneNumber}</div>
                    </address>
                ) : (
                    <div style={{ color: '#777' }}>{t('store.shipping.legacyUnavailable')}</div>
                )}
            </section>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                {order.items.map((item) => (
                    <div key={item.productId} style={rowStyle}>
                        <div style={{ flex: 1 }}>
                            <div style={{ fontWeight: 600 }}>{item.name}</div>
                            <div style={{ color: '#555', fontSize: 14 }}>
                                {item.price.toLocaleString()}원 × {item.quantity}
                            </div>
                        </div>
                        <div style={{ fontWeight: 700 }}>{item.lineAmount.toLocaleString()}원</div>
                    </div>
                ))}
            </div>

            <div style={{ marginTop: 20, borderTop: '1px solid #eee', paddingTop: 16, textAlign: 'right' }}>
                <span style={{ fontSize: 18, fontWeight: 700 }}>
                    합계: {order.totalAmount.toLocaleString()}원
                </span>
            </div>

            {order.status === 'PENDING' && (
                <div style={{ marginTop: 20, textAlign: 'right' }}>
                    <button
                        type="button"
                        disabled={cancelling}
                        onClick={cancelOrder}
                        style={{
                            border: 'none',
                            borderRadius: 6,
                            padding: '9px 16px',
                            background: cancelling ? '#a0aec0' : '#c53030',
                            color: '#fff',
                            cursor: cancelling ? 'not-allowed' : 'pointer',
                            fontWeight: 600,
                        }}
                    >
                        {cancelling
                            ? t('store.order.actions.cancelling')
                            : t('store.order.actions.cancel')}
                    </button>
                </div>
            )}
            {cancelFeedback && (
                <div
                    role={cancelFeedback === 'success' ? 'status' : 'alert'}
                    style={{
                        marginTop: 12,
                        color: cancelFeedback === 'success' ? '#276749' : '#c53030',
                        textAlign: 'right',
                    }}
                >
                    {t(cancelFeedbackTranslationKey[cancelFeedback])}
                </div>
            )}
        </div>
    )
}

const rowStyle: React.CSSProperties = {
    border: '1px solid #eee',
    borderRadius: 8,
    padding: '12px 16px',
    display: 'flex',
    alignItems: 'center',
    flexWrap: 'wrap',
    gap: 12,
    background: '#fff',
}

const shippingStyle: React.CSSProperties = {
    border: '1px solid #eee',
    borderRadius: 8,
    padding: '12px 16px',
    marginBottom: 20,
    background: '#fff',
}
