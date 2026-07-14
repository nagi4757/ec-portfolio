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
        const raw = localStorage.getItem(USER_KEY)
        return raw ? JSON.parse(raw) : null
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

