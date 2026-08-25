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
        order: {
            loadFailed: '注文の取得に失敗しました。',
            status: {
                pending: '注文受付',
                preparing: '発送準備中',
                shipped: '発送済み',
                delivered: '配送完了',
                cancelled: 'キャンセル済み',
            },
            actions: {
                cancel: '注文をキャンセル',
                cancelling: 'キャンセル中...',
            },
            cancel: {
                confirm: 'この注文をキャンセルしますか？',
                success: '注文をキャンセルしました。',
                failed: '注文のキャンセルに失敗しました。',
            },
        },
        errors: {
            api: {
                invalidOrderTransition: '注文状態が変更されたため、処理できません。',
                orderNotFound: '注文が見つかりません。',
            },
        },
    },
} as const
