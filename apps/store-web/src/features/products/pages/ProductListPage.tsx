import { useEffect, useState } from 'react';
import { ProductAPI } from '@/features/products/api';
import type { ProductResponse } from '@/types/product';
import { ProductCard } from '../components/ProductCard';

export default function ProductListPage() {
    const [data, setData] = useState<ProductResponse[] | null>(null);
    const [err, setErr] = useState<string | null>(null);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        ProductAPI.list()
            .then(setData)
            .catch((e) => setErr(e.message))
            .finally(() => setLoading(false));
    }, []);

    if (loading) return <div style={{ padding: 24 }}>Loading...</div>;
    if (err) return <div style={{ padding: 24, color: 'crimson' }}>Error: {err}</div>;
    if (!data?.length) return <div style={{ padding: 24 }}>상품이 없습니다.</div>;

    return (
        <div style={{ padding: 24 }}>
            <h1 style={{ margin: '8px 0 16px' }}>상품 목록</h1>
            <div style={grid}>
                {data.map((p) => <ProductCard key={p.id} product={p} />)}
            </div>
        </div>
    );
}

const grid: React.CSSProperties = {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))',
    gap: 16,
};