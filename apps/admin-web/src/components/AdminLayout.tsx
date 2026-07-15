import { Link, useNavigate } from 'react-router-dom'
import { authStore } from '@/lib/authStore'
import type { ReactNode } from 'react'

type Props = {
    children: ReactNode
}

export default function AdminLayout({ children }: Props) {
    const navigate = useNavigate()
    const user = authStore.getUser()

    function handleLogout() {
        authStore.clear()
        navigate('/login', { replace: true })
    }

    return (
        <div style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column' }}>
            {/* 상단 헤더 */}
            <header style={headerStyle}>
                <div style={{ display: 'flex', alignItems: 'center', gap: '24px', flexWrap: 'wrap' }}>
                    <span style={{ fontWeight: 700, fontSize: '16px' }}>EC Admin</span>
                    <nav style={{ display: 'flex', gap: '16px', flexWrap: 'wrap' }}>
                        <Link to="/products" style={{ color: '#fff', textDecoration: 'none', fontWeight: 500 }}>상품</Link>
                        <Link to="/categories" style={{ color: '#fff', textDecoration: 'none', fontWeight: 500 }}>카테고리</Link>
                        <Link to="/orders" style={{ color: '#fff', textDecoration: 'none', fontWeight: 500 }}>주문</Link>
                    </nav>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: '12px', fontSize: '14px', flexWrap: 'wrap' }}>
                    <span style={{ maxWidth: 260, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                        {user?.name} ({user?.email})
                    </span>
                    <button
                        onClick={handleLogout}
                        style={{
                            background: 'rgba(255,255,255,0.2)',
                            border: 'none',
                            color: '#fff',
                            padding: '4px 12px',
                            borderRadius: '4px',
                            cursor: 'pointer',
                            fontSize: '13px',
                        }}
                    >
                        로그아웃
                    </button>
                </div>
            </header>

            {/* 본문 */}
            <main style={{ flex: 1 }}>
                {children}
            </main>
        </div>
    )
}

const headerStyle: React.CSSProperties = {
    background: '#2b6cb0',
    color: '#fff',
    padding: '10px clamp(12px, 4vw, 24px)',
    minHeight: 52,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: '12px',
    flexWrap: 'wrap',
}

