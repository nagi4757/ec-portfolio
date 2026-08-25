import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate } from 'react-router-dom'
import { CartAPI } from '@/features/cart/api'
import { OrderAPI } from '@/features/orders/api'
import { ProductAPI } from '@/features/products/api'
import { authStore } from '@/lib/authStore'
import { cartStore } from '@/lib/cartStore'
import { isApiErrorCode } from '@/lib/api'
import type { CartResponse } from '@/types/cart'

type ActionError = {
    messageKey?: string
    fallback?: string
}

function toActionError(error: unknown, fallback: string): ActionError {
    if (isApiErrorCode(error, 'INSUFFICIENT_STOCK')) {
        return { messageKey: 'store.stock.insufficient' }
    }
    return { fallback: error instanceof Error ? error.message : fallback }
}

async function fetchStockQuantities(items: CartResponse['items']): Promise<Record<number, number>> {
    const products = await Promise.all(items.map(async (item) => {
        try {
            return await ProductAPI.get(item.productId)
        } catch {
            return null
        }
    }))

    return products.reduce<Record<number, number>>((stocks, product) => {
        if (product) stocks[product.id] = product.stockQuantity
        return stocks
    }, {})
}

export default function CartPage() {
    const { t } = useTranslation()
    const navigate = useNavigate()
    const [cart, setCart] = useState<CartResponse | null>(null)
    const [stockQuantities, setStockQuantities] = useState<Record<number, number>>({})
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState<string | null>(null)
    const [actionError, setActionError] = useState<ActionError | null>(null)
    const [ordering, setOrdering] = useState(false)

    const applyCart = useCallback(async (data: CartResponse) => {
        const stocks = await fetchStockQuantities(data.items)
        setCart(data)
        setStockQuantities(stocks)
        cartStore.setTotalQuantity(data.totalQuantity)
    }, [])

    const loadCart = useCallback(async () => {
        setLoading(true)
        setError(null)
        setActionError(null)
        try {
            const data = await CartAPI.get()
            await applyCart(data)
        } catch (e) {
            setError(e instanceof Error ? e.message : '장바구니를 불러오지 못했습니다.')
        } finally {
            setLoading(false)
        }
    }, [applyCart])

    useEffect(() => {
        if (!authStore.isLoggedIn()) {
            cartStore.setTotalQuantity(0)
            setLoading(false)
            return
        }
        void loadCart()
    }, [loadCart])

    async function changeQty(productId: number, quantity: number) {
        const stockQuantity = stockQuantities[productId]
        if (stockQuantity !== undefined && quantity > stockQuantity) {
            setActionError({ messageKey: 'store.stock.insufficient' })
            return
        }

        setActionError(null)
        try {
            const data = await CartAPI.updateItem(productId, quantity)
            await applyCart(data)
        } catch (e) {
            setActionError(toActionError(e, '수량 변경에 실패했습니다.'))
        }
    }

    async function removeItem(productId: number) {
        setActionError(null)
        try {
            const data = await CartAPI.removeItem(productId)
            await applyCart(data)
        } catch (e) {
            setActionError(toActionError(e, '상품 삭제에 실패했습니다.'))
        }
    }

    async function placeOrder() {
        setOrdering(true)
        setActionError(null)
        try {
            await OrderAPI.place()
            cartStore.setTotalQuantity(0)
            navigate('/orders')
        } catch (e) {
            setActionError(toActionError(e, '주문에 실패했습니다.'))
            if (cart) {
                setStockQuantities(await fetchStockQuantities(cart.items))
            }
        } finally {
            setOrdering(false)
        }
    }

    async function clearCart() {
        setActionError(null)
        try {
            const data = await CartAPI.clear()
            await applyCart(data)
        } catch (e) {
            setActionError(toActionError(e, '장바구니 비우기에 실패했습니다.'))
        }
    }

    if (!authStore.isLoggedIn()) {
        return (
            <div style={{ padding: 24 }}>
                <h1>장바구니</h1>
                <p>장바구니는 로그인 후 이용할 수 있습니다.</p>
                <button onClick={() => navigate('/login')}>로그인하러 가기</button>
            </div>
        )
    }

    if (loading) return <div style={{ padding: 24 }}>Loading...</div>
    if (error) return <div style={{ padding: 24, color: 'crimson' }}>Error: {error}</div>

    const items = cart?.items ?? []

    return (
        <div style={{ padding: 'clamp(12px, 4vw, 24px)', maxWidth: 980, margin: '0 auto' }}>
            <h1 style={{ marginTop: 0 }}>장바구니</h1>
            <Link to="/" style={{ display: 'inline-block', marginBottom: 12 }}>← 쇼핑 계속하기</Link>

            {actionError && (
                <div role="alert" style={{ marginBottom: 12, color: 'crimson' }}>
                    {actionError.messageKey ? t(actionError.messageKey) : actionError.fallback}
                </div>
            )}

            {items.length === 0 ? (
                <div>장바구니가 비어 있습니다.</div>
            ) : (
                <>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                        {items.map((item) => (
                            <div key={item.productId} style={row}>
                                <div style={{ flex: 1 }}>
                                    <div style={{ fontWeight: 600 }}>{item.name}</div>
                                    <div style={{ color: '#555', fontSize: 14 }}>{item.price.toLocaleString()}원</div>
                                    <div style={{ color: stockQuantities[item.productId] === 0 ? 'crimson' : '#2f855a', fontSize: 13 }}>
                                        {stockQuantities[item.productId] === 0
                                            ? t('store.stock.outOfStock')
                                            : stockQuantities[item.productId] !== undefined
                                                ? t('store.stock.remaining', { count: stockQuantities[item.productId] })
                                                : null}
                                    </div>
                                </div>

                                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                                    <button onClick={() => changeQty(item.productId, item.quantity - 1)}>-</button>
                                    <span>{item.quantity}</span>
                                    <button
                                        onClick={() => changeQty(item.productId, item.quantity + 1)}
                                        disabled={stockQuantities[item.productId] === undefined
                                            || item.quantity >= stockQuantities[item.productId]}
                                    >+</button>
                                </div>

                                <div style={lineAmount}>
                                    {item.lineAmount.toLocaleString()}원
                                </div>

                                <button onClick={() => removeItem(item.productId)}>삭제</button>
                            </div>
                        ))}
                    </div>

                    <div style={{ marginTop: 20, borderTop: '1px solid #eee', paddingTop: 14 }}>
                        <div>총 수량: {cart?.totalQuantity ?? 0}</div>
                        <div style={{ fontSize: 20, fontWeight: 700 }}>
                            총 금액: {(cart?.totalAmount ?? 0).toLocaleString()}원
                        </div>
                        <div style={{ marginTop: 10, display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                            <button onClick={clearCart}>장바구니 비우기</button>
                            <button
                                onClick={placeOrder}
                                disabled={ordering}
                                style={{ background: '#2b6cb0', color: '#fff', border: 'none', borderRadius: 6, padding: '6px 16px', cursor: ordering ? 'not-allowed' : 'pointer', fontWeight: 600 }}
                            >
                                {ordering ? '주문 중...' : '주문하기'}
                            </button>
                        </div>
                    </div>
                </>
            )}
        </div>
    )
}

const row: React.CSSProperties = {
    border: '1px solid #eee',
    borderRadius: 8,
    padding: 12,
    display: 'flex',
    alignItems: 'center',
    flexWrap: 'wrap',
    gap: 12,
    background: '#fff',
}

const lineAmount: React.CSSProperties = {
    marginLeft: 'auto',
    minWidth: 120,
    textAlign: 'right',
    fontWeight: 600,
}
