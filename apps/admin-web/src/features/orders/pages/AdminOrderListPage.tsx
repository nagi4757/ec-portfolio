import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { OrderAdminApi } from '@/features/orders/api'
import { isApiErrorCode } from '@/lib/api'
import { ORDER_STATUS_TRANSITIONS, ORDER_STATUS_TRANSLATION_KEY } from '@/types/order'
import type { OrderListResponse, OrderStatus } from '@/types/order'

const statusColor: Record<OrderStatus, string> = {
    PENDING: '#b7791f',
    PREPARING: '#2b6cb0',
    SHIPPED: '#6b46c1',
    DELIVERED: '#276749',
    CANCELLED: '#c53030',
}

export default function AdminOrderListPage() {
    const { t } = useTranslation()
    const [data, setData] = useState<OrderListResponse | null>(null)
    const [page, setPage] = useState(1)
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState<string | null>(null)
    const [updatingId, setUpdatingId] = useState<number | null>(null)

    const load = useCallback(() => {
        setLoading(true)
        setError(null)
        OrderAdminApi.list(page, 20)
            .then(setData)
            .catch(() => setError(t('admin.order.loadFailed')))
            .finally(() => setLoading(false))
    }, [page, t])

    useEffect(() => {
        load()
    }, [load])

    async function changeStatus(id: number, status: OrderStatus) {
        setUpdatingId(id)
        try {
            const updated = await OrderAdminApi.updateStatus(id, status)
            setData((prev) => {
                if (!prev) return prev
                return {
                    ...prev,
                    items: prev.items.map((o) =>
                        o.id === id ? { ...o, status: updated.status } : o
                    ),
                }
            })
        } catch (cause) {
            if (isApiErrorCode(cause, 'INVALID_ORDER_TRANSITION')) {
                alert(t('admin.errors.api.invalidOrderTransition'))
                load()
            } else if (isApiErrorCode(cause, 'ORDER_NOT_FOUND')) {
                alert(t('admin.errors.api.orderNotFound'))
                load()
            } else {
                alert(t('admin.order.transition.failed'))
            }
        } finally {
            setUpdatingId(null)
        }
    }

    if (loading) return <div style={{ padding: 24 }}>Loading...</div>
    if (error)   return <div style={{ padding: 24, color: 'crimson' }}>Error: {error}</div>

    const orders = data?.items ?? []

    return (
        <div style={{ padding: 24 }}>
            <h1 style={{ marginTop: 0 }}>주문 관리</h1>
            <div style={{ marginBottom: 12, color: '#555', fontSize: 14 }}>
                총 {data?.total ?? 0}건 / {data?.page ?? 1}페이지
            </div>

            {orders.length === 0 ? (
                <div>주문이 없습니다.</div>
            ) : (
                <div style={{ overflowX: 'auto' }}>
                    <table style={{ ...tableStyle, minWidth: 840 }}>
                        <thead>
                            <tr style={{ background: '#f7f8fa' }}>
                                <th style={th}>주문 번호</th>
                                <th style={th}>회원 ID</th>
                                <th style={th}>상태</th>
                                <th style={th}>합계</th>
                                <th style={th}>주문일시</th>
                                <th style={th}>상태 변경</th>
                            </tr>
                        </thead>
                        <tbody>
                            {orders.map((order) => {
                                const nextStatuses = ORDER_STATUS_TRANSITIONS[order.status]
                                return (
                                    <tr key={order.id} style={{ borderBottom: '1px solid #eee' }}>
                                        <td style={td}>
                                            <Link to={`/orders/${order.id}`} style={orderLink}>
                                                #{order.id}
                                            </Link>
                                        </td>
                                        <td style={td}>{order.userId}</td>
                                        <td style={td}>
                                            <span style={{
                                                ...badgeStyle,
                                                background: statusColor[order.status] ?? '#555',
                                            }}>
                                                {t(ORDER_STATUS_TRANSLATION_KEY[order.status])}
                                            </span>
                                        </td>
                                        <td style={{ ...td, fontWeight: 600 }}>
                                            {order.totalAmount.toLocaleString()}원
                                        </td>
                                        <td style={td}>{order.createdAt ?? '-'}</td>
                                        <td style={td}>
                                            {nextStatuses.length > 0 ? (
                                                <select
                                                    value=""
                                                    disabled={updatingId === order.id}
                                                    onChange={(e) => changeStatus(order.id, e.target.value as OrderStatus)}
                                                    style={{ padding: '4px 8px', borderRadius: 4, border: '1px solid #ddd', fontSize: 13 }}
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
                                        </td>
                                    </tr>
                                )
                            })}
                        </tbody>
                    </table>
                </div>
            )}

            <div style={{ display: 'flex', gap: 8, marginTop: 20 }}>
                <button onClick={() => setPage((p) => Math.max(1, p - 1))} disabled={(data?.page ?? 1) <= 1}>
                    이전
                </button>
                <span style={{ alignSelf: 'center', fontSize: 14 }}>
                    {data?.page ?? 1} / {Math.max(1, data?.totalPages ?? 1)}
                </span>
                <button
                    onClick={() => setPage((p) => p + 1)}
                    disabled={(data?.totalPages ?? 0) === 0 || (data?.page ?? 1) >= (data?.totalPages ?? 1)}
                >
                    다음
                </button>
            </div>
        </div>
    )
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

const orderLink: React.CSSProperties = {
    color: '#2b6cb0',
    textDecoration: 'none',
    fontWeight: 600,
}

const badgeStyle: React.CSSProperties = {
    display: 'inline-block',
    padding: '2px 10px',
    borderRadius: 9999,
    color: '#fff',
    fontSize: 12,
    fontWeight: 600,
}
