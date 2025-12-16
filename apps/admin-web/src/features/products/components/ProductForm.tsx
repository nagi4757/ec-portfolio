import { useEffect, useState } from 'react'
import type { CreateProduct, UpdateProduct, Product } from '@/types/product'

type Props = {
    initial?: Product | null
    onSubmit: (data: CreateProduct | UpdateProduct) => Promise<void> | void
    submitting?: boolean
}

export default function ProductForm({ initial, onSubmit, submitting }: Props) {
    const [name, setName] = useState(initial?.name ?? '')
    const [price, setPrice] = useState<number>(initial?.price ?? 0)
    const [imageUrl, setImageUrl] = useState<string>(initial?.imageUrl ?? '')
    const [description, setDescription] = useState<string>(initial?.description ?? '')

    useEffect(() => {
        setName(initial?.name ?? '')
        setPrice(initial?.price ?? 0)
        setImageUrl(initial?.imageUrl ?? '')
        setDescription(initial?.description ?? '')
    }, [initial])

    return (
        <form
            className="flex flex-col gap-12"
            onSubmit={async (e) => {
                e.preventDefault()
                const payload = initial
                    ? ({ name, price, imageUrl, description } as UpdateProduct)
                    : ({ name, price, imageUrl, description } as CreateProduct)
                await onSubmit(payload)
            }}
        >
            <label>
                <div>Name</div>
                <input value={name} onChange={(e) => setName(e.target.value)} required />
            </label>

            <label>
                <div>Price</div>
                <input
                    type="number"
                    value={price}
                    min={0}
                    onChange={(e) => setPrice(Number(e.target.value))}
                    required
                />
            </label>

            <label>
                <div>Image URL</div>
                <input value={imageUrl} onChange={(e) => setImageUrl(e.target.value)} />
            </label>

            <label>
                <div>Description</div>
                <textarea value={description} onChange={(e) => setDescription(e.target.value)} />
            </label>

            <button type="submit" disabled={submitting}>
                {submitting ? 'Saving...' : 'Save'}
            </button>
        </form>
    )
}
