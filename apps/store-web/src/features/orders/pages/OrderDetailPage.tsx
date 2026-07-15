import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { OrderAPI } from '@/features/orders/api'
import { ORDER_STATUS_LABEL } from '@/types/order'
import type { Order } from '@/types/order'

const statusColor: Record<string, string> = {
    PENDING:   '#b7791f',
    CONFIRMED: '#2b6cb0',
    SHIPPED:   '#6b46c1',
    DELIVERED: '#276749',
    CANCELLED: '#c53030',
}

export default function OrderDetailPage() {
    const { id } = useParams()
    const [order, setOrder] = useState<Order | null>(null)
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState<string | null>(null)

    useEffect(() => {
        if (!id) return
        OrderAPI.get(Number(id))
            .then(setOrder)
            .catch((e) => setError(e.message))
            .finally(() => setLoading(false))
    }, [id])

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
                    {ORDER_STATUS_LABEL[order.status] ?? order.status}
                </span>
            </div>

            <div style={{ color: '#666', fontSize: 13, marginBottom: 20 }}>
                주문일시: {order.createdAt ?? '-'}
            </div>

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

