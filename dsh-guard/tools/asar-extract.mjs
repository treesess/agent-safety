/**
 * Extract the four DSH packages needed by verify-cordis.mjs.
 *
 * Read-only with respect to the DSH installation: it only reads `app.asar` and
 * the profile's `node_modules`, and writes ONLY under `<this script>/node_modules`
 * (the script refuses any other destination).
 *
 * Usage (PowerShell, from this directory):
 *   node asar-extract.mjs
 *   node asar-extract.mjs --asar "D:\path\to\app.asar" --dest ".\node_modules"
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
function arg(name, fallback) {
  const index = args.indexOf(`--${name}`);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
}

const ASAR = arg('asar', 'C:\\Users\\user\\AppData\\Local\\Programs\\DeepSeek Harness\\resources\\app.asar');
const PROFILE_MODULES = arg('profile-modules', 'C:\\Users\\user\\.dsh\\profiles\\desktop\\node_modules');
const DEST = path.resolve(here, arg('dest', 'node_modules'));

// Only ever write inside this tools directory.
const allowedRoot = path.resolve(here) + path.sep;
if (!(DEST + path.sep).startsWith(allowedRoot)) {
  console.error(`refusing to write outside ${here}: ${DEST}`);
  process.exit(2);
}

/** Packages shipped inside app.asar (read by entry offset). */
const IN_ASAR = [
  'dsh/node_modules/@deepseek-ai/cordis',
  'dsh/node_modules/@deepseek-ai/dsh-scope',
];
/** Packages copied from the installed profile (cordis dependencies). */
const IN_PROFILE = [
  '@deepseek-ai/cosmokit',
  '@standard-schema/spec',
];

/** Read the archive header (Electron asar: pickle header + JSON) and index entries. */
function indexAsar(archive) {
  const fd = fs.openSync(archive, 'r');
  const sizeBuf = Buffer.alloc(8);
  fs.readSync(fd, sizeBuf, 0, 8, 0);
  const headerPickleSize = sizeBuf.readUInt32LE(4);
  const headBuf = Buffer.alloc(headerPickleSize);
  fs.readSync(fd, headBuf, 0, headerPickleSize, 8);
  const jsonLen = headBuf.readUInt32LE(4);
  const header = JSON.parse(headBuf.subarray(8, 8 + jsonLen).toString('utf8'));
  const dataOffset = 8 + headerPickleSize;
  const entries = [];
  (function walk(node, prefix) {
    for (const [name, meta] of Object.entries(node.files ?? {})) {
      const p = prefix ? `${prefix}/${name}` : name;
      if (meta.files) walk(meta, p);
      else if (!meta.link) entries.push({ path: p, size: Number(meta.size), offset: Number(meta.offset), unpacked: !!meta.unpacked });
    }
  })(header, '');
  return { fd, dataOffset, entries };
}

if (!fs.existsSync(ASAR)) {
  console.error(`app.asar not found: ${ASAR}`);
  process.exit(2);
}

const { fd, dataOffset, entries } = indexAsar(ASAR);
const ASAR_PREFIX = 'dsh/node_modules/';
let count = 0;
for (const entry of entries) {
  const prefix = IN_ASAR.find((p) => entry.path === p || entry.path.startsWith(`${p}/`));
  if (!prefix) continue;
  // Drop the `dsh/node_modules/` prefix so the extracted tree resolves as
  // node_modules/<package-name>/... from this tools directory.
  const relative = entry.path.startsWith(ASAR_PREFIX) ? entry.path.slice(ASAR_PREFIX.length) : entry.path;
  const out = path.join(DEST, ...relative.split('/'));
  fs.mkdirSync(path.dirname(out), { recursive: true });
  if (entry.unpacked) {
    fs.copyFileSync(path.join(`${ASAR}.unpacked`, ...entry.path.split('/')), out);
    continue;
  }
  const buf = Buffer.alloc(entry.size);
  fs.readSync(fd, buf, 0, entry.size, dataOffset + entry.offset);
  fs.writeFileSync(out, buf);
  count++;
}
fs.closeSync(fd);

for (const name of IN_PROFILE) {
  const source = path.join(PROFILE_MODULES, ...name.split('/'));
  const target = path.join(DEST, ...name.split('/'));
  if (!fs.existsSync(source)) {
    console.error(`missing (is the DSH profile installed?): ${source}`);
    process.exit(3);
  }
  fs.cpSync(source, target, { recursive: true });
}

console.log(`extracted ${count} asar entries + ${IN_PROFILE.length} profile packages into ${DEST}`);
console.log('now run: node verify-cordis.mjs');
