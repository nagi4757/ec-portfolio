import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate } from 'react-router-dom'
import { ProductApi } from '@/features/products/api'
import type { Product } from '@/types/product'
import { ApiError } from '@/lib/api'

type StatusAction = {
    productId: number
    kind: 'deactivate' | 'reactivate'
}

export default function AdminProductListPage() {
    const { t } = useTranslation()
    const [items, setItems] = useState<Product[]>([])
    const [loading, setLoading] = useState(true)
    const [loadError, setLoadError] = useState<string | null>(null)
    const [actionError, setActionError] = useState<string | null>(null)
    const [statusAction, setStatusAction] = useState<StatusAction | null>(null)
    const navigate = useNavigate()

    const load = useCallback(async () => {
        setLoading(true)
        setLoadError(null)
        try {
            const data = await ProductApi.list()
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

    async function onStatusChange(product: Product) {
        if (statusAction) return
        const kind = product.active ? 'deactivate' : 'reactivate'
        if (kind === 'deactivate' && !window.confirm(t('admin.product.deactivateConfirm'))) return

        setStatusAction({ productId: product.id, kind })
        setActionError(null)
        try {
            if (kind === 'deactivate') {
                await ProductApi.remove(product.id)
            } else {
                await ProductApi.update(product.id, { active: true })
            }
            await load()
        } catch (cause) {
            setActionError(cause instanceof ApiError && cause.status === 403
                ? 'admin.feedback.forbidden' : 'admin.feedback.updateFailed')
        } finally {
            setStatusAction(null)
        }
    }

    return (
        <div style={{ padding: 24 }}>
            <h1>상품 관리</h1>

            <div style={{ marginBottom: 16 }}>
                <button onClick={() => navigate('/products/new')}>+ New Product</button>
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
                    <table border={1} cellPadding={8} style={{ minWidth: 760, width: '100%', background: '#fff' }}>
                        <thead>
                        <tr>
                            <th>ID</th><th>Name</th><th>Price</th><th>{t('admin.product.stockQuantity')}</th><th>{t('admin.product.status')}</th><th>Image</th><th>Description</th><th>Actions</th>
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
                                <td>{t(p.active ? 'admin.product.active' : 'admin.product.inactive')}</td>
                                <td>{p.imageUrl}</td>
                                <td>{p.description}</td>
                                <td>
                                    <Link to={`/products/${p.id}/edit`}>Edit</Link>
                                    {' | '}
                                    <button
                                        type="button"
                                        disabled={statusAction !== null}
                                        onClick={() => onStatusChange(p)}
                                    >
                                        {statusAction?.productId === p.id
                                            ? t(statusAction.kind === 'deactivate'
                                                ? 'admin.product.deactivating'
                                                : 'admin.product.reactivating')
                                            : t(p.active
                                                ? 'admin.product.deactivate'
                                                : 'admin.product.reactivate')}
                                    </button>
                                </td>
                            </tr>
                        ))}
                        {items.length === 0 && (
                            <tr><td colSpan={8}>No data</td></tr>
                        )}
                        </tbody>
                    </table>
                </div>
            )}
        </div>
    )
}
