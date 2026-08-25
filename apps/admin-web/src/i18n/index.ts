import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
import {
    commonResources,
    DEFAULT_LOCALE,
    getInitialLocale,
    isSupportedLocale,
    persistLocale,
    SUPPORTED_LOCALES,
} from '@ec/i18n'
import { adminJa } from './locales/ja'
import { adminKo } from './locales/ko'

const initialLocale = getInitialLocale()

function applyLocale(language: string) {
    const locale = isSupportedLocale(language) ? language : DEFAULT_LOCALE
    persistLocale(locale)
    document.documentElement.lang = locale
}

document.documentElement.lang = initialLocale
i18n.on('languageChanged', applyLocale)

void i18n
    .use(initReactI18next)
    .init({
        resources: {
            ja: { translation: { ...commonResources.ja, ...adminJa } },
            ko: { translation: { ...commonResources.ko, ...adminKo } },
        },
        lng: initialLocale,
        fallbackLng: DEFAULT_LOCALE,
        supportedLngs: [...SUPPORTED_LOCALES],
        interpolation: {
            escapeValue: false,
        },
        react: {
            useSuspense: false,
        },
    })

export default i18n
