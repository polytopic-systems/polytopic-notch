// Shared by check.mjs and translate.mjs: reading String Catalogs (.xcstrings), the shipped locales, placeholders
// and plural categories. Plain Node, no packages.
import { readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

export const ROOT = new URL('../../', import.meta.url).pathname.replace(/\/$/, '');

/** The shipped locales from Tools/l10n/locales.txt (comments and blank lines skipped). */
export function shippedLocales(file = join(ROOT, 'Tools/l10n/locales.txt')) {
  return readFileSync(file, 'utf8').split('\n').map((l) => l.replace(/#.*/, '').trim()).filter(Boolean);
}

/** Every .xcstrings file in the repo except vendored packages (checked upstream) and build output. */
export function findCatalogs(dir = ROOT) {
  const skip = new Set(['Vendor', 'build', 'builds', 'DerivedData', 'node_modules', '.git', '.build', '.claude']);
  const out = [];
  for (const name of readdirSync(dir)) {
    if (skip.has(name) || name.startsWith('.')) continue;
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) out.push(...findCatalogs(p));
    else if (name.endsWith('.xcstrings')) out.push(p);
  }
  return out.sort();
}

export const rel = (p) => relative(ROOT, p);

export function readCatalog(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

/** Writes a catalog the way Xcode does (2-space JSON, " : " separators, sorted keys), so diffs stay small. */
export function writeCatalog(path, catalog) {
  const sortKeys = (v) => {
    if (Array.isArray(v)) return v.map(sortKeys);
    if (v && typeof v === 'object') {
      return Object.fromEntries(Object.keys(v).sort(compareKeys).map((k) => [k, sortKeys(v[k])]));
    }
    return v;
  };
  const text = JSON.stringify(sortKeys(catalog), null, 2).replace(/^(\s*"(?:[^"\\]|\\.)*"): /gm, '$1 : ');
  writeFileSync(path, text + '\n');
}

// Xcode sorts string keys with a case-insensitive, numeric-aware compare.
const collator = new Intl.Collator('en', { sensitivity: 'base', numeric: true });
const compareKeys = (a, b) => collator.compare(a, b) || (a < b ? -1 : a > b ? 1 : 0);

/** CLDR cardinal plural categories Xcode offers per language. `many` is optional where it only covers millions. */
const PLURALS = {
  en: ['one', 'other'], de: ['one', 'other'], nl: ['one', 'other'], tr: ['one', 'other'], it: ['one', 'many', 'other'],
  es: ['one', 'many', 'other'], fr: ['one', 'many', 'other'], 'pt-BR': ['one', 'many', 'other'], pt: ['one', 'many', 'other'],
  pl: ['one', 'few', 'many', 'other'], uk: ['one', 'few', 'many', 'other'], ru: ['one', 'few', 'many', 'other'],
  ja: ['other'], vi: ['other'], ko: ['other'], 'zh-Hans': ['other'], 'zh-Hant': ['other'], th: ['other'], id: ['other'],
  ar: ['zero', 'one', 'two', 'few', 'many', 'other'], he: ['one', 'two', 'other'],
};
const OPTIONAL_MANY = new Set(['es', 'fr', 'it', 'pt', 'pt-BR']);

export function pluralCategories(locale) {
  return PLURALS[locale] ?? PLURALS[locale.split('-')[0]] ?? ['one', 'other'];
}
export function requiredPluralCategories(locale) {
  const all = pluralCategories(locale);
  return OPTIONAL_MANY.has(locale) ? all.filter((c) => c !== 'many') : all;
}

const SPEC = /%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA])|%#@([A-Za-z0-9_]+)@|%%/g;

/** Placeholders in a string as a sorted signature, so order changes (allowed with positions) still compare equal. */
export function placeholders(value) {
  const found = [];
  let next = 1;
  for (const m of value.matchAll(SPEC)) {
    if (m[0] === '%%') continue;
    if (m[3]) { found.push(`sub:${m[3]}`); continue; }
    const pos = m[1] ? Number(m[1]) : next++;
    let type = m[2];
    if ('dDiuUxXoO'.includes(type)) type = 'int';
    else if ('fFeEgGaA'.includes(type)) type = 'float';
    found.push(`${pos}:${type}`);
  }
  return found.sort();
}

/** Markdown links and bold markers, which must survive translation. */
export function markup(value) {
  const links = [...value.matchAll(/\]\(([^)]+)\)/g)].map((m) => m[1]).sort();
  const bold = (value.match(/\*\*/g) ?? []).length;
  return JSON.stringify({ links, bold });
}

/**
 * The leaves of one localization: [{ path, value, state }]. Handles a plain stringUnit, top-level plural (and
 * device) variations, and substitutions with their own plural variations.
 */
export function leaves(loc) {
  const out = [];
  const walk = (node, path) => {
    if (!node) return;
    if (node.stringUnit) out.push({ path: path || 'value', value: node.stringUnit.value ?? '', state: node.stringUnit.state });
    if (node.variations) {
      for (const [kind, forms] of Object.entries(node.variations)) {
        for (const [form, child] of Object.entries(forms)) walk(child, `${path ? path + '.' : ''}${kind}.${form}`);
      }
    }
    if (node.substitutions) {
      for (const [name, sub] of Object.entries(node.substitutions)) walk(sub, `${path ? path + '.' : ''}sub.${name}`);
    }
  };
  walk(loc, '');
  return out;
}

/** The English (source) localization of a key: the catalog's `en` entry, or the key itself as one stringUnit. */
export function sourceLocalization(key, entry, sourceLanguage = 'en') {
  return entry.localizations?.[sourceLanguage] ?? { stringUnit: { state: 'translated', value: key } };
}

/** Plural variations used by a localization, as { pathPrefix: [categories] } (top level is prefix ''). */
export function pluralGroups(loc) {
  const groups = {};
  const walk = (node, prefix) => {
    if (!node) return;
    if (node.variations?.plural) groups[prefix] = Object.keys(node.variations.plural);
    if (node.substitutions) for (const [n, s] of Object.entries(node.substitutions)) walk(s, `${prefix}sub.${n}.`);
  };
  walk(loc, '');
  return groups;
}

/** Keys that need translating: everything except shouldTranslate:false and stale (no longer in the code). */
export function translatableKeys(catalog) {
  return Object.entries(catalog.strings ?? {}).filter(
    ([key, e]) => e.shouldTranslate !== false && e.extractionState !== 'stale' && /\p{L}/u.test(key),
  );
}
