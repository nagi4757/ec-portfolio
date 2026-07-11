import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import AdminProductListPage from '@/features/products/pages/AdminProductListPage'
import AdminProductEditPage from '@/features/products/pages/AdminProductEditPage'
import AdminCategoryListPage from '@/features/categories/pages/AdminCategoryListPage'
import AdminCategoryEditPage from '@/features/categories/pages/AdminCategoryEditPage'

export default function App() {
    return (
        <BrowserRouter>
            <Routes>
                <Route path="/" element={<Navigate to="/products" replace />} />
                <Route path="/products" element={<AdminProductListPage />} />
                <Route path="/products/new" element={<AdminProductEditPage />} />
                <Route path="/products/:id/edit" element={<AdminProductEditPage />} />
                <Route path="/categories" element={<AdminCategoryListPage />} />
                <Route path="/categories/new" element={<AdminCategoryEditPage />} />
                <Route path="/categories/:id/edit" element={<AdminCategoryEditPage />} />
            </Routes>
        </BrowserRouter>
    )
}
