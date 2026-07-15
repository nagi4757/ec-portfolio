import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { OrderAPI } from '@/features/orders/api'
import { authStore } from '@/lib/authStore'
import { ORDER_STATUS_LABEL } from '@/types/order'
import type { OrderSummary } from '@/types/order'

const statusColor: Record<string, string> = {
    PENDING:   '#b7791f',
    CONFIRMED: '#2b6cb0',
    SHIPPED:   '#6b46c1',
    DELIVERED: '#276749',
    CANCELLED: '#c53030',
}

export default function OrderListPage() {
    const navigate = useNavigate()
    const [orders, setOrders] = useState<OrderSummary[]>([])
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState<string | null>(null)

    useEffect(() => {
        if (!authStore.isLoggedIn()) {
            setLoading(false)
            return
        }
        OrderAPI.list()
            .then(setOrders)
            .catch((e) => setError(e.message))
            .finally(() => setLoading(false))
    }, [])

    if (!authStore.isLoggedIn()) {
        return (
            <div style={{ padding: 24 }}>
                <h1>주문 내역</h1>
                <p>로그인 후 이용할 수 있습니다.</p>
                <button onClick={() => navigate('/login')}>로그인하러 가기</button>
            </div>
        )
    }

    if (loading) return <div style={{ padding: 24 }}>Loading...</div>
    if (error)   return <div style={{ padding: 24, color: 'crimson' }}>Error: {error}</div>

    return (
        <div style={{ padding: 'clamp(12px, 4vw, 24px)', maxWidth: 800, margin: '0 auto' }}>
            <h1 style={{ marginTop: 0 }}>주문 내역</h1>
            <Link to="/" style={{ display: 'inline-block', marginBottom: 16 }}>← 쇼핑 계속하기</Link>

            {orders.length === 0 ? (
                <div>주문 내역이 없습니다.</div>
            ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                    {orders.map((order) => (
                        <Link
                            key={order.id}
                            to={`/orders/${order.id}`}
                            style={{ textDecoration: 'none', color: 'inherit' }}
                        >
                            <div style={cardStyle}>
                                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                                    <span style={{ fontWeight: 600 }}>주문 #{order.id}</span>
                                    <span style={{
                                        ...badgeStyle,
                                        background: statusColor[order.status] ?? '#555',
                                    }}>
                                        {ORDER_STATUS_LABEL[order.status] ?? order.status}
                                    </span>
                                </div>
                                <div style={{ marginTop: 8, display: 'flex', justifyContent: 'space-between', fontSize: 14, color: '#555', gap: 8, flexWrap: 'wrap' }}>
                                    <span>{order.createdAt ?? '-'}</span>
                                    <span style={{ fontWeight: 700, color: '#111' }}>
                                        {order.totalAmount.toLocaleString()}원
                                    </span>
                                </div>
                            </div>
                        </Link>
                    ))}
                </div>
            )}
        </div>
    )
}

const cardStyle: React.CSSProperties = {
    border: '1px solid #eee',
    borderRadius: 10,
    padding: 16,
    background: '#fff',
    cursor: 'pointer',
    transition: 'box-shadow 0.15s',
}

const badgeStyle: React.CSSProperties = {
    display: 'inline-block',
    padding: '3px 10px',
    borderRadius: 9999,
    color: '#fff',
    fontSize: 12,
    fontWeight: 600,
}

