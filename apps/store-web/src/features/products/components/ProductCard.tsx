import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Link } from 'react-router-dom';
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

export function ProductCard({ product }: { product: ProductResponse }) {
    const { t } = useTranslation();
    const [adding, setAdding] = useState(false);
    const [feedback, setFeedback] = useState<AddFeedback | null>(null);

    async function handleAddToCart(e: React.MouseEvent<HTMLButtonElement>) {
        e.preventDefault();
        e.stopPropagation();

        if (!authStore.isLoggedIn()) {
            setFeedback({ kind: 'error', messageKey: 'store.cart.loginRequired' });
            return;
        }

        setAdding(true);
        setFeedback(null);
        try {
            const updated = await CartAPI.addItem(product.id, 1);
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
                    <div style={{ marginTop: 6, color: product.stockQuantity === 0 ? 'crimson' : '#2f855a' }}>
                        {product.stockQuantity === 0
                            ? t('store.stock.outOfStock')
                            : t('store.stock.inStock')}
                    </div>
                </div>
            </Link>
            <div style={styles.actions}>
                <button
                    onClick={handleAddToCart}
                    disabled={adding || product.stockQuantity === 0}
                    style={styles.cartButton}
                >
                    {adding ? t('store.cart.adding') : t('store.cart.add')}
                </button>
            </div>
            {feedback && (
                <div style={{ ...styles.msg, color: feedback.kind === 'success' ? '#2b6cb0' : 'crimson' }}>
                    {feedback.messageKey ? t(feedback.messageKey) : feedback.fallback}
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
