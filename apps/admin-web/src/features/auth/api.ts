import { api } from '@/lib/api'
import type { AuthUser } from '@/lib/authStore'

const BASE = '/api/public/auth'

export type LoginRequest = {
    email: string
    password: string
}

export type AuthResponse = {
    accessToken: string
    tokenType: string
    user: AuthUser
}

export const authApi = {
    login: (data: LoginRequest) => api.post<AuthResponse>(BASE + '/login', data),
    me: () => api.get<AuthUser>(BASE + '/me'),
}

