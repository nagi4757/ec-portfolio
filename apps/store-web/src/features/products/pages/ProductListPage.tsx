import { useEffect, useMemo, useState } from 'react';
import { ProductAPI } from '@/features/products/api';
import type { ProductListResponse, ProductSearchParams } from '@/types/product';
import { ProductCard } from '../components/ProductCard';

const PAGE_SIZE = 8;

export default function ProductListPage() {
    const [data, setData] = useState<ProductListResponse | null>(null);
    const [err, setErr] = useState<string | null>(null);
    const [loading, setLoading] = useState(true);

    const [keywordInput, setKeywordInput] = useState('');
    const [keyword, setKeyword] = useState('');
    const [minPrice, setMinPrice] = useState('');
    const [maxPrice, setMaxPrice] = useState('');
    const [sort, setSort] = useState<ProductSearchParams['sort']>('newest');
    const [page, setPage] = useState(1);

    const searchParams = useMemo<ProductSearchParams>(() => ({
        keyword: keyword || undefined,
        minPrice: minPrice ? Number(minPrice) : undefined,
        maxPrice: maxPrice ? Number(maxPrice) : undefined,
        sort,
        page,
        size: PAGE_SIZE,
    }), [keyword, minPrice, maxPrice, sort, page]);

    useEffect(() => {
        setLoading(true);
        setErr(null);
        ProductAPI.list(searchParams)
            .then(setData)
            .catch((e) => setErr(e.message))
            .finally(() => setLoading(false));
    }, [searchParams]);

    function applyFilters() {
        setPage(1);
        setKeyword(keywordInput.trim());
    }

    function resetFilters() {
        setKeywordInput('');
        setKeyword('');
        setMinPrice('');
        setMaxPrice('');
        setSort('newest');
        setPage(1);
    }

    if (loading) return <div style={{ padding: 24 }}>Loading...</div>;
    if (err) return <div style={{ padding: 24, color: 'crimson' }}>Error: {err}</div>;

    const products = data?.items ?? [];

    return (
        <div style={{ padding: 24 }}>
            <h1 style={{ margin: '8px 0 16px' }}>상품 목록</h1>

            <section style={filterBox}>
                <div style={filterGrid}>
                    <input
                        value={keywordInput}
                        onChange={(e) => setKeywordInput(e.target.value)}
                        placeholder="상품명/설명 검색"
                        style={input}
                    />
                    <input
                        type="number"
                        min={0}
                        value={minPrice}
                        onChange={(e) => setMinPrice(e.target.value)}
                        placeholder="최소 가격"
                        style={input}
                    />
                    <input
                        type="number"
                        min={0}
                        value={maxPrice}
                        onChange={(e) => setMaxPrice(e.target.value)}
                        placeholder="최대 가격"
                        style={input}
                    />
                    <select value={sort} onChange={(e) => setSort(e.target.value as ProductSearchParams['sort'])} style={input}>
                        <option value="newest">최신순</option>
                        <option value="priceAsc">가격 낮은순</option>
                        <option value="priceDesc">가격 높은순</option>
                        <option value="nameAsc">이름순</option>
                    </select>
                </div>
                <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
                    <button onClick={applyFilters}>검색</button>
                    <button onClick={resetFilters}>초기화</button>
                </div>
            </section>

            {!products.length ? (
                <div style={{ padding: '16px 4px' }}>검색 결과가 없습니다.</div>
            ) : (
                <>
                    <div style={{ margin: '8px 0 12px', color: '#555', fontSize: 14 }}>
                        총 {data?.total ?? 0}건 / {data?.page ?? 1}페이지
                    </div>
                    <div style={grid}>
                        {products.map((p) => <ProductCard key={p.id} product={p} />)}
                    </div>
                </>
            )}

            <div style={{ display: 'flex', gap: 8, marginTop: 20 }}>
                <button
                    onClick={() => setPage((prev) => Math.max(1, prev - 1))}
                    disabled={(data?.page ?? 1) <= 1}
                >
                    이전
                </button>
                <span style={{ alignSelf: 'center', fontSize: 14 }}>
                    {data?.page ?? 1} / {Math.max(1, data?.totalPages ?? 1)}
                </span>
                <button
                    onClick={() => setPage((prev) => prev + 1)}
                    disabled={(data?.totalPages ?? 0) === 0 || (data?.page ?? 1) >= (data?.totalPages ?? 1)}
                >
                    다음
                </button>
            </div>
        </div>
    );
}

const filterBox: React.CSSProperties = {
    border: '1px solid #eee',
    borderRadius: 10,
    padding: 12,
    marginBottom: 16,
    background: '#fff',
};

const filterGrid: React.CSSProperties = {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))',
    gap: 8,
};

const input: React.CSSProperties = {
    padding: '8px 10px',
    borderRadius: 6,
    border: '1px solid #ddd',
    fontSize: 14,
};

const grid: React.CSSProperties = {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))',
    gap: 16,
};