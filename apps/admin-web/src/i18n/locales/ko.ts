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
            status: '판매 상태',
            active: '판매 중',
            inactive: '판매 중지',
            deactivate: '판매 중지',
            reactivate: '판매 재개',
            deactivateConfirm: '이 상품의 판매를 중지하시겠습니까?',
            deactivating: '중지 중...',
            reactivating: '재개 중...',
        },
        order: {
            status: {
                pending: '주문 접수',
                preparing: '배송 준비 중',
                shipped: '배송 중',
                delivered: '배송 완료',
                cancelled: '취소됨',
            },
            transition: {
                select: '다음 상태 선택',
                none: '변경 불가',
                failed: '주문 상태 변경에 실패했습니다.',
            },
            loadFailed: '주문 조회에 실패했습니다.',
        },
        shipping: {
            title: '배송지',
            legacyUnavailable: '이 주문에는 배송지 정보가 등록되어 있지 않습니다.',
        },
        errors: {
            api: {
                invalidOrderTransition: '주문 상태가 변경되어 처리할 수 없습니다.',
                orderNotFound: '주문을 찾을 수 없습니다.',
            },
        },
    },
} as const
