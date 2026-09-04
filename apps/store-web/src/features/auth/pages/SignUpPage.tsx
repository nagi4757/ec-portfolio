import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { authApi } from '@/features/auth/api'
import { authStore } from '@/lib/authStore'
import { ApiError } from '@/lib/api'
import { useTranslation } from 'react-i18next'

export default function SignUpPage() {
    const navigate = useNavigate()
    const { t } = useTranslation()
    const [name, setName] = useState('')
    const [email, setEmail] = useState('')
    const [password, setPassword] = useState('')
    const [passwordConfirm, setPasswordConfirm] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [loading, setLoading] = useState(false)

    async function handleSubmit(e: React.FormEvent) {
        e.preventDefault()
        setError(null)
        if (password !== passwordConfirm) {
            setError('store.auth.passwordMismatch')
            return
        }
        if (password.length < 8) {
            setError('store.auth.passwordTooShort')
            return
        }
        setLoading(true)
        try {
            const res = await authApi.signUp({ email, password, name })
            authStore.save(res.accessToken, res.user)
            navigate('/', { replace: true })
        } catch (err: unknown) {
            if (err instanceof ApiError && err.status === 409) {
                setError('store.auth.emailAlreadyUsed')
            } else if (err instanceof ApiError && err.status === 400) {
                setError('store.auth.invalidInput')
            } else {
                setError('store.auth.requestFailed')
            }
        } finally {
            setLoading(false)
        }
    }

    return (
        <div style={wrap}>
            <div style={card}>
                <h1 style={title}>회원가입</h1>
                <form onSubmit={handleSubmit} style={formStyle}>
                    <label style={labelStyle}>
                        <span style={labelText}>이름</span>
                        <input
                            type="text"
                            value={name}
                            onChange={(e) => setName(e.target.value)}
                            required
                            autoFocus
                            placeholder="홍길동"
                            style={input}
                        />
                    </label>
                    <label style={labelStyle}>
                        <span style={labelText}>이메일</span>
                        <input
                            type="email"
                            value={email}
                            onChange={(e) => setEmail(e.target.value)}
                            required
                            placeholder="example@email.com"
                            style={input}
                        />
                    </label>
                    <label style={labelStyle}>
                        <span style={labelText}>비밀번호</span>
                        <input
                            type="password"
                            value={password}
                            onChange={(e) => setPassword(e.target.value)}
                            required
                            placeholder="8자 이상"
                            style={input}
                        />
                    </label>
                    <label style={labelStyle}>
                        <span style={labelText}>비밀번호 확인</span>
                        <input
                            type="password"
                            value={passwordConfirm}
                            onChange={(e) => setPasswordConfirm(e.target.value)}
                            required
                            placeholder="비밀번호 재입력"
                            style={input}
                        />
                    </label>
                    {error && <div role="alert" style={errBox}>{t(error)}</div>}
                    <button type="submit" disabled={loading} style={btn(loading)}>
                        {loading ? '처리 중...' : '회원가입'}
                    </button>
                </form>
                <div style={{ marginTop: 16, textAlign: 'center', fontSize: 14, color: '#555' }}>
                    이미 계정이 있으신가요?{' '}
                    <Link to="/login" style={{ color: '#2b6cb0', fontWeight: 600 }}>로그인</Link>
                </div>
            </div>
        </div>
    )
}

const wrap: React.CSSProperties = {
    display: 'flex', justifyContent: 'center', alignItems: 'center',
    minHeight: 'calc(100vh - 56px)', background: '#f7f8fa', padding: 24,
}
const card: React.CSSProperties = {
    background: '#fff', padding: '40px 36px', borderRadius: 12,
    boxShadow: '0 2px 12px rgba(0,0,0,0.08)', width: '100%', maxWidth: 400,
}
const title: React.CSSProperties = { margin: '0 0 28px', fontSize: 22, fontWeight: 700 }
const formStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 16 }
const labelStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 6 }
const labelText: React.CSSProperties = { fontWeight: 500, fontSize: 14 }
const input: React.CSSProperties = {
    padding: '10px 12px', border: '1px solid #ddd', borderRadius: 6,
    fontSize: 14, outline: 'none',
}
const errBox: React.CSSProperties = {
    background: '#fff5f5', color: '#e53e3e', padding: '10px 12px',
    borderRadius: 6, fontSize: 14,
}
const btn = (disabled: boolean): React.CSSProperties => ({
    padding: '12px', background: disabled ? '#aaa' : '#2b6cb0',
    color: '#fff', border: 'none', borderRadius: 6,
    cursor: disabled ? 'not-allowed' : 'pointer',
    fontWeight: 600, fontSize: 15, marginTop: 4,
})
