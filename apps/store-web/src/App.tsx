import { BrowserRouter, Routes, Route, Link, useNavigate } from 'react-router-dom';
import ProductListPage from '@/features/products/pages/ProductListPage';
import ProductDetailPage from '@/features/products/pages/ProductDetailPage';
import LoginPage from '@/features/auth/pages/LoginPage';
import SignUpPage from '@/features/auth/pages/SignUpPage';
import { authStore } from '@/lib/authStore';
import { useState } from 'react';

function Header() {
    const navigate = useNavigate();
    const [, forceUpdate] = useState(0);

    const user = authStore.getUser();

    function handleLogout() {
        authStore.clear();
        forceUpdate(n => n + 1);
        navigate('/', { replace: true });
    }

    return (
        <header style={hdr}>
            <Link to="/" style={brand}>EC Store</Link>
            <nav style={{ display: 'flex', alignItems: 'center', gap: 12, fontSize: 14 }}>
                {user ? (
                    <>
                        <span style={{ color: '#555' }}>{user.name}님</span>
                        <button onClick={handleLogout} style={navBtn}>로그아웃</button>
                    </>
                ) : (
                    <>
                        <Link to="/login" style={navLink}>로그인</Link>
                        <Link to="/signup" style={{ ...navLink, background: '#2b6cb0', color: '#fff', padding: '5px 12px', borderRadius: 6 }}>회원가입</Link>
                    </>
                )}
            </nav>
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
                <Route path="/login" element={<LoginPage />} />
                <Route path="/signup" element={<SignUpPage />} />
            </Routes>
        </BrowserRouter>
    );
}

const hdr: React.CSSProperties = {
    height: 56, display: 'flex', alignItems: 'center', justifyContent: 'space-between',
    padding: '0 24px', borderBottom: '1px solid #eee', background: '#fff',
    position: 'sticky', top: 0, zIndex: 10,
};
const brand: React.CSSProperties = { textDecoration: 'none', color: '#111', fontWeight: 700, fontSize: 16 };
const navLink: React.CSSProperties = { textDecoration: 'none', color: '#333', fontWeight: 500 };
const navBtn: React.CSSProperties = {
    background: 'none', border: '1px solid #ddd', borderRadius: 6,
    padding: '5px 12px', cursor: 'pointer', fontSize: 13, color: '#555',
};
