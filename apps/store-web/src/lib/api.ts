// apps/store-web/src/lib/api.ts
const BASE_URL = import.meta.env.VITE_API_BASE_URL as string;

async function request<T>(path: string, init?: RequestInit): Promise<T> {
    const res = await fetch(`${BASE_URL}${path}`, {
        headers: { 'Content-Type': 'application/json' },
        ...init,
    });
    if (!res.ok) {
        throw new Error(`HTTP ${res.status} ${res.statusText}`);
    }
    return res.json() as Promise<T>;
}

export const api = {
    get: <T>(path: string) => request<T>(path),
};