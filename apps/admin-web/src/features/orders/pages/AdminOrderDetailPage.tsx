import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { OrderAdminApi } from '@/features/orders/api'
import { isApiErrorCode } from '@/lib/api'
import { ORDER_STATUS_TRANSITIONS, ORDER_STATUS_TRANSLATION_KEY } from '@/types/order'
import type { Order, OrderStatus } from '@/types/order'

const statusColor: Record<OrderStatus, string> = {
    PENDING: '#b7791f',
    PREPARING: '#2b6cb0',
    SHIPPED: '#6b46c1',
    DELIVERED: '#276749',
    CANCELLED: '#c53030',
}

export default function AdminOrderDetailPage() {
    const { t } = useTranslation()
    const { id } = useParams()
    const navigate = useNavigate()
    const [order, setOrder] = useState<Order | null>(null)
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState<string | null>(null)
    const [updating, setUpdating] = useState(false)

    const loadOrder = useCallback(async () => {
        if (!id) {
            setError('주문 ID가 없습니다.')
            setLoading(false)
            return
        }

        setLoading(true)
        setError(null)
        try {
            setOrder(await OrderAdminApi.get(Number(id)))
        } catch (cause) {
            setError(
                isApiErrorCode(cause, 'ORDER_NOT_FOUND')
                    ? t('admin.errors.api.orderNotFound')
                    : t('admin.order.loadFailed')
            )
        } finally {
            setLoading(false)
        }
    }, [id, t])

    useEffect(() => {
        void loadOrder()
    }, [loadOrder])

    async function changeStatus(nextStatus: OrderStatus) {
        if (!id || !order) return
        setUpdating(true)
        try {
            const updated = await OrderAdminApi.updateStatus(Number(id), nextStatus)
            setOrder(updated)
        } catch (cause) {
            if (isApiErrorCode(cause, 'INVALID_ORDER_TRANSITION')) {
                alert(t('admin.errors.api.invalidOrderTransition'))
                await loadOrder()
            } else if (isApiErrorCode(cause, 'ORDER_NOT_FOUND')) {
                alert(t('admin.errors.api.orderNotFound'))
                await loadOrder()
            } else {
                alert(t('admin.order.transition.failed'))
            }
        } finally {
            setUpdating(false)
        }
    }

    if (loading) return <div style={{ padding: 24 }}>Loading...</div>
    if (error) {
        return (
            <div style={{ padding: 24 }}>
                <div style={{ color: 'crimson', marginBottom: 12 }}>Error: {error}</div>
                <button onClick={() => navigate('/orders')}>목록으로 돌아가기</button>
            </div>
        )
    }
    if (!order) return <div style={{ padding: 24 }}>주문을 찾을 수 없습니다.</div>

    const nextStatuses = ORDER_STATUS_TRANSITIONS[order.status]

    return (
        <div style={{ padding: 'clamp(12px, 4vw, 24px)', maxWidth: 980, margin: '0 auto' }}>
            <Link to="/orders" style={{ display: 'inline-block', marginBottom: 12 }}>
                ← 주문 목록
            </Link>

            <h1 style={{ marginTop: 0 }}>주문 상세 #{order.id}</h1>
            <div style={summaryBox}>
                <div>
                    <div style={label}>주문 상태</div>
                    <span style={{ ...badgeStyle, background: statusColor[order.status] ?? '#555' }}>
                        {t(ORDER_STATUS_TRANSLATION_KEY[order.status])}
                    </span>
                </div>
                <div>
                    <div style={label}>주문일시</div>
                    <div>{order.createdAt ?? '-'}</div>
                </div>
                <div>
                    <div style={label}>총 금액</div>
                    <div style={{ fontWeight: 700 }}>{order.totalAmount.toLocaleString()}원</div>
                </div>
                <div>
                    <div style={label}>상태 변경</div>
                    {nextStatuses.length > 0 ? (
                        <select
                            value=""
                            disabled={updating}
                            onChange={(e) => changeStatus(e.target.value as OrderStatus)}
                            style={{ padding: '6px 10px', borderRadius: 6, border: '1px solid #ddd', fontSize: 13 }}
                        >
                            <option value="" disabled>
                                {t('admin.order.transition.select')}
                            </option>
                            {nextStatuses.map((status) => (
                                <option key={status} value={status}>
                                    {t(ORDER_STATUS_TRANSLATION_KEY[status])}
                                </option>
                            ))}
                        </select>
                    ) : (
                        <span style={{ color: '#777', fontSize: 13 }}>
                            {t('admin.order.transition.none')}
                        </span>
                    )}
                </div>
            </div>

            <h2 style={{ margin: '20px 0 10px' }}>주문 아이템</h2>
            <div style={{ overflowX: 'auto' }}>
                <table style={{ ...tableStyle, minWidth: 680 }}>
                    <thead>
                        <tr style={{ background: '#f7f8fa' }}>
                            <th style={th}>상품 ID</th>
                            <th style={th}>상품명</th>
                            <th style={th}>단가</th>
                            <th style={th}>수량</th>
                            <th style={th}>합계</th>
                        </tr>
                    </thead>
                    <tbody>
                        {order.items.map((item) => (
                            <tr key={item.productId} style={{ borderBottom: '1px solid #eee' }}>
                                <td style={td}>{item.productId}</td>
                                <td style={td}>{item.name}</td>
                                <td style={td}>{item.price.toLocaleString()}원</td>
                                <td style={td}>{item.quantity}</td>
                                <td style={{ ...td, fontWeight: 600 }}>{item.lineAmount.toLocaleString()}원</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>
        </div>
    )
}

const summaryBox: React.CSSProperties = {
    border: '1px solid #eee',
    borderRadius: 10,
    background: '#fff',
    padding: 16,
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(140px, 1fr))',
    gap: 12,
}

const label: React.CSSProperties = {
    fontSize: 12,
    color: '#666',
    marginBottom: 4,
}

const badgeStyle: React.CSSProperties = {
    display: 'inline-block',
    padding: '2px 10px',
    borderRadius: 9999,
    color: '#fff',
    fontSize: 12,
    fontWeight: 600,
}

const tableStyle: React.CSSProperties = {
    width: '100%',
    borderCollapse: 'collapse',
    background: '#fff',
    border: '1px solid #eee',
    borderRadius: 8,
    overflow: 'hidden',
}

const th: React.CSSProperties = {
    padding: '10px 14px',
    textAlign: 'left',
    fontSize: 13,
    fontWeight: 600,
    color: '#555',
    borderBottom: '1px solid #eee',
}

const td: React.CSSProperties = {
    padding: '12px 14px',
    fontSize: 14,
}
