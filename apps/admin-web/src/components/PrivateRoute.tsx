import { Navigate } from 'react-router-dom'
import { authStore } from '@/lib/authStore'
import type { ReactNode } from 'react'

type Props = {
    children: ReactNode
}

export default function PrivateRoute({ children }: Props) {
    if (!authStore.isLoggedIn()) {
        return <Navigate to="/login" replace />
    }
    return <>{children}</>
}

