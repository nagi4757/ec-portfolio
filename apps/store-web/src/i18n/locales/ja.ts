export const storeJa = {
    store: {
        navigation: {
            cart: 'カート',
            myOrders: '注文履歴',
            signedInUser: '{{name}} 様',
        },
        actions: {
            signUp: '新規登録',
        },
        stock: {
            label: '在庫',
            inStock: '在庫あり',
            outOfStock: '在庫切れ',
            remaining: '残り{{count}}点',
            insufficient: '在庫が不足しています。',
        },
        cart: {
            add: 'カートに追加',
            adding: '追加中...',
            added: 'カートに追加しました。',
            loginRequired: 'ログイン後にカートをご利用ください。',
            addFailed: 'カートへの追加に失敗しました。',
        },
    },
} as const
