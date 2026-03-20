import zhCN from './zh-CN.js';
import enUS from './en-US.js';

const localeCatalog = {
  'zh-CN': zhCN,
  zh: zhCN,
  'en-US': enUS,
  en: enUS,
};

function normalizeLocaleTag(input) {
  const raw = String(input || '').trim();
  if (!raw) return 'zh-CN';

  const lower = raw.replace('_', '-').toLowerCase();
  if (lower === 'zh' || lower === 'zh-cn' || lower === 'zh-hans') return 'zh-CN';
  if (lower === 'en' || lower === 'en-us') return 'en-US';

  const [language, region] = lower.split('-');
  if (!region) return language || 'zh';
  return `${language}-${region.toUpperCase()}`;
}

export function resolveLocale(source) {
  const requested = typeof source === 'string' ? source : source?.RALPH_LANG;
  const normalized = normalizeLocaleTag(requested);
  const base = normalized.split('-')[0];
  return localeCatalog[normalized] || localeCatalog[base] || localeCatalog['zh-CN'];
}

export function t(source, key, ...args) {
  const locale = resolveLocale(source);
  const fallback = localeCatalog['zh-CN'];
  const value = locale[key] ?? fallback[key];
  if (value === undefined) return key;
  return typeof value === 'function' ? value(...args) : value;
}
