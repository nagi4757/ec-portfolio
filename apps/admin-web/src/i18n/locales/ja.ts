export const adminJa = {
    admin: {
        navigation: {
            products: '商品',
            categories: 'カテゴリー',
            orders: '注文',
        },
        auth: {
            title: '管理者ログイン',
            email: 'メールアドレス',
            password: 'パスワード',
            passwordPlaceholder: '8文字以上',
            loginInProgress: 'ログイン中...',
            loginFailed: 'ログインに失敗しました。',
        },
        product: {
            stockQuantity: '在庫',
            inStock: '在庫あり',
            outOfStock: '在庫切れ',
        },
    },
} as const
