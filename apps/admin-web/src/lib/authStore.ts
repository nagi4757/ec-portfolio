// 토큰/유저 정보를 localStorage에 저장하는 간단한 auth 스토어
const TOKEN_KEY = 'admin_access_token'
const USER_KEY = 'admin_user'

export type AuthUser = {
    id: number
    email: string
    name: string
    role: string
}

export const authStore = {
    getToken(): string | null {
        return localStorage.getItem(TOKEN_KEY)
    },
    getUser(): AuthUser | null {
        try {
            const raw = localStorage.getItem(USER_KEY)
            const user: unknown = raw ? JSON.parse(raw) : null
            if (!user || typeof user !== 'object') return null
            const candidate = user as Partial<AuthUser>
            return typeof candidate.id === 'number' && Number.isFinite(candidate.id)
                && typeof candidate.email === 'string'
                && typeof candidate.name === 'string'
                && typeof candidate.role === 'string'
                ? candidate as AuthUser : null
        } catch {
            return null
        }
    },
    save(token: string, user: AuthUser) {
        localStorage.setItem(TOKEN_KEY, token)
        localStorage.setItem(USER_KEY, JSON.stringify(user))
    },
    clear() {
        localStorage.removeItem(TOKEN_KEY)
        localStorage.removeItem(USER_KEY)
    },
    isLoggedIn(): boolean {
        return !!this.getToken()
    },
}
