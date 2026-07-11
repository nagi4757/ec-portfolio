export type Category = {
    id: number
    name: string
    description?: string | null
}

export type CreateCategory = Omit<Category, 'id'>
export type UpdateCategory = Partial<Omit<Category, 'id'>>

