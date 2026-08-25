import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useParams, Link } from 'react-router-dom';
import { ProductAPI } from '@/features/products/api';
import { CartAPI } from '@/features/cart/api';
import { authStore } from '@/lib/authStore';
import { cartStore } from '@/lib/cartStore';
import { isApiErrorCode } from '@/lib/api';
import type { ProductResponse } from '@/types/product';

type AddFeedback = {
    kind: 'success' | 'error';
    messageKey?: string;
    fallback?: string;
};

export default function ProductDetailPage() {
    const { t } = useTranslation();
    const { id } = useParams();
    const [data, setData] = useState<ProductResponse | null>(null);
    const [err, setErr] = useState<string | null>(null);
    const [loading, setLoading] = useState(true);
    const [adding, setAdding] = useState(false);
    const [feedback, setFeedback] = useState<AddFeedback | null>(null);

    useEffect(() => {
        if (!id) return;
        ProductAPI.get(Number(id))
            .then(setData)
            .catch((e) => setErr(e.message))
            .finally(() => setLoading(false));
    }, [id]);

    if (loading) return <div style={{ padding: 24 }}>Loading...</div>;
    if (err) return <div style={{ padding: 24, color: 'crimson' }}>Error: {err}</div>;
    if (!data) return <div style={{ padding: 24 }}>상품을 찾을 수 없습니다.</div>;

    async function addToCart() {
        if (!data) return;
        if (!authStore.isLoggedIn()) {
            setFeedback({ kind: 'error', messageKey: 'store.cart.loginRequired' });
            return;
        }
        setAdding(true);
        setFeedback(null);
        try {
            const updated = await CartAPI.addItem(data.id, 1);
            cartStore.setTotalQuantity(updated.totalQuantity);
            setFeedback({ kind: 'success', messageKey: 'store.cart.added' });
        } catch (e) {
            setFeedback(isApiErrorCode(e, 'PRODUCT_NOT_AVAILABLE')
                ? { kind: 'error', messageKey: 'store.product.notAvailable' }
                : isApiErrorCode(e, 'INSUFFICIENT_STOCK')
                ? { kind: 'error', messageKey: 'store.stock.insufficient' }
                : {
                    kind: 'error',
                    fallback: e instanceof Error ? e.message : t('store.cart.addFailed'),
                });
        } finally {
            setAdding(false);
        }
    }

    return (
        <div style={{ padding: 'clamp(12px, 4vw, 24px)', maxWidth: 960, margin: '0 auto' }}>
            <Link to="/" style={{ display: 'inline-block', marginBottom: 16 }}>← 목록으로</Link>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))', gap: 20 }}>
                <div style={{ border: '1px solid #eee', borderRadius: 12, overflow: 'hidden', background: '#fff' }}>
                    {data.imageUrl ? (
                        <img src={data.imageUrl} alt={data.name} style={{ width: '100%', objectFit: 'cover' }} />
                    ) : (
                        <div style={{ height: 320, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#888' }}>No Image</div>
                    )}
                </div>
                <div>
                    <h1 style={{ marginTop: 0 }}>{data.name}</h1>
                    <div style={{ fontSize: 20, fontWeight: 700, margin: '8px 0 16px' }}>
                        {data.price.toLocaleString()} 円
                    </div>
                    <div style={{ marginBottom: 12, color: data.stockQuantity === 0 ? 'crimson' : '#2f855a' }}>
                        {data.stockQuantity === 0
                            ? t('store.stock.outOfStock')
                            : t('store.stock.remaining', { count: data.stockQuantity })}
                    </div>
                    <p style={{ lineHeight: 1.6, color: '#333' }}>{data.description ?? '상품 설명 없음'}</p>
                    <div style={{ marginTop: 16, display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                        <button onClick={addToCart} disabled={adding || data.stockQuantity === 0}>
                            {adding ? t('store.cart.adding') : t('store.cart.add')}
                        </button>
                        <Link to="/cart">장바구니로 이동</Link>
                    </div>
                    {feedback && (
                        <div style={{ marginTop: 10, fontSize: 14, color: feedback.kind === 'success' ? '#2b6cb0' : 'crimson' }}>
                            {feedback.messageKey ? t(feedback.messageKey) : feedback.fallback}
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
}
