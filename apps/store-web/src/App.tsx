import { BrowserRouter, Routes, Route, Link, useLocation, useNavigate } from 'react-router-dom';
import ProductListPage from '@/features/products/pages/ProductListPage';
import ProductDetailPage from '@/features/products/pages/ProductDetailPage';
import LoginPage from '@/features/auth/pages/LoginPage';
import SignUpPage from '@/features/auth/pages/SignUpPage';
import CartPage from '@/features/cart/pages/CartPage';
import OrderListPage from '@/features/orders/pages/OrderListPage';
import OrderDetailPage from '@/features/orders/pages/OrderDetailPage';
import { CartAPI } from '@/features/cart/api';
import { authStore } from '@/lib/authStore';
import { cartStore } from '@/lib/cartStore';
import { useEffect, useState } from 'react';

function Header() {
    const navigate = useNavigate();
    const location = useLocation();
    const [totalQuantity, setTotalQuantity] = useState(cartStore.getTotalQuantity());

    const user = authStore.getUser();

    useEffect(() => {
        return cartStore.subscribe(setTotalQuantity);
    }, []);

    useEffect(() => {
        if (!authStore.isLoggedIn()) {
            cartStore.setTotalQuantity(0);
            return;
        }

        CartAPI.get()
            .then((data) => cartStore.setTotalQuantity(data.totalQuantity))
            .catch(() => {
                // 장바구니 조회 실패 시 기존 배지 값을 유지한다.
            });
    }, [location.pathname]);

    function handleLogout() {
        authStore.clear();
        cartStore.setTotalQuantity(0);
        navigate('/', { replace: true });
    }

    return (
        <header style={hdr}>
            <Link to="/" style={brand}>EC Store</Link>
            <nav style={nav}>
                <Link to="/cart" style={{ ...navLink, position: 'relative', paddingRight: totalQuantity > 0 ? 20 : undefined }}>
                    장바구니
                    {totalQuantity > 0 && (
                        <span style={badge}>{totalQuantity > 99 ? '99+' : totalQuantity}</span>
                    )}
                </Link>
                {user && (
                    <Link to="/orders" style={navLink}>내 주문</Link>
                )}
                {user ? (
                    <>
                        <span style={userName}>{user.name}님</span>
                        <button onClick={handleLogout} style={navBtn}>로그아웃</button>
                    </>
                ) : (
                    <>
                        <Link to="/login" style={navLink}>로그인</Link>
                        <Link to="/signup" style={{ ...navLink, ...signUpLink }}>회원가입</Link>
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
                <Route path="/cart" element={<CartPage />} />
                <Route path="/orders" element={<OrderListPage />} />
                <Route path="/orders/:id" element={<OrderDetailPage />} />
                <Route path="/login" element={<LoginPage />} />
                <Route path="/signup" element={<SignUpPage />} />
            </Routes>
        </BrowserRouter>
    );
}

const hdr: React.CSSProperties = {
    minHeight: 56,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    flexWrap: 'wrap',
    gap: 10,
    padding: '10px clamp(12px, 4vw, 24px)',
    borderBottom: '1px solid #e5e7eb',
    background: '#fff',
    position: 'sticky', top: 0, zIndex: 10,
};
const brand: React.CSSProperties = { textDecoration: 'none', color: '#111', fontWeight: 700, fontSize: 17 };
const nav: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 12, fontSize: 14, flexWrap: 'wrap' };
const navLink: React.CSSProperties = { textDecoration: 'none', color: '#334155', fontWeight: 500 };
const userName: React.CSSProperties = { color: '#475569', fontSize: 13, maxWidth: 140, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' };
const signUpLink: React.CSSProperties = { background: '#2b6cb0', color: '#fff', padding: '6px 12px', borderRadius: 6 };
const badge: React.CSSProperties = {
    position: 'absolute',
    top: -8,
    right: -12,
    minWidth: 18,
    height: 18,
    padding: '0 5px',
    borderRadius: 9999,
    background: '#e53e3e',
    color: '#fff',
    fontSize: 11,
    fontWeight: 700,
    display: 'inline-flex',
    alignItems: 'center',
    justifyContent: 'center',
    lineHeight: 1,
    boxSizing: 'border-box',
};
const navBtn: React.CSSProperties = {
    background: '#fff', border: '1px solid #d1d5db', borderRadius: 6,
    padding: '5px 10px', cursor: 'pointer', fontSize: 13, color: '#475569',
};
