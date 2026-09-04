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
            invalidCredentials: '이메일 또는 비밀번호가 올바르지 않습니다.',
            requestFailed: '로그인하지 못했습니다. 연결 상태를 확인하고 잠시 후 다시 시도해 주세요.',
            adminRequired: '관리자 계정으로 로그인해 주세요.',
        },
        feedback: {
            loadFailed: '데이터를 불러오지 못했습니다. 연결 상태를 확인하고 다시 시도해 주세요.',
            saveFailed: '저장하지 못했습니다. 입력 내용은 유지되어 있습니다. 다시 시도해 주세요.',
            updateFailed: '판매 상태를 변경하지 못했습니다. 다시 시도해 주세요.',
            deleteFailed: '삭제하지 못했습니다. 다시 시도해 주세요.',
            invalidInput: '입력 내용을 확인해 주세요.',
            notFound: '대상을 찾을 수 없습니다. URL을 확인해 주세요.',
            forbidden: '이 작업을 수행할 권한이 없습니다. 관리자 계정을 확인해 주세요.',
            retry: '다시 시도',
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
