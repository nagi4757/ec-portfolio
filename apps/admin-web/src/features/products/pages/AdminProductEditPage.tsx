import { useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ProductApi } from '@/features/products/api'
import type { Product, CreateProduct, UpdateProduct } from '@/types/product'
import ProductForm from '../components/ProductForm'
import { ApiError, isApiErrorCode } from '@/lib/api'

const STOCK_CONFLICT = 'admin.feedback.stockConflict'

export default function AdminProductEditPage() {
    const { id } = useParams<{ id: string }>()
    const navigate = useNavigate()
    const { t } = useTranslation()

    const isNew = !id
    const productId = id ? Number(id) : null
    const isEdit = !isNew && productId !== null && Number.isSafeInteger(productId) && productId > 0

    const [initial, setInitial] = useState<Product | null>(null)
    const [loading, setLoading] = useState(isEdit)
    const [saving, setSaving] = useState(false)
    const [loadError, setLoadError] = useState<string | null>(null)
    const [saveError, setSaveError] = useState<string | null>(null)
    const [reloadVersion, setReloadVersion] = useState(0)

    useEffect(() => {
        setInitial(null)
        setLoadError(null)
        setSaveError(null)
        setLoading(isEdit)
        if (!isEdit) return;
        let active = true;
        (async () => {
            try {
                const data = await ProductApi.get(productId!)
                if (active) setInitial(data)
            } catch (cause) {
                if (active) setLoadError(cause instanceof ApiError && cause.status === 404
                    ? 'admin.feedback.notFound'
                    : cause instanceof ApiError && cause.status === 403
                        ? 'admin.feedback.forbidden' : 'admin.feedback.loadFailed')
            } finally {
                if (active) setLoading(false)
            }
        })()
        return () => { active = false }
    }, [isEdit, productId, reloadVersion])

    async function handleSubmit(data: CreateProduct | UpdateProduct) {
        if (saving || (!isNew && (!isEdit || initial?.id !== productId))) return
        setSaving(true)
        setSaveError(null)
        try {
            if (isNew) {
                await ProductApi.create(data as CreateProduct)
            } else if (isEdit) {
                await ProductApi.update(productId!, data as UpdateProduct)
            } else {
                throw new Error(`Invalid product id: ${id}`)
            }
            navigate('/products')
        } catch (cause) {
            if (isApiErrorCode(cause, 'PRODUCT_STOCK_CONFLICT')) {
                // Checkout or a refund moved the stock after this form loaded, and
                // nothing was saved. Reloading is left to the admin: it replaces
                // everything they typed.
                setSaveError(STOCK_CONFLICT)
                return
            }
            setSaveError(cause instanceof ApiError && cause.status === 400
                ? 'admin.feedback.invalidInput'
                : cause instanceof ApiError && cause.status === 404
                    ? 'admin.feedback.notFound'
                    : cause instanceof ApiError && cause.status === 403
                        ? 'admin.feedback.forbidden' : 'admin.feedback.saveFailed')
        } finally {
            setSaving(false)
        }
    }

    if (!isNew && !isEdit) return <div role="alert" style={{ padding: 24 }}>{t('admin.feedback.notFound')}</div>

    if (isEdit && loadError) return (
        <div role="alert" style={{ padding: 24 }}>
            <p>{t(loadError)}</p>
            <button type="button" onClick={() => setReloadVersion(value => value + 1)}>{t('admin.feedback.retry')}</button>
        </div>
    )

    if (isEdit && (loading || initial?.id !== productId)) return <div style={{ padding: 24 }}>Loading...</div>

    return (
        <div style={{ padding: 24 }}>
            <h1>{isNew ? '상품 등록' : `상품 수정 #${id}`}</h1>
            {saveError && <p role="alert" style={{ color: '#e53e3e' }}>{t(saveError)}</p>}
            {saveError === STOCK_CONFLICT && (
                // Refetches from the server; the new key rebuilds the form from that
                // response instead of keeping the state of the rejected edit.
                <button type="button" onClick={() => setReloadVersion(value => value + 1)}>
                    {t('admin.feedback.reloadLatest')}
                </button>
            )}
            <ProductForm
                key={`${id ?? 'new'}:${reloadVersion}`}
                initial={isNew ? null : initial}
                onSubmit={handleSubmit}
                submitting={saving}
            />
        </div>
    )
}
