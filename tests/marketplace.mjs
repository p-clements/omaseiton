// Runs the Omarchy plugin marketplace's OWN checks against this repo, using the
// marketplace's source code (not a copy of its rules), so what passes here is what
// their automation will see:
//   1. validateManifest(manifest, { community: true })
//   2. the static security baseline over the tracked files. Anything other than
//      outcome "passed" with no capabilities means the listing would not get the
//      automatic "Verified" status.
//
// Usage: node tests/marketplace.mjs <path to the marketplace's scripts/ folder>
// (tests/marketplace.sh fetches it at a pinned commit and calls this.)

import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { join, resolve } from "node:path"
import { pathToFileURL } from "node:url"

const scriptsDir = resolve(process.argv[2] || process.env.MARKETPLACE_SCRIPTS || "")
const repoDir = resolve(join(import.meta.dirname, ".."))
const load = (name) => import(pathToFileURL(join(scriptsDir, name)).href)

const catalog = await load("build-catalog.mjs")
const analysis = await load("security-baseline-analysis.mjs")
const scope = await load("security-baseline-scope.mjs")

let failed = false
const fail = (message) => {
  console.error("FAIL: " + message)
  failed = true
}

// 1. manifest rules
const manifest = JSON.parse(readFileSync(join(repoDir, "manifest.json"), "utf8"))
try {
  catalog.validateManifest(manifest, "manifest.json", { community: true })
  console.log("manifest: valid (community rules)")
} catch (error) {
  fail("manifest rejected: " + (error.code || "") + " " + error.message)
}

// 2. security baseline over the files the marketplace would scan: tracked files only
const listing = execFileSync("git", ["ls-files", "-s"], { cwd: repoDir, encoding: "utf8" }).trim().split("\n")
const entries = listing.map((line) => {
  const [meta, path] = line.split("\t")
  return { path, mode: meta.split(" ")[0] }
})
const forced = new Set(Object.values(manifest.entryPoints || {}))
const excludedDirs = new Set([".github", "coverage", "docs", "fixtures", "node_modules", "spec", "specs", "test", "tests"])
const selected = entries.filter((entry) => {
  const parts = entry.path.toLowerCase().split("/")
  if (parts.slice(0, -1).some((part) => excludedDirs.has(part)) && !forced.has(entry.path)) return false
  const base = parts.at(-1)
  return scope.isSecurityScanPath(entry.path) || entry.mode === "100755" || !base.includes(".") || forced.has(entry.path)
})
const files = selected.map((entry) => ({ path: entry.path, mode: entry.mode, content: readFileSync(join(repoDir, entry.path), "utf8") }))
console.log("scanned " + files.length + " files: " + files.map((file) => file.path).join(", "))

const result = analysis.buildSecurityBaseline(
  {
    repository: "p-clements/omaseiton",
    repoUrl: "https://github.com/p-clements/omaseiton",
    commitSha: "0123456789abcdef0123456789abcdef01234567",
    files
  },
  { checkedAt: new Date().toISOString() }
)
const capabilities = result.capabilities || []
const where = (capability) => (capability.evidence || []).map((item) => item.path + ":" + item.line + "  " + item.snippet).join("\n      ")
console.log("security baseline: " + result.outcome + ", capabilities: [" + capabilities.map((capability) => capability.id).join(", ") + "]")
if (result.outcome !== "passed" || capabilities.length > 0) {
  fail(
    "not an automatic pass.\n" +
      capabilities.map((capability) => "  - " + capability.id + ": " + capability.why + "\n      " + where(capability)).join("\n") +
      (result.findings || []).map((finding) => "\n  - finding: " + JSON.stringify(finding)).join("")
  )
}

process.exit(failed ? 1 : 0)
