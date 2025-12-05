import { BrowserRouter, Routes, Route, Link } from 'react-router-dom';
import ProductListPage from '@/features/products/pages/ProductListPage';
import ProductDetailPage from '@/features/products/pages/ProductDetailPage';

function Header() {
    return (
        <header style={hdr}>
            <Link to="/" style={brand}>EC Store</Link>
        </header>
    );
}

export default function App() {
    return (
        <BrowserRouter>
            <Header />
            <Routes>
                <Route path="/" element={<ProductListPage />} />
                <Route path="/products/:id" element={<ProductDetailPage />} />
            </Routes>
        </BrowserRouter>
    );
}

const hdr: React.CSSProperties = {
    height: 56, display: 'flex', alignItems: 'center', padding: '0 16px',
    borderBottom: '1px solid #eee', background: '#fff', position: 'sticky', top: 0, zIndex: 10,
};
const brand: React.CSSProperties = { textDecoration: 'none', color: '#111', fontWeight: 700 };