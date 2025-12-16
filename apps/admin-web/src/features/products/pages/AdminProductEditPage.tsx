import { useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { ProductApi } from '@/features/products/api'
import type { Product, CreateProduct, UpdateProduct } from '@/types/product'
import ProductForm from '../components/ProductForm'

export default function AdminProductEditPage() {
    const { id } = useParams<{ id: string }>()
    const navigate = useNavigate()

    const isNew = !id
    const productId = id ? Number(id) : null
    const isEdit = !isNew && productId !== null && Number.isFinite(productId)

    const [initial, setInitial] = useState<Product | null>(null)
    const [loading, setLoading] = useState(isEdit)
    const [saving, setSaving] = useState(false)

    useEffect(() => {
        if (!isEdit) return;
        (async () => {
            setLoading(true)
            try {
                const data = await ProductApi.get(productId!)
                setInitial(data)
            } finally {
                setLoading(false)
            }
        })()
    }, [isEdit, productId])

    async function handleSubmit(data: CreateProduct | UpdateProduct) {
        setSaving(true)
        try {
            if (isNew) {
                await ProductApi.create(data as CreateProduct)
            } else if (isEdit) {
                await ProductApi.update(productId!, data as UpdateProduct)
            } else {
                throw new Error(`Invalid product id: ${id}`)
            }
            navigate('/products')
        } finally {
            setSaving(false)
        }
    }

    if (isEdit && loading) return <div style={{ padding: 24 }}>Loading...</div>

    return (
        <div style={{ padding: 24 }}>
            <h1>{isNew ? 'New Product' : `Edit Product #${id}`}</h1>
            <ProductForm initial={isNew ? null : initial} onSubmit={handleSubmit} submitting={saving} />
        </div>
    )
}
