import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { ProductAPI } from '@/features/products/api';
import { CartAPI } from '@/features/cart/api';
import { authStore } from '@/lib/authStore';
import type { ProductResponse } from '@/types/product';

export default function ProductDetailPage() {
    const { id } = useParams();
    const [data, setData] = useState<ProductResponse | null>(null);
    const [err, setErr] = useState<string | null>(null);
    const [loading, setLoading] = useState(true);
    const [adding, setAdding] = useState(false);
    const [addMsg, setAddMsg] = useState<string | null>(null);

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
            setAddMsg('장바구니는 로그인 후 이용 가능합니다.');
            return;
        }
        setAdding(true);
        setAddMsg(null);
        try {
            await CartAPI.addItem(data.id, 1);
            setAddMsg('장바구니에 담았습니다.');
        } catch (e) {
            setAddMsg(e instanceof Error ? e.message : '장바구니 담기에 실패했습니다.');
        } finally {
            setAdding(false);
        }
    }

    return (
        <div style={{ padding: 24, maxWidth: 960, margin: '0 auto' }}>
            <Link to="/" style={{ display: 'inline-block', marginBottom: 16 }}>← 목록으로</Link>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 24 }}>
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
                    <p style={{ lineHeight: 1.6, color: '#333' }}>{data.description ?? '상품 설명 없음'}</p>
                    <div style={{ marginTop: 16, display: 'flex', gap: 8 }}>
                        <button onClick={addToCart} disabled={adding}>
                            {adding ? '담는 중...' : '장바구니 담기'}
                        </button>
                        <Link to="/cart">장바구니로 이동</Link>
                    </div>
                    {addMsg && (
                        <div style={{ marginTop: 10, fontSize: 14, color: addMsg.includes('실패') ? 'crimson' : '#2b6cb0' }}>
                            {addMsg}
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
}