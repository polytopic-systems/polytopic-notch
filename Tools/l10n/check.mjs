#!/usr/bin/env node
// Checks the String Catalogs for every shipped language (Tools/l10n/locales.txt). Run it after Tools/l10n/translate.mjs.
//
//     node Tools/l10n/check.mjs [catalog.xcstrings ...] [--locales de,ja] [--warnings]
//
// Fails on: a missing or unfinished translation, placeholders or Markdown links that differ from English, a
// plural form a language needs that isn't there, a translation identical to long English (likely untranslated,
// unless listed in Tools/l10n/same-ok.txt). Warns (with --warnings) on a count placeholder in English without
// plural variations and on translations much longer than English for short strings.
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  ROOT, findCatalogs, leaves, markup, placeholders, pluralGroups, readCatalog, rel, requiredPluralCategories,
  pluralCategories, shippedLocales, sourceLocalization, translatableKeys,
} from './lib.mjs';

const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : undefined; };
const files = args.filter((a, i) => a.endsWith('.xcstrings') && args[i - 1] !== '--locales');
const locales = opt('--locales')?.split(',') ?? shippedLocales();
const sameOkFile = join(ROOT, 'Tools/l10n/same-ok.txt');
const sameOk = new Set(existsSync(sameOkFile)
  ? readFileSync(sameOkFile, 'utf8').split('\n').map((l) => l.replace(/#.*/, '').trim()).filter(Boolean) : []);

const errors = [];
const warnings = [];
let checked = 0;

for (const path of files.length ? files : findCatalogs()) {
  const catalog = readCatalog(path);
  const src = catalog.sourceLanguage ?? 'en';
  for (const [key, entry] of translatableKeys(catalog)) {
    checked++;
    const where = `${rel(path)}: "${key.length > 70 ? key.slice(0, 67) + '…' : key}"`;
    const en = sourceLocalization(key, entry, src);
    const enLeaves = leaves(en);
    const enGroups = pluralGroups(en);
    const enPh = placeholders(enLeaves.find((l) => /plural\.other$|^value$/.test(l.path))?.value ?? key);
    if (!Object.keys(enGroups).length && enPh.some((p) => p.endsWith(':int'))) {
      warnings.push(`${where}: count placeholder without plural variations`);
    }
    for (const locale of locales) {
      const loc = entry.localizations?.[locale];
      if (!loc) { errors.push(`${where} [${locale}]: not translated`); continue; }
      const ls = leaves(loc);
      for (const l of ls) {
        if (l.state !== 'translated') errors.push(`${where} [${locale}] ${l.path}: state "${l.state}"`);
        if (!l.value.trim()) errors.push(`${where} [${locale}] ${l.path}: empty`);
      }
      // Placeholders: each leaf against the matching English leaf (by path), else English "other"/value.
      for (const l of ls) {
        const enLeaf = enLeaves.find((e) => e.path === l.path)
          ?? enLeaves.find((e) => e.path.replace(/\.(zero|one|two|few|many|other)$/, '.other') === l.path.replace(/\.(zero|one|two|few|many|other)$/, '.other'))
          ?? enLeaves.find((e) => e.path === 'value');
        if (!enLeaf) continue;
        // A singular form may drop the number ("one day"), so only plural `other` and plain strings must match exactly.
        const exact = !/plural\.(zero|one|two)$/.test(l.path);
        const a = placeholders(enLeaf.value), b = placeholders(l.value);
        if (exact ? a.join() !== b.join() : b.some((p) => !a.includes(p))) {
          errors.push(`${where} [${locale}] ${l.path}: placeholders ${JSON.stringify(b)} ≠ English ${JSON.stringify(a)}`);
        }
        if (JSON.parse(markup(enLeaf.value)).links.join() !== JSON.parse(markup(l.value)).links.join()) {
          errors.push(`${where} [${locale}] ${l.path}: Markdown links differ from English`);
        }
        if (enLeaf.value.length <= 24 && l.value.length > Math.max(12, enLeaf.value.length * 1.8)) {
          warnings.push(`${where} [${locale}]: "${l.value}" is long for a short string`);
        }
        const words = enLeaf.value.replace(/%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@a-zA-Z]|%#@\w+@/g, ' ');
        const looksEnglish = l.value === enLeaf.value && /\p{L}{4,}\s+(?:\S+\s+)*\p{L}{3,}/u.test(words);
        if (looksEnglish && !sameOk.has(enLeaf.value)) {
          errors.push(`${where} [${locale}] ${l.path}: same as English (add to Tools/l10n/same-ok.txt if intended)`);
        }
      }
      // Plural forms the language needs, wherever English has a plural.
      const locGroups = pluralGroups(loc);
      for (const prefix of Object.keys(enGroups)) {
        const have = locGroups[prefix] ?? [];
        for (const c of requiredPluralCategories(locale)) {
          if (!have.includes(c)) errors.push(`${where} [${locale}] ${prefix}plural: missing "${c}"`);
        }
        for (const c of have) {
          if (!pluralCategories(locale).includes(c) && c !== 'zero') errors.push(`${where} [${locale}] ${prefix}plural: "${c}" isn't a ${locale} plural form`);
        }
      }
    }
  }
}

if (flag('--warnings')) for (const w of warnings) console.log(`warning: ${w}`);
for (const e of errors) console.log(`error: ${e}`);
console.log(`l10n: ${checked} strings × ${locales.length} languages (${locales.join(' ')}): ${errors.length} errors, ${warnings.length} warnings`);
process.exit(errors.length ? 1 : 0);
