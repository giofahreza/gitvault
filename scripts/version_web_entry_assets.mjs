import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const [outputDirectory, revision] = process.argv.slice(2);

if (!outputDirectory || !revision) {
  throw new Error("Usage: node scripts/version_web_entry_assets.mjs <build-directory> <revision>");
}

if (!/^[A-Za-z0-9._-]+$/.test(revision)) {
  throw new Error("The web asset revision contains unsupported characters.");
}

const indexPath = resolve(outputDirectory, "index.html");
const bootstrapPath = resolve(outputDirectory, "flutter_bootstrap.js");
const cacheQuery = `rev=${encodeURIComponent(revision)}`;

function replaceExactlyOnce(source, pattern, replacement, description) {
  const matches = [...source.matchAll(pattern)];
  if (matches.length !== 1) {
    throw new Error(`Expected one ${description} reference, found ${matches.length}.`);
  }

  return source.replace(pattern, replacement);
}

const indexHtml = readFileSync(indexPath, "utf8");
const versionedIndexHtml = replaceExactlyOnce(
  indexHtml,
  /(<script\s+src=(["']))flutter_bootstrap\.js(?:\?[^"']*)?\2/g,
  `$1flutter_bootstrap.js?${cacheQuery}$2`,
  "Flutter bootstrap",
);
writeFileSync(indexPath, versionedIndexHtml);

const bootstrap = readFileSync(bootstrapPath, "utf8");
const versionedBootstrap = replaceExactlyOnce(
  bootstrap,
  /("mainJsPath"\s*:\s*")main\.dart\.js(?:\?[^"']*)?"/g,
  `$1main.dart.js?${cacheQuery}"`,
  "Flutter main entrypoint",
);
writeFileSync(bootstrapPath, versionedBootstrap);
