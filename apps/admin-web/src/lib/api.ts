import { authStore } from '@/lib/authStore'

const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:8080'

async function request<T>(url: string, init?: RequestInit): Promise<T> {
    const token = authStore.getToken()
    const headers: Record<string, string> = { 'Content-Type': 'application/json' }
    if (token) {
        headers['Authorization'] = `Bearer ${token}`
    }

    const res = await fetch(`${BASE_URL}${url}`, {
        headers,
        ...init,
    })

    // 이미 로그인된 상태에서 401이 오면 토큰 만료 → 자동 로그아웃
    // 로그인/회원가입 요청 중 401이면 redirect 없이 에러만 throw (에러 메시지 유지)
    if (res.status === 401) {
        if (authStore.getToken()) {
            authStore.clear()
            window.location.href = '/login'
        }
        throw new Error('Unauthorized')
    }
    if (!res.ok) {
        const text = await res.text().catch(() => '')
        throw new Error(`HTTP ${res.status} ${res.statusText} :: ${text}`)
    }

    if (res.status === 204) {
        return undefined as T
    }

    const contentType = res.headers.get('content-type') ?? ''
    if (!contentType.includes('application/json')) {
        const text = await res.text()
        return (text ? (text as T) : (undefined as T))
    }

    const text = await res.text()
    return (text ? JSON.parse(text) : undefined) as T
}

export const api = {
    get: <T>(url: string) => request<T>(url),
    post: <T>(url: string, body: unknown) =>
        request<T>(url, { method: 'POST', body: JSON.stringify(body) }),
    patch: <T>(url: string, body: unknown) =>
        request<T>(url, { method: 'PATCH', body: JSON.stringify(body) }),
    delete: <T>(url: string) =>
        request<T>(url, { method: 'DELETE' }),
}
