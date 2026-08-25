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
        product: {
            notAvailable: '현재 판매 중지된 상품입니다.',
        },
        cart: {
            add: '장바구니 담기',
            adding: '담는 중...',
            added: '장바구니에 담았습니다.',
            loginRequired: '로그인 후 장바구니를 이용할 수 있습니다.',
            addFailed: '장바구니 담기에 실패했습니다.',
            notAvailable: '판매 중지',
            removeUnavailableItem: '현재 구매할 수 없는 상품입니다. 장바구니에서 삭제해 주세요.',
        },
        order: {
            loadFailed: '주문 조회에 실패했습니다.',
            status: {
                pending: '주문 접수',
                preparing: '배송 준비 중',
                shipped: '배송 중',
                delivered: '배송 완료',
                cancelled: '취소됨',
            },
            actions: {
                cancel: '주문 취소',
                cancelling: '취소 중...',
            },
            cancel: {
                confirm: '이 주문을 취소하시겠습니까?',
                success: '주문을 취소했습니다.',
                failed: '주문 취소에 실패했습니다.',
            },
        },
        errors: {
            api: {
                invalidOrderTransition: '주문 상태가 변경되어 처리할 수 없습니다.',
                orderNotFound: '주문을 찾을 수 없습니다.',
                productNotAvailable: '현재 판매 중지된 상품입니다.',
            },
        },
    },
} as const
