export const storeJa = {
    store: {
        money: {
            amount: '{{amount, number}}円',
        },
        navigation: {
            cart: 'カート',
            myOrders: '注文履歴',
            signedInUser: '{{name}} 様',
        },
        actions: {
            signUp: '新規登録',
        },
        auth: {
            invalidCredentials: 'メールアドレスまたはパスワードが正しくありません。',
            requestFailed: '処理に失敗しました。接続状況を確認し、時間をおいて再度お試しください。',
            invalidInput: '入力内容を確認してください。',
            emailAlreadyUsed: 'このメールアドレスは既に使用されています。',
            passwordMismatch: 'パスワードが一致しません。',
            passwordTooShort: 'パスワードは8文字以上で入力してください。',
        },
        stock: {
            label: '在庫',
            inStock: '在庫あり',
            outOfStock: '在庫切れ',
            remaining: '残り{{count}}点',
            insufficient: '在庫が不足しています。',
        },
        product: {
            notAvailable: 'この商品は現在販売されていません。',
        },
        cart: {
            add: 'カートに追加',
            adding: '追加中...',
            added: 'カートに追加しました。',
            loginRequired: 'ログイン後にカートをご利用ください。',
            addFailed: 'カートへの追加に失敗しました。',
            notAvailable: '販売停止',
            removeUnavailableItem: 'この商品は現在購入できません。カートから削除してください。',
        },
        checkout: {
            title: '配送先と注文内容の確認',
            proceed: '購入手続きへ',
            backToCart: 'カートに戻る',
            orderSummary: '注文内容',
            total: '合計',
            submit: '注文を確定する',
            submitting: '注文処理中...',
            loadFailed: 'カートの取得に失敗しました。',
            submitFailed: '注文の作成に失敗しました。入力内容を確認してください。',
            loginRequired: '購入手続きにはログインが必要です。',
            emptyCart: 'カートに商品がありません。',
            unavailableItems: '購入できない商品が含まれています。カートを確認してください。',
        },
        shipping: {
            title: '配送先',
            recipientName: 'お名前',
            postalCode: '郵便番号',
            prefecture: '都道府県',
            city: '市区町村',
            addressLine1: '番地',
            addressLine2: '建物名・部屋番号（任意）',
            phoneNumber: '電話番号',
            legacyUnavailable: 'この注文には配送先情報が登録されていません。',
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
                productNotFound: '商品が見つかりません。',
                productNotAvailable: 'この商品は現在販売されていません。',
            },
        },
    },
} as const
