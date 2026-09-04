import { Navigate } from 'react-router-dom'
import { authStore } from '@/lib/authStore'
import type { ReactNode } from 'react'

type Props = {
    children: ReactNode
}

export default function PrivateRoute({ children }: Props) {
    // This is a UX guard only; the backend remains authoritative for permissions.
    if (!authStore.isLoggedIn() || authStore.getUser()?.role !== 'ADMIN') {
        return <Navigate to="/login" replace />
    }
    return <>{children}</>
}
