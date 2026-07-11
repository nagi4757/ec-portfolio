import { useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { CategoryApi } from '@/features/categories/api'
import type { Category, CreateCategory, UpdateCategory } from '@/types/category'
import CategoryForm from '../components/CategoryForm'

export default function AdminCategoryEditPage() {
    const { id } = useParams<{ id: string }>()
    const navigate = useNavigate()

    const isNew = !id
    const categoryId = id ? Number(id) : null
    const isEdit = !isNew && categoryId !== null && Number.isFinite(categoryId)

    const [initial, setInitial] = useState<Category | null>(null)
    const [loading, setLoading] = useState(isEdit)
    const [saving, setSaving] = useState(false)

    useEffect(() => {
        if (!isEdit) return
        ;(async () => {
            setLoading(true)
            try {
                const data = await CategoryApi.get(categoryId!)
                setInitial(data)
            } finally {
                setLoading(false)
            }
        })()
    }, [isEdit, categoryId])

    async function handleSubmit(data: CreateCategory | UpdateCategory) {
        setSaving(true)
        try {
            if (isNew) {
                await CategoryApi.create(data as CreateCategory)
            } else if (isEdit) {
                await CategoryApi.update(categoryId!, data as UpdateCategory)
            } else {
                throw new Error(`Invalid category id: ${id}`)
            }
            navigate('/categories')
        } finally {
            setSaving(false)
        }
    }

    if (isEdit && loading) return <div style={{ padding: 24 }}>Loading...</div>

    return (
        <div style={{ padding: 24 }}>
            <h1>{isNew ? 'New Category' : `Edit Category #${id}`}</h1>
            <div style={{ marginBottom: 16 }}>
                <Link to="/products">Products</Link>
                {' | '}
                <Link to="/categories">Categories</Link>
            </div>
            <CategoryForm initial={isNew ? null : initial} onSubmit={handleSubmit} submitting={saving} />
        </div>
    )
}

