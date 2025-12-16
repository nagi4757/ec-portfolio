import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import AdminProductListPage from '@/features/products/pages/AdminProductListPage'
import AdminProductEditPage from '@/features/products/pages/AdminProductEditPage'

export default function App() {
    return (
        <BrowserRouter>
            <Routes>
                <Route path="/" element={<Navigate to="/products" replace />} />
                <Route path="/products" element={<AdminProductListPage />} />
                <Route path="/products/new" element={<AdminProductEditPage />} />
                <Route path="/products/:id/edit" element={<AdminProductEditPage />} />
            </Routes>
        </BrowserRouter>
    )
}
