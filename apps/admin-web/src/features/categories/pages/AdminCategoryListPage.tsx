import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate } from 'react-router-dom'
import { CategoryApi } from '@/features/categories/api'
import type { Category } from '@/types/category'
import { ApiError } from '@/lib/api'

export default function AdminCategoryListPage() {
    const { t } = useTranslation()
    const [items, setItems] = useState<Category[]>([])
    const [loading, setLoading] = useState(true)
    const [loadError, setLoadError] = useState<string | null>(null)
    const [actionError, setActionError] = useState<string | null>(null)
    const [deletingId, setDeletingId] = useState<number | null>(null)
    const navigate = useNavigate()

    const load = useCallback(async () => {
        setLoading(true)
        setLoadError(null)
        try {
            const data = await CategoryApi.list()
            setItems(data)
        } catch (cause) {
            setLoadError(cause instanceof ApiError && cause.status === 403
                ? 'admin.feedback.forbidden' : 'admin.feedback.loadFailed')
        } finally {
            setLoading(false)
        }
    }, [])

    useEffect(() => {
        void load()
    }, [load])

    async function onDelete(id: number) {
        if (deletingId !== null) return
        if (!confirm(`Delete category ${id}?`)) return
        setDeletingId(id)
        setActionError(null)
        try {
            await CategoryApi.remove(id)
            await load()
        } catch (cause) {
            setActionError(cause instanceof ApiError && cause.status === 403
                ? 'admin.feedback.forbidden' : 'admin.feedback.deleteFailed')
        } finally {
            setDeletingId(null)
        }
    }

    return (
        <div style={{ padding: 24 }}>
            <h1>카테고리 관리</h1>

            <div style={{ marginBottom: 16 }}>
                <button onClick={() => navigate('/categories/new')}>+ New Category</button>
            </div>

            {actionError && <p role="alert" style={{ color: '#e53e3e' }}>{t(actionError)}</p>}

            {loading ? (
                <div>Loading...</div>
            ) : loadError ? (
                <div role="alert">
                    <p>{t(loadError)}</p>
                    <button type="button" onClick={() => void load()}>{t('admin.feedback.retry')}</button>
                </div>
            ) : (
                <div style={{ overflowX: 'auto' }}>
                    <table border={1} cellPadding={8} style={{ minWidth: 640, width: '100%', background: '#fff' }}>
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
                                        <button disabled={deletingId !== null} onClick={() => onDelete(c.id)}>Delete</button>
                                    </td>
                                </tr>
                            ))}
                            {items.length === 0 && (
                                <tr><td colSpan={4}>No data</td></tr>
                            )}
                        </tbody>
                    </table>
                </div>
            )}
        </div>
    )
}
