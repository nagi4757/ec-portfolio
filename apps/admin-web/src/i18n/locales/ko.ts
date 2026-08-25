export const adminKo = {
    admin: {
        navigation: {
            products: '상품',
            categories: '카테고리',
            orders: '주문',
        },
        auth: {
            title: '관리자 로그인',
            email: '이메일',
            password: '비밀번호',
            passwordPlaceholder: '8자 이상',
            loginInProgress: '로그인 중...',
            loginFailed: '로그인에 실패했습니다.',
        },
        product: {
            stockQuantity: '재고',
            inStock: '재고 있음',
            outOfStock: '품절',
        },
    },
} as const
