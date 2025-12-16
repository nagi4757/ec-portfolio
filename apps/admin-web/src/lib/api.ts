const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:8080'

async function request<T>(url: string, init?: RequestInit): Promise<T> {
    const res = await fetch(`${BASE_URL}${url}`, {
        headers: { 'Content-Type': 'application/json' },
        ...init,
    })
    if (!res.ok) {
        const text = await res.text().catch(() => '')
        throw new Error(`HTTP ${res.status} ${res.statusText} :: ${text}`)
    }
    return res.json() as Promise<T>
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
