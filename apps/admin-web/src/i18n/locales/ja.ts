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
            status: '販売状態',
            active: '販売中',
            inactive: '販売停止',
            deactivate: '販売停止',
            reactivate: '販売再開',
            deactivateConfirm: 'この商品の販売を停止しますか？',
            deactivating: '停止中...',
            reactivating: '再開中...',
        },
        order: {
            status: {
                pending: '注文受付',
                preparing: '発送準備中',
                shipped: '発送済み',
                delivered: '配送完了',
                cancelled: 'キャンセル済み',
            },
            transition: {
                select: '次の状態を選択',
                none: '変更不可',
                failed: '注文状態の変更に失敗しました。',
            },
            loadFailed: '注文の取得に失敗しました。',
        },
        errors: {
            api: {
                invalidOrderTransition: '注文状態が変更されたため、処理できません。',
                orderNotFound: '注文が見つかりません。',
            },
        },
    },
} as const
