import { authStore } from '@/lib/authStore'

const BASE_URL = (import.meta.env.VITE_API_BASE_URL ?? '').trim().replace(/\/+$/, '')

type ApiErrorResponse = {
    code?: unknown
    correlationId?: unknown
}

export class ApiError extends Error {
    public readonly status: number
    public readonly code: string | null
    public readonly correlationId: string | null

    constructor(status: number, code: string | null, message: string, correlationId: string | null = null) {
        super(message)
        this.name = 'ApiError'
        this.status = status
        this.code = code
        this.correlationId = correlationId
    }
}

export function isApiErrorCode(error: unknown, code: string): error is ApiError {
    return error instanceof ApiError && error.code === code
}

async function request<T>(url: string, init?: RequestInit): Promise<T> {
    const token = authStore.getToken()
    const headers: Record<string, string> = {}
    if (init?.body !== undefined) headers['Content-Type'] = 'application/json'
    if (token) {
        headers['Authorization'] = `Bearer ${token}`
    }

    const res = await fetch(`${BASE_URL}${url}`, {
        headers,
        ...init,
    })
    let correlationId = res.headers.get('X-Correlation-ID')

    if (!res.ok) {
        let code: string | null = null
        try {
            const body: unknown = await res.json()
            if (body && typeof body === 'object') {
                const error = body as ApiErrorResponse
                code = typeof error.code === 'string' ? error.code : null
                if (typeof error.correlationId === 'string') correlationId = error.correlationId
            }
        } catch {
            // An upstream HTML error must not become a user-facing server payload.
        }

        const isAuthRequest = url === '/api/public/auth/login' || url === '/api/public/auth/signup'
        // A late 401 must not clear a newer session. Failed logins stay on the form.
        if (res.status === 401 && !isAuthRequest && token && token === authStore.getToken()) {
            authStore.clear()
            window.location.href = '/login'
        }
        throw new ApiError(res.status, code, `API request failed (HTTP ${res.status}).`, correlationId)
    }

    if (res.status === 204) {
        return undefined as T
    }

    const contentType = res.headers.get('content-type')?.split(';')[0].trim().toLowerCase()
    if (contentType !== 'application/json') {
        throw new ApiError(res.status, null, 'Expected a JSON API response. Check VITE_API_BASE_URL.', correlationId)
    }

    try {
        return await res.json() as T
    } catch {
        throw new ApiError(res.status, null, 'Invalid JSON API response.', correlationId)
    }
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
