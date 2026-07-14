import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { authApi } from '@/features/auth/api'
import { authStore } from '@/lib/authStore'

export default function LoginPage() {
    const navigate = useNavigate()
    const [email, setEmail] = useState('')
    const [password, setPassword] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [loading, setLoading] = useState(false)

    async function handleSubmit(e: React.FormEvent) {
        e.preventDefault()
        setError(null)
        setLoading(true)
        try {
            const res = await authApi.login({ email, password })
            authStore.save(res.accessToken, res.user)
            navigate('/', { replace: true })
        } catch (err: unknown) {
            setError(err instanceof Error ? err.message : '로그인에 실패했습니다.')
        } finally {
            setLoading(false)
        }
    }

    return (
        <div style={{
            display: 'flex',
            justifyContent: 'center',
            alignItems: 'center',
            height: '100vh',
            background: '#f5f5f5',
        }}>
            <div style={{
                background: '#fff',
                padding: '40px',
                borderRadius: '8px',
                boxShadow: '0 2px 8px rgba(0,0,0,0.12)',
                width: '360px',
            }}>
                <h1 style={{ margin: '0 0 24px', fontSize: '20px' }}>관리자 로그인</h1>

                <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
                    <label>
                        <div style={{ marginBottom: '4px', fontWeight: 500 }}>이메일</div>
                        <input
                            type="email"
                            value={email}
                            onChange={(e) => setEmail(e.target.value)}
                            required
                            autoFocus
                            placeholder="admin@example.com"
                            style={{ width: '100%', padding: '8px', boxSizing: 'border-box', borderRadius: '4px', border: '1px solid #ccc' }}
                        />
                    </label>

                    <label>
                        <div style={{ marginBottom: '4px', fontWeight: 500 }}>비밀번호</div>
                        <input
                            type="password"
                            value={password}
                            onChange={(e) => setPassword(e.target.value)}
                            required
                            placeholder="8자 이상"
                            style={{ width: '100%', padding: '8px', boxSizing: 'border-box', borderRadius: '4px', border: '1px solid #ccc' }}
                        />
                    </label>

                    {error && (
                        <div style={{ color: '#e53e3e', fontSize: '14px', background: '#fff5f5', padding: '8px 12px', borderRadius: '4px' }}>
                            {error}
                        </div>
                    )}

                    <button
                        type="submit"
                        disabled={loading}
                        style={{
                            padding: '10px',
                            background: loading ? '#999' : '#2b6cb0',
                            color: '#fff',
                            border: 'none',
                            borderRadius: '4px',
                            cursor: loading ? 'not-allowed' : 'pointer',
                            fontWeight: 600,
                            fontSize: '15px',
                        }}
                    >
                        {loading ? '로그인 중...' : '로그인'}
                    </button>
                </form>
            </div>
        </div>
    )
}

