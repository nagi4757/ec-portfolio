import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { authApi } from '@/features/auth/api'
import { authStore } from '@/lib/authStore'
import LanguageSwitcher from '@/components/LanguageSwitcher'
import { useTranslation } from 'react-i18next'

export default function LoginPage() {
    const navigate = useNavigate()
    const { t } = useTranslation()
    const [email, setEmail] = useState('')
    const [password, setPassword] = useState('')
    const [loginFailed, setLoginFailed] = useState(false)
    const [loading, setLoading] = useState(false)

    async function handleSubmit(e: React.FormEvent) {
        e.preventDefault()
        setLoginFailed(false)
        setLoading(true)
        try {
            const res = await authApi.login({ email, password })
            authStore.save(res.accessToken, res.user)
            navigate('/', { replace: true })
        } catch {
            setLoginFailed(true)
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
            position: 'relative',
        }}>
            <div style={{ position: 'absolute', top: 16, right: 16 }}>
                <LanguageSwitcher />
            </div>
            <div style={{
                background: '#fff',
                padding: '40px',
                borderRadius: '8px',
                boxShadow: '0 2px 8px rgba(0,0,0,0.12)',
                width: '360px',
            }}>
                <h1 style={{ margin: '0 0 24px', fontSize: '20px' }}>{t('admin.auth.title')}</h1>

                <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
                    <label>
                        <div style={{ marginBottom: '4px', fontWeight: 500 }}>{t('admin.auth.email')}</div>
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
                        <div style={{ marginBottom: '4px', fontWeight: 500 }}>{t('admin.auth.password')}</div>
                        <input
                            type="password"
                            value={password}
                            onChange={(e) => setPassword(e.target.value)}
                            required
                            placeholder={t('admin.auth.passwordPlaceholder')}
                            style={{ width: '100%', padding: '8px', boxSizing: 'border-box', borderRadius: '4px', border: '1px solid #ccc' }}
                        />
                    </label>

                    {loginFailed && (
                        <div style={{ color: '#e53e3e', fontSize: '14px', background: '#fff5f5', padding: '8px 12px', borderRadius: '4px' }}>
                            {t('admin.auth.loginFailed')}
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
                        {loading ? t('admin.auth.loginInProgress') : t('actions.login')}
                    </button>
                </form>
            </div>
        </div>
    )
}
