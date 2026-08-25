import type { ChangeEvent, CSSProperties } from 'react'
import { useTranslation } from 'react-i18next'
import { DEFAULT_LOCALE, isSupportedLocale } from '@ec/i18n'

type Props = {
    style?: CSSProperties
}

export default function LanguageSwitcher({ style }: Props) {
    const { t, i18n } = useTranslation()
    const currentLocale = isSupportedLocale(i18n.resolvedLanguage)
        ? i18n.resolvedLanguage
        : DEFAULT_LOCALE

    function handleChange(event: ChangeEvent<HTMLSelectElement>) {
        const locale = event.target.value
        if (isSupportedLocale(locale)) {
            void i18n.changeLanguage(locale)
        }
    }

    return (
        <select
            aria-label={t('language.label')}
            value={currentLocale}
            onChange={handleChange}
            style={{ ...selectStyle, ...style }}
        >
            <option value="ja">{t('language.japanese')}</option>
            <option value="ko">{t('language.korean')}</option>
        </select>
    )
}

const selectStyle: CSSProperties = {
    border: '1px solid #d1d5db',
    borderRadius: 6,
    background: '#fff',
    color: '#334155',
    padding: '5px 8px',
    fontSize: 13,
    cursor: 'pointer',
}
