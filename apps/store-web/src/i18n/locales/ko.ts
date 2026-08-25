export const storeKo = {
    store: {
        navigation: {
            cart: '장바구니',
            myOrders: '내 주문',
            signedInUser: '{{name}}님',
        },
        actions: {
            signUp: '회원가입',
        },
        stock: {
            label: '재고',
            inStock: '재고 있음',
            outOfStock: '품절',
            remaining: '재고 {{count}}개',
            insufficient: '재고가 부족합니다.',
        },
        cart: {
            add: '장바구니 담기',
            adding: '담는 중...',
            added: '장바구니에 담았습니다.',
            loginRequired: '로그인 후 장바구니를 이용할 수 있습니다.',
            addFailed: '장바구니 담기에 실패했습니다.',
        },
    },
} as const
