import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { ProductApi } from '@/features/products/api'
import type { Product } from '@/types/product'

export default function AdminProductListPage() {
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
            <h1>Admin - Products</h1>

            <div style={{ marginBottom: 16 }}>
                <button onClick={() => navigate('/products/new')}>+ New Product</button>
            </div>

            {loading ? (
                <div>Loading...</div>
            ) : (
                <table border={1} cellPadding={8}>
                    <thead>
                    <tr>
                        <th>ID</th><th>Name</th><th>Price</th><th>Image</th><th>Description</th><th>Actions</th>
                    </tr>
                    </thead>
                    <tbody>
                    {items.map(p => (
                        <tr key={p.id}>
                            <td>{p.id}</td>
                            <td>{p.name}</td>
                            <td>{p.price.toLocaleString()}</td>
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
                        <tr><td colSpan={6}>No data</td></tr>
                    )}
                    </tbody>
                </table>
            )}
        </div>
    )
}
