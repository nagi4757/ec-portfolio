import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { OrderAdminApi } from '@/features/orders/api'
import { ORDER_STATUS_LABEL, ORDER_STATUS_OPTIONS } from '@/types/order'
import type { OrderListResponse, OrderStatus } from '@/types/order'

const statusColor: Record<string, string> = {
    PENDING:   '#b7791f',
    CONFIRMED: '#2b6cb0',
    SHIPPED:   '#6b46c1',
    DELIVERED: '#276749',
    CANCELLED: '#c53030',
}

export default function AdminOrderListPage() {
    const [data, setData] = useState<OrderListResponse | null>(null)
    const [page, setPage] = useState(1)
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState<string | null>(null)
    const [updatingId, setUpdatingId] = useState<number | null>(null)

    useEffect(() => {
        load()
    }, [page])

    function load() {
        setLoading(true)
        setError(null)
        OrderAdminApi.list(page, 20)
            .then(setData)
            .catch((e) => setError(e.message))
            .finally(() => setLoading(false))
    }

    async function changeStatus(id: number, status: string) {
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
        } catch (e) {
            alert(e instanceof Error ? e.message : '상태 변경 실패')
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
                            {orders.map((order) => (
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
                                            {ORDER_STATUS_LABEL[order.status] ?? order.status}
                                        </span>
                                    </td>
                                    <td style={{ ...td, fontWeight: 600 }}>
                                        {order.totalAmount.toLocaleString()}원
                                    </td>
                                    <td style={td}>{order.createdAt ?? '-'}</td>
                                    <td style={td}>
                                        <select
                                            value={order.status}
                                            disabled={updatingId === order.id}
                                            onChange={(e) => changeStatus(order.id, e.target.value)}
                                            style={{ padding: '4px 8px', borderRadius: 4, border: '1px solid #ddd', fontSize: 13 }}
                                        >
                                            {ORDER_STATUS_OPTIONS.map((s) => (
                                                <option key={s} value={s}>
                                                    {ORDER_STATUS_LABEL[s as OrderStatus]}
                                                </option>
                                            ))}
                                        </select>
                                    </td>
                                </tr>
                            ))}
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

