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
        checkout: {
            title: '배송지 및 주문 확인',
            proceed: '주문서 작성',
            backToCart: '장바구니로 돌아가기',
            orderSummary: '주문 상품',
            total: '총 금액',
            submit: '주문 확정',
            submitting: '주문 처리 중...',
            loadFailed: '장바구니를 불러오지 못했습니다.',
            submitFailed: '주문 생성에 실패했습니다. 입력 내용을 확인해 주세요.',
            loginRequired: '주문하려면 로그인이 필요합니다.',
            emptyCart: '장바구니가 비어 있습니다.',
            unavailableItems: '구매할 수 없는 상품이 포함되어 있습니다. 장바구니를 확인해 주세요.',
        },
        shipping: {
            title: '배송지',
            recipientName: '받는 사람',
            postalCode: '우편번호',
            prefecture: '도도부현',
            city: '시구정촌',
            addressLine1: '번지',
            addressLine2: '건물명·호수 (선택)',
            phoneNumber: '전화번호',
            legacyUnavailable: '이 주문에는 배송지 정보가 등록되어 있지 않습니다.',
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
