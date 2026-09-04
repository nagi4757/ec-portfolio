import { useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { CategoryApi } from '@/features/categories/api'
import type { Category, CreateCategory, UpdateCategory } from '@/types/category'
import CategoryForm from '../components/CategoryForm'
import { ApiError } from '@/lib/api'

export default function AdminCategoryEditPage() {
    const { id } = useParams<{ id: string }>()
    const navigate = useNavigate()
    const { t } = useTranslation()

    const isNew = !id
    const categoryId = id ? Number(id) : null
    const isEdit = !isNew && categoryId !== null && Number.isSafeInteger(categoryId) && categoryId > 0

    const [initial, setInitial] = useState<Category | null>(null)
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
        if (!isEdit) return
        let active = true
        ;(async () => {
            try {
                const data = await CategoryApi.get(categoryId!)
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
    }, [isEdit, categoryId, reloadVersion])

    async function handleSubmit(data: CreateCategory | UpdateCategory) {
        if (saving || (!isNew && (!isEdit || initial?.id !== categoryId))) return
        setSaving(true)
        setSaveError(null)
        try {
            if (isNew) {
                await CategoryApi.create(data as CreateCategory)
            } else if (isEdit) {
                await CategoryApi.update(categoryId!, data as UpdateCategory)
            } else {
                throw new Error(`Invalid category id: ${id}`)
            }
            navigate('/categories')
        } catch (cause) {
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

    if (isEdit && (loading || initial?.id !== categoryId)) return <div style={{ padding: 24 }}>Loading...</div>

    return (
        <div style={{ padding: 24 }}>
            <h1>{isNew ? '카테고리 등록' : `카테고리 수정 #${id}`}</h1>
            {saveError && <p role="alert" style={{ color: '#e53e3e' }}>{t(saveError)}</p>}
            <CategoryForm key={id ?? 'new'} initial={isNew ? null : initial} onSubmit={handleSubmit} submitting={saving} />
        </div>
    )
}
