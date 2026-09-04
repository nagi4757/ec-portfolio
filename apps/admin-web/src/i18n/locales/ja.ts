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
            invalidCredentials: 'メールアドレスまたはパスワードが正しくありません。',
            requestFailed: 'ログインできませんでした。接続状況を確認し、時間をおいて再度お試しください。',
            adminRequired: '管理者アカウントでログインしてください。',
        },
        feedback: {
            loadFailed: 'データを取得できませんでした。接続状況を確認して再度お試しください。',
            saveFailed: '保存できませんでした。入力内容は保持されています。再度お試しください。',
            updateFailed: '販売状態を変更できませんでした。再度お試しください。',
            deleteFailed: '削除できませんでした。再度お試しください。',
            invalidInput: '入力内容を確認してください。',
            notFound: '対象のデータが見つかりません。URLを確認してください。',
            forbidden: 'この操作を行う権限がありません。管理者アカウントを確認してください。',
            retry: '再試行',
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
        shipping: {
            title: '配送先',
            legacyUnavailable: 'この注文には配送先情報が登録されていません。',
        },
        errors: {
            api: {
                invalidOrderTransition: '注文状態が変更されたため、処理できません。',
                orderNotFound: '注文が見つかりません。',
            },
        },
    },
} as const
