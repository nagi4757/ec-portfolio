import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useParams } from 'react-router-dom'
import { OrderAPI } from '@/features/orders/api'
import { RefundAPI } from '@/features/refund/api'
import { clearRefundKey, resolveRefundKey } from '@/features/refund/idempotency'
import { isApiErrorCode } from '@/lib/api'
import { ORDER_STATUS_TRANSLATION_KEY } from '@/types/order'
import type { Order, OrderStatus } from '@/types/order'
import { isDirectlyCancellable, isRefundable } from '@/types/refund'

const statusColor: Record<OrderStatus, string> = {
    LEGACY_UNPAID: '#64748b',
    // Distinct from PENDING: the payment outcome is still unknown here.
    PAYMENT_PENDING: '#0369a1',
    PENDING: '#b7791f',
    PREPARING: '#2b6cb0',
    // A refund is in flight; the order is neither paid-and-ready nor cancelled.
    REFUND_PENDING: '#0369a1',
    SHIPPED: '#6b46c1',
    DELIVERED: '#276749',
    CANCELLED: '#c53030',
}

type CancelFeedback = 'success' | 'invalidOrderTransition' | 'orderNotFound' | 'failed'

type RefundFeedback =
    | 'success'
    | 'pendingConfirmation'
    | 'failed'
    | 'inProgress'
    | 'notEligible'
    | 'error'

const refundFeedbackTranslationKey: Record<RefundFeedback, string> = {
    success: 'store.order.refund.success',
    pendingConfirmation: 'store.order.refund.pendingNotice',
    failed: 'store.order.refund.failed',
    inProgress: 'store.order.refund.inProgress',
    notEligible: 'store.order.refund.notEligible',
    error: 'store.order.cancel.failed',
}

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
    const [refunding, setRefunding] = useState(false)
    const [refundFeedback, setRefundFeedback] = useState<RefundFeedback | null>(null)

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

    async function refundOrder() {
        if (!id || !order) return
        // REFUND_PENDING is included: that is the re-check path for a refund whose
        // outcome was never confirmed, and it continues the same attempt.
        const resuming = order.status === 'REFUND_PENDING'
        if (!resuming && !isRefundable(order.status)) return
        // Only a first request asks for confirmation; re-checking an unresolved
        // refund is not a new decision.
        if (!resuming && !window.confirm(t('store.order.refund.confirm'))) return

        const orderId = Number(id)
        setRefunding(true)
        setRefundFeedback(null)
        // The same key is reused for every retry of this order's refund. Disabling
        // the button is only a courtesy; the server's order lock and the refund
        // attempt's idempotency are what actually prevent a second refund.
        const idempotencyKey = resolveRefundKey(orderId)

        try {
            const result = await RefundAPI.refund(orderId, idempotencyKey)

            if (result.outcome === 'PENDING_CONFIRMATION') {
                // Not a success. The money may not have moved, so the order is not
                // cancelled and the key is kept for an explicit re-check.
                setOrder(result.order)
                setRefundFeedback('pendingConfirmation')
                return
            }

            clearRefundKey(orderId)
            // Re-read rather than trusting the response alone, so the page shows the
            // order exactly as the server now holds it.
            setOrder(await OrderAPI.get(orderId).catch(() => result.order))
            setRefundFeedback('success')
        } catch (cause) {
            if (isApiErrorCode(cause, 'REFUND_FAILED')) {
                // A known refusal is terminal: the next attempt is a new refund.
                clearRefundKey(orderId)
                setRefundFeedback('failed')
                OrderAPI.get(orderId).then(setOrder).catch(() => undefined)
            } else if (isApiErrorCode(cause, 'REFUND_ATTEMPT_IN_PROGRESS')) {
                // Another refund for this order is unsettled. Minting a new key here
                // would be exactly the double-refund this guard exists to stop.
                setRefundFeedback('inProgress')
            } else if (isApiErrorCode(cause, 'REFUND_NOT_ELIGIBLE')) {
                setRefundFeedback('notEligible')
                OrderAPI.get(orderId).then(setOrder).catch(() => undefined)
            } else {
                // Network and unknown failures leave the key in place: the refund may
                // have reached the server, so a retry must be the same attempt.
                setRefundFeedback('error')
            }
        } finally {
            setRefunding(false)
        }
    }

    async function cancelOrder() {
        // PENDING now means paid. Only an unpaid legacy order may still be
        // cancelled; everything else needs a refund the system cannot issue yet.
        if (!id || !order || !isDirectlyCancellable(order.status)) return
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
                                {t('store.money.amount', { amount: item.price })} × {item.quantity}
                            </div>
                        </div>
                        <div style={{ fontWeight: 700 }}>{t('store.money.amount', { amount: item.lineAmount })}</div>
                    </div>
                ))}
            </div>

            <div style={{ marginTop: 20, borderTop: '1px solid #eee', paddingTop: 16, textAlign: 'right' }}>
                <span style={{ fontSize: 18, fontWeight: 700 }}>
                    합계: {t('store.money.amount', { amount: order.totalAmount })}
                </span>
            </div>

            {isRefundable(order.status) && (
                <div style={{ marginTop: 20, textAlign: 'right' }}>
                    <button
                        type="button"
                        disabled={refunding}
                        onClick={refundOrder}
                        style={{
                            border: 'none',
                            borderRadius: 6,
                            padding: '9px 16px',
                            background: refunding ? '#a0aec0' : '#c53030',
                            color: '#fff',
                            cursor: refunding ? 'not-allowed' : 'pointer',
                            fontWeight: 600,
                        }}
                    >
                        {refunding
                            ? t('store.order.actions.refunding')
                            : t('store.order.actions.refund')}
                    </button>
                </div>
            )}
            {order.status === 'REFUND_PENDING' && (
                <div style={{ marginTop: 20, textAlign: 'right' }}>
                    <button
                        type="button"
                        disabled={refunding}
                        onClick={refundOrder}
                        style={{
                            border: '1px solid #0369a1',
                            borderRadius: 6,
                            padding: '9px 16px',
                            background: '#fff',
                            color: '#0369a1',
                            cursor: refunding ? 'not-allowed' : 'pointer',
                            fontWeight: 600,
                        }}
                    >
                        {refunding
                            ? t('store.order.actions.refunding')
                            : t('store.order.refund.recheck')}
                    </button>
                </div>
            )}
            {refundFeedback && (
                <div
                    role={refundFeedback === 'success' ? 'status' : 'alert'}
                    style={{
                        marginTop: 12,
                        color: refundFeedback === 'success' ? '#276749' : '#c53030',
                    }}
                >
                    {t(refundFeedbackTranslationKey[refundFeedback])}
                </div>
            )}

            {isDirectlyCancellable(order.status) && (
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
