#!/usr/bin/env node
// Translates the String Catalogs into the shipped languages (Tools/l10n/locales.txt) with Claude, following
// Docs/Localization.md. Only strings that are missing or unfinished in a language are sent; finished ones are
// never touched, so it's safe to run after every change. Uses the `claude` command line tool (Claude Code), so it
// needs no API key of its own.
//
//     node Tools/l10n/translate.mjs [catalog.xcstrings ...] [--locales de,ja] [--model <model>] [--batch 40]
//                                   [--dry-run]
//
// Every answer is checked like Tools/l10n/check.mjs does (placeholders, links, plural forms); an answer that fails
// is left out and reported, so the next run asks again. Run check.mjs afterwards.
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  ROOT, findCatalogs, leaves, markup, placeholders, pluralGroups, readCatalog, rel, requiredPluralCategories,
  pluralCategories, shippedLocales, sourceLocalization, translatableKeys, writeCatalog,
} from './lib.mjs';

const args = process.argv.slice(2);
const opt = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : undefined; };
const files = args.filter((a) => a.endsWith('.xcstrings'));
const locales = opt('--locales')?.split(',') ?? shippedLocales();
const model = opt('--model');
const batchSize = Number(opt('--batch') ?? 40);
const dryRun = args.includes('--dry-run');
const guide = readFileSync(join(ROOT, 'Docs/Localization.md'), 'utf8');
const appName = opt('--app') ?? readAppName();

function readAppName() {
  try {
    return readFileSync(join(ROOT, 'project.yml'), 'utf8').match(/^name:\s*(.+)$/m)?.[1]?.trim() ?? 'the app';
  } catch { return 'the app'; }
}

/** What to send for one key: its English leaves, comment, and the plural forms the language needs. */
function item(id, key, entry, src) {
  const en = sourceLocalization(key, entry, src);
  const groups = pluralGroups(en);
  const english = {};
  for (const l of leaves(en)) english[l.path] = l.value;
  return { id, key, comment: entry.comment ?? null, english, plural: Object.keys(groups).length > 0, en };
}

/** Builds the localization for `locale` from the model's answer `{ "<path>": "<text>" }`, or explains the problem. */
function build(it, locale, answer) {
  const groups = pluralGroups(it.en);
  const unit = (value) => ({ stringUnit: { state: 'translated', value } });
  const need = (prefix) => {
    const forms = {};
    for (const c of pluralCategories(locale)) {
      const k = `${prefix}plural.${c}`;
      if (answer[k] != null) forms[c] = unit(answer[k]);
    }
    for (const c of requiredPluralCategories(locale)) if (!forms[c]) throw new Error(`missing plural "${c}" at ${prefix || 'top'}`);
    return forms;
  };
  // Top-level shape mirrors English.
  let loc;
  if (groups['']) loc = { variations: { plural: need('') } };
  else loc = unit(answer.value ?? answer[Object.keys(it.english).find((p) => !p.includes('.')) ?? 'value']);
  if (it.en.substitutions) {
    if (answer.value == null) throw new Error('missing value');
    loc = { ...unit(answer.value), substitutions: {} };
    for (const [name, sub] of Object.entries(it.en.substitutions)) {
      const { variations, stringUnit, ...rest } = sub;
      loc.substitutions[name] = { ...rest, variations: { plural: need(`sub.${name}.`) } };
    }
  }
  // Same checks as check.mjs.
  for (const l of leaves(loc)) {
    if (!l.value?.trim()) throw new Error(`${l.path} empty`);
    const enPath = l.path.replace(/\.(zero|one|two|few|many|other)$/, '.other');
    const enValue = it.english[l.path] ?? it.english[enPath] ?? it.english.value ?? it.key;
    const a = placeholders(enValue), b = placeholders(l.value);
    const exact = !/plural\.(zero|one|two)$/.test(l.path);
    if (exact ? a.join() !== b.join() : b.some((p) => !a.includes(p))) throw new Error(`${l.path} placeholders ${b} ≠ ${a}`);
    if (JSON.parse(markup(enValue)).links.join() !== JSON.parse(markup(l.value)).links.join()) throw new Error(`${l.path} links differ`);
  }
  return loc;
}

function prompt(locale, items) {
  const forms = pluralCategories(locale).join(', ');
  return `You translate the user interface of ${appName}, a macOS app by Polytopic Systems, from English into the
language with code "${locale}". Follow this style guide and glossary exactly:

<style-guide>
${guide}
</style-guide>

Translate each item below. Each item has an "id", the English text as "english" (an object of path → text), and
sometimes a "comment" saying where it appears. Return ONLY a JSON object, no prose, of this shape:
{"translations": [{"id": "<id>", "<path>": "<translated text>", ...}, ...]}

Rules for paths:
- A plain string has the single path "value": answer {"id": "...", "value": "..."}.
- A plural string has paths like "plural.one" and "plural.other" (or "sub.<name>.plural.<form>" plus "value").
  Answer every plural form ${locale} uses: ${forms}. Use the English "other" text as the meaning of every form.
- Keep every placeholder (%@, %lld, %d, %1$@, %#@name@, %%) exactly, the same count and types. In a plural form
  for one/two you may write the number as a word instead of the placeholder.
- Keep Markdown (**bold**, [text](url) with the url unchanged) and line breaks (\\n).

Items:
${JSON.stringify(items.map(({ id, comment, english }) => ({ id, ...(comment ? { comment } : {}), english })), null, 1)}
`;
}

function runClaude(text) {
  return new Promise((resolve, reject) => {
    const argv = ['-p', '--output-format', 'json', ...(model ? ['--model', model] : [])];
    const child = spawn('claude', argv, { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '', err = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code !== 0) return reject(new Error(`claude exited ${code}: ${err.slice(0, 400)}`));
      try {
        const result = JSON.parse(out).result ?? '';
        const json = result.slice(result.indexOf('{'), result.lastIndexOf('}') + 1);
        resolve(JSON.parse(json).translations ?? []);
      } catch (e) {
        reject(new Error(`unreadable answer: ${e.message}: ${out.slice(0, 300)}`));
      }
    });
    child.stdin.end(text);
  });
}

async function pool(tasks, size) {
  const results = [];
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(size, tasks.length) }, async () => {
    while (i < tasks.length) { const t = tasks[i++]; results.push(await t()); }
  }));
  return results;
}

let failed = 0;
let written = 0;
for (const path of files.length ? files : findCatalogs()) {
  const catalog = readCatalog(path);
  const src = catalog.sourceLanguage ?? 'en';
  const keys = translatableKeys(catalog);
  const tasks = [];
  for (const locale of locales) {
    const todo = keys.filter(([, e]) => {
      const loc = e.localizations?.[locale];
      return !loc || leaves(loc).some((l) => l.state !== 'translated' || !l.value?.trim());
    }).map(([key, e], n) => item(`k${n}`, key, e, src));
    if (!todo.length) continue;
    console.log(`${rel(path)} [${locale}]: ${todo.length} to translate`);
    if (dryRun) continue;
    for (let b = 0; b < todo.length; b += batchSize) {
      const batch = todo.slice(b, b + batchSize);
      tasks.push(async () => {
        try {
          const answers = await runClaude(prompt(locale, batch));
          const byId = new Map(answers.map((a) => [a.id, a]));
          for (const it of batch) {
            const a = byId.get(it.id);
            if (!a) { failed++; console.log(`  [${locale}] no answer for "${it.key}"`); continue; }
            try {
              const loc = build(it, locale, a);
              const entry = catalog.strings[it.key];
              entry.localizations = { ...(entry.localizations ?? {}), [locale]: loc };
              written++;
            } catch (e) { failed++; console.log(`  [${locale}] "${it.key}": ${e.message}`); }
          }
          console.log(`  [${locale}] batch ${b / batchSize + 1}: ${batch.length} done`);
        } catch (e) { failed += batch.length; console.log(`  [${locale}] batch ${b / batchSize + 1} failed: ${e.message}`); }
      });
    }
  }
  if (tasks.length) {
    await pool(tasks, 4);
    writeCatalog(path, catalog);
  }
}
console.log(`l10n: ${written} translations written, ${failed} left for the next run`);
process.exit(failed ? 1 : 0);
