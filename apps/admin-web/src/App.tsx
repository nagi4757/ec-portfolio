import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import AdminProductListPage from '@/features/products/pages/AdminProductListPage'
import AdminProductEditPage from '@/features/products/pages/AdminProductEditPage'
import AdminCategoryListPage from '@/features/categories/pages/AdminCategoryListPage'
import AdminCategoryEditPage from '@/features/categories/pages/AdminCategoryEditPage'
import AdminOrderListPage from '@/features/orders/pages/AdminOrderListPage'
import AdminOrderDetailPage from '@/features/orders/pages/AdminOrderDetailPage'
import LoginPage from '@/features/auth/pages/LoginPage'
import PrivateRoute from '@/components/PrivateRoute'
import AdminLayout from '@/components/AdminLayout'

function ProtectedLayout({ children }: { children: React.ReactNode }) {
    return (
        <PrivateRoute>
            <AdminLayout>{children}</AdminLayout>
        </PrivateRoute>
    )
}

export default function App() {
    return (
        <BrowserRouter>
            <Routes>
                <Route path="/login" element={<LoginPage />} />
                <Route path="/" element={<Navigate to="/products" replace />} />
                <Route path="/products" element={<ProtectedLayout><AdminProductListPage /></ProtectedLayout>} />
                <Route path="/products/new" element={<ProtectedLayout><AdminProductEditPage /></ProtectedLayout>} />
                <Route path="/products/:id/edit" element={<ProtectedLayout><AdminProductEditPage /></ProtectedLayout>} />
                <Route path="/categories" element={<ProtectedLayout><AdminCategoryListPage /></ProtectedLayout>} />
                <Route path="/categories/new" element={<ProtectedLayout><AdminCategoryEditPage /></ProtectedLayout>} />
                <Route path="/categories/:id/edit" element={<ProtectedLayout><AdminCategoryEditPage /></ProtectedLayout>} />
                <Route path="/orders" element={<ProtectedLayout><AdminOrderListPage /></ProtectedLayout>} />
                <Route path="/orders/:id" element={<ProtectedLayout><AdminOrderDetailPage /></ProtectedLayout>} />
            </Routes>
        </BrowserRouter>
    )
}
