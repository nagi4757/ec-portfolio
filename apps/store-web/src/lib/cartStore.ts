type Listener = (totalQuantity: number) => void

let totalQuantity = 0
const listeners = new Set<Listener>()

function emit() {
    for (const listener of listeners) {
        listener(totalQuantity)
    }
}

export const cartStore = {
    getTotalQuantity(): number {
        return totalQuantity
    },
    setTotalQuantity(next: number) {
        totalQuantity = Math.max(0, next)
        emit()
    },
    subscribe(listener: Listener): () => void {
        listeners.add(listener)
        return () => listeners.delete(listener)
    },
}

