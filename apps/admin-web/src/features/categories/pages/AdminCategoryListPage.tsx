import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { CategoryApi } from '@/features/categories/api'
import type { Category } from '@/types/category'

export default function AdminCategoryListPage() {
    const [items, setItems] = useState<Category[]>([])
    const [loading, setLoading] = useState(true)
    const navigate = useNavigate()

    async function load() {
        setLoading(true)
        try {
            const data = await CategoryApi.list()
            setItems(data)
        } finally {
            setLoading(false)
        }
    }

    useEffect(() => {
        load()
    }, [])

    async function onDelete(id: number) {
        if (!confirm(`Delete category ${id}?`)) return
        await CategoryApi.remove(id)
        await load()
    }

    return (
        <div style={{ padding: 24 }}>
            <h1>Admin - Categories</h1>
            <div style={{ marginBottom: 16 }}>
                <Link to="/products">Products</Link>
                {' | '}
                <strong>Categories</strong>
            </div>

            <div style={{ marginBottom: 16 }}>
                <button onClick={() => navigate('/categories/new')}>+ New Category</button>
            </div>

            {loading ? (
                <div>Loading...</div>
            ) : (
                <table border={1} cellPadding={8}>
                    <thead>
                        <tr>
                            <th>ID</th><th>Name</th><th>Description</th><th>Actions</th>
                        </tr>
                    </thead>
                    <tbody>
                        {items.map((c) => (
                            <tr key={c.id}>
                                <td>{c.id}</td>
                                <td>{c.name}</td>
                                <td>{c.description}</td>
                                <td>
                                    <Link to={`/categories/${c.id}/edit`}>Edit</Link>
                                    {' | '}
                                    <button onClick={() => onDelete(c.id)}>Delete</button>
                                </td>
                            </tr>
                        ))}
                        {items.length === 0 && (
                            <tr><td colSpan={4}>No data</td></tr>
                        )}
                    </tbody>
                </table>
            )}
        </div>
    )
}

