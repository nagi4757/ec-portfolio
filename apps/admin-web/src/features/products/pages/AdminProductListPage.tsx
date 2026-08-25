import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate } from 'react-router-dom'
import { ProductApi } from '@/features/products/api'
import type { Product } from '@/types/product'

export default function AdminProductListPage() {
    const { t } = useTranslation()
    const [items, setItems] = useState<Product[]>([])
    const [loading, setLoading] = useState(true)
    const navigate = useNavigate()

    async function load() {
        setLoading(true)
        try {
            const data = await ProductApi.list()
            setItems(data)
        } finally {
            setLoading(false)
        }
    }

    useEffect(() => {
        load()
    }, [])

    async function onDelete(id: number) {
        if (!confirm(`Delete product ${id}?`)) return
        await ProductApi.remove(id)
        await load()
    }

    return (
        <div style={{ padding: 24 }}>
            <h1>상품 관리</h1>

            <div style={{ marginBottom: 16 }}>
                <button onClick={() => navigate('/products/new')}>+ New Product</button>
            </div>

            {loading ? (
                <div>Loading...</div>
            ) : (
                <div style={{ overflowX: 'auto' }}>
                    <table border={1} cellPadding={8} style={{ minWidth: 760, width: '100%', background: '#fff' }}>
                        <thead>
                        <tr>
                            <th>ID</th><th>Name</th><th>Price</th><th>{t('admin.product.stockQuantity')}</th><th>Image</th><th>Description</th><th>Actions</th>
                        </tr>
                        </thead>
                        <tbody>
                        {items.map(p => (
                            <tr key={p.id}>
                                <td>{p.id}</td>
                                <td>{p.name}</td>
                                <td>{p.price.toLocaleString()}</td>
                                <td>
                                    {p.stockQuantity === 0
                                        ? t('admin.product.outOfStock')
                                        : `${p.stockQuantity} (${t('admin.product.inStock')})`}
                                </td>
                                <td>{p.imageUrl}</td>
                                <td>{p.description}</td>
                                <td>
                                    <Link to={`/products/${p.id}/edit`}>Edit</Link>
                                    {' | '}
                                    <button onClick={() => onDelete(p.id)}>Delete</button>
                                </td>
                            </tr>
                        ))}
                        {items.length === 0 && (
                            <tr><td colSpan={7}>No data</td></tr>
                        )}
                        </tbody>
                    </table>
                </div>
            )}
        </div>
    )
}
