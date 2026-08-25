import { commonJa } from './locales/ja'
import { commonKo } from './locales/ko'

export const SUPPORTED_LOCALES = ['ja', 'ko'] as const

export type SupportedLocale = (typeof SUPPORTED_LOCALES)[number]

export const DEFAULT_LOCALE: SupportedLocale = 'ja'
export const LOCALE_STORAGE_KEY = 'ec_locale'

type LocaleStorage = Pick<Storage, 'getItem' | 'setItem'>

export function isSupportedLocale(value: unknown): value is SupportedLocale {
    return typeof value === 'string' && SUPPORTED_LOCALES.some((locale) => locale === value)
}

export function getInitialLocale(storage: LocaleStorage | null = getBrowserStorage()): SupportedLocale {
    if (!storage) return DEFAULT_LOCALE

    try {
        const storedLocale = storage.getItem(LOCALE_STORAGE_KEY)
        return isSupportedLocale(storedLocale) ? storedLocale : DEFAULT_LOCALE
    } catch {
        return DEFAULT_LOCALE
    }
}

export function persistLocale(
    locale: SupportedLocale,
    storage: LocaleStorage | null = getBrowserStorage(),
): void {
    if (!storage) return

    try {
        storage.setItem(LOCALE_STORAGE_KEY, locale)
    } catch {
        // The selected locale remains active even when browser storage is unavailable.
    }
}

export const commonResources = {
    ja: commonJa,
    ko: commonKo,
} as const

function getBrowserStorage(): Storage | null {
    if (typeof window === 'undefined') return null

    try {
        return window.localStorage
    } catch {
        return null
    }
}
