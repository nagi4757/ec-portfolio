import { useState } from 'react';
import { Link } from 'react-router-dom';
import { CartAPI } from '@/features/cart/api';
import { authStore } from '@/lib/authStore';
import { cartStore } from '@/lib/cartStore';
import type { ProductResponse } from '@/types/product';

export function ProductCard({ product }: { product: ProductResponse }) {
    const [adding, setAdding] = useState(false);
    const [addMsg, setAddMsg] = useState<string | null>(null);

    async function handleAddToCart(e: React.MouseEvent<HTMLButtonElement>) {
        e.preventDefault();
        e.stopPropagation();

        if (!authStore.isLoggedIn()) {
            setAddMsg('로그인 후 장바구니를 이용할 수 있습니다.');
            return;
        }

        setAdding(true);
        setAddMsg(null);
        try {
            const updated = await CartAPI.addItem(product.id, 1);
            cartStore.setTotalQuantity(updated.totalQuantity);
            setAddMsg('장바구니에 담았습니다.');
        } catch (e) {
            setAddMsg(e instanceof Error ? e.message : '장바구니 담기에 실패했습니다.');
        } finally {
            setAdding(false);
        }
    }

    return (
        <div style={styles.card}>
            <Link to={`/products/${product.id}`} style={{ textDecoration: 'none', color: 'inherit' }}>
                <div style={styles.thumb}>
                    {product.imageUrl ? (
                        <img src={product.imageUrl} alt={product.name}
                             style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
                    ) : (
                        <div style={styles.noImg}>No Image</div>
                    )}
                </div>
                <div style={{ padding: 12 }}>
                    <div style={{ fontWeight: 600, marginBottom: 4 }}>{product.name}</div>
                    <div style={{ color: '#444' }}>{product.price.toLocaleString()} 円</div>
                </div>
            </Link>
            <div style={styles.actions}>
                <button onClick={handleAddToCart} disabled={adding} style={styles.cartButton}>
                    {adding ? '담는 중...' : '장바구니 담기'}
                </button>
            </div>
            {addMsg && (
                <div style={{ ...styles.msg, color: addMsg.includes('담았습니다') ? '#2b6cb0' : 'crimson' }}>
                    {addMsg}
                </div>
            )}
        </div>
    );
}

const styles: Record<string, React.CSSProperties> = {
    card: { border: '1px solid #eee', borderRadius: 12, overflow: 'hidden', background: '#fff' },
    thumb: { width: '100%', height: 160, background: '#f8f8f8' },
    noImg: { display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100%', color: '#888' },
    actions: { padding: '0 12px 8px' },
    cartButton: { width: '100%' },
    msg: { padding: '0 12px 12px', fontSize: 13 },
};
