import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { ProductAPI } from '@/features/products/api';
import type { ProductResponse } from '@/types/product';

export default function ProductDetailPage() {
    const { id } = useParams();
    const [data, setData] = useState<ProductResponse | null>(null);
    const [err, setErr] = useState<string | null>(null);
    const [loading, setLoading] = useState(true);

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
                </div>
            </div>
        </div>
    );
}