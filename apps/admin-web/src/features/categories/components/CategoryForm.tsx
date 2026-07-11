import { useEffect, useState } from 'react'
import type { Category, CreateCategory, UpdateCategory } from '@/types/category'

type Props = {
    initial?: Category | null
    onSubmit: (data: CreateCategory | UpdateCategory) => Promise<void> | void
    submitting?: boolean
}

export default function CategoryForm({ initial, onSubmit, submitting }: Props) {
    const [name, setName] = useState(initial?.name ?? '')
    const [description, setDescription] = useState(initial?.description ?? '')

    useEffect(() => {
        setName(initial?.name ?? '')
        setDescription(initial?.description ?? '')
    }, [initial])

    return (
        <form
            className="flex flex-col gap-12"
            onSubmit={async (e) => {
                e.preventDefault()
                const payload = initial
                    ? ({ name, description } as UpdateCategory)
                    : ({ name, description } as CreateCategory)
                await onSubmit(payload)
            }}
        >
            <label>
                <div>Name</div>
                <input value={name} onChange={(e) => setName(e.target.value)} required />
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

