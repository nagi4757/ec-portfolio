import { Link } from 'react-router-dom';
import type { ProductResponse } from '@/types/product';

export function ProductCard({ product }: { product: ProductResponse }) {
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
        </div>
    );
}

const styles: Record<string, React.CSSProperties> = {
    card: { border: '1px solid #eee', borderRadius: 12, overflow: 'hidden', background: '#fff' },
    thumb: { width: '100%', height: 160, background: '#f8f8f8' },
    noImg: { display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100%', color: '#888' },
};
