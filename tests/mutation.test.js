// Mutation check for Layout.js: break the logic on purpose, in a copy, and make
// sure tests/layout.test.js notices. A mutant that survives means the tests
// assert too little (or the line is dead code).
//
// Run with: node tests/mutation.test.js

const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { spawnSync } = require("node:child_process")

const crypto = require("node:crypto")

// SAFETY: a mutant is a deliberately broken script. The test scripts sandbox
// themselves (fake HOME, guard commands, their own canary), and this harness
// adds one more: the real shell.json must be byte-for-byte unchanged afterwards.
const realConfig = path.join(process.env.HOME || "", ".config", "omarchy", "shell.json")
function checksum() {
  try {
    return crypto.createHash("sha256").update(fs.readFileSync(realConfig)).digest("hex")
  } catch (e) {
    return "absent"
  }
}
const canaryBefore = checksum()

const root = path.join(__dirname, "..")
const original = fs.readFileSync(path.join(root, "Layout.js"), "utf8")
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "omaseiton-mutants-"))

// [description, text to find, replacement, how many times it must occur (default 1)]
const mutants = [
  ["parseJson returns a JSON null as is", "return value === null || value === undefined ? fallback : value", "return value"],
  ["a string bar entry is not accepted", 'if (typeof entry === "string") return entry', 'if (typeof entry === "string") return ""'],
  [
    "non-object entries are not filtered out",
    'filter(function(x) { return x && typeof x === "object" })',
    "filter(function(x) { return true })"
  ],
  [
    "the plugin's canDisable flag is ignored",
    "canDisable: id !== selfId && (plugin ? plugin.canDisable !== false : true)",
    "canDisable: id !== selfId"
  ],
  ["Omaseiton may switch itself off", "canDisable: id !== selfId &&", "canDisable: true &&"],
  ["isSelf is never true", "isSelf: id === selfId", "isSelf: false"],
  ["a widget's clonedFrom is dropped", 'clonedFrom: plugin ? (plugin.clonedFrom || "") : ""', 'clonedFrom: ""'],
  ["an available plugin's clonedFrom is dropped", 'clonedFrom: available[k].clonedFrom || ""', 'clonedFrom: ""'],
  ["a widget's firstParty flag is dropped", "firstParty: plugin ? !!plugin.firstParty : false,", "firstParty: false,"],
  ["an available plugin's firstParty flag is dropped", "firstParty: !!available[k].firstParty,", "firstParty: false,"],
  ["sectionSize is off by one", "sectionSize: entries.length", "sectionSize: entries.length + 1"],
  ["real indices are replaced by a running count", "index: i,", "index: shown,"],
  ["a collapsed lane still lists its widgets", "if (collapsed[section]) continue", "if (false) continue"],
  [
    "a placed widget is also offered as available",
    "if (isBarWidget(p) && !placed[p.id]) available.push(p)",
    "if (isBarWidget(p)) available.push(p)"
  ],
  ["services count as bar widgets", 'plugin.kinds.indexOf("bar-widget") >= 0', "plugin.kinds.length >= 0"],
  ["a collapsed Available list still shows rows", "if (collapsed.available) break", "if (false) break"],
  ["an automatic snapshot loses its time", 'note: "", savedAt: autos[k].savedAt', 'note: "", savedAt: ""'],
  ["My layout loses its time", 'savedAt: mine ? mine.savedAt : ""', 'savedAt: ""'],
  ["My layout loses its widget count", "widgets: mine ? mine.widgets : 0", "widgets: 0"],
  [
    "a save snapshot is called a restore snapshot",
    'autos[k].reason === "save" ? "Before a save" : "Before a restore"',
    '"Before a restore"'
  ],
  [
    "the first move check lets an index past the end through",
    "if (index < 0 || index >= size) return null",
    "if (index < 0 || index > size) return null"
  ],
  ["the first widget can move up", "if (index === 0) return null", "if (index === -1) return null"],
  ["the last widget can move down", "if (index >= size - 1) return null", "if (index > size - 1) return null"],
  ["the left lane has a lane before it", "if (at === 0) return null", "if (at === 1) return null"],
  ["the right lane has a lane after it", "if (at === SECTIONS.length - 1) return null", "if (at === SECTIONS.length) return null"],
  ["moving to the lane you are already in is allowed", "target === section) return null", 'target === "") return null'],
  [
    "findRow ignores the index",
    "rows[i].section === target.section && rows[i].index === target.index",
    "rows[i].section === target.section"
  ],
  ["findRow matches by id against the wrong field", "if (rows[i].id === target.id) return i", "if (rows[i].slot === target.id) return i"],
  ["the cursor can step past the last row", "if (i < 0 || i >= rows.length) return from", "if (i < 0) return from"],
  ["g no longer goes to the first row", 'token === "home" || token === "g"', 'token === "home"'],
  ["G no longer goes to the last row", 'token === "end" || token === "G"', 'token === "end"'],
  ["[ goes the wrong way", 'if (token === "[") return { kind: "lane", dir: -1 }', 'if (token === "[") return { kind: "lane", dir: 1 }'],
  ["Left no longer folds a lane", '{ kind: "fold", value: true }', '{ kind: "fold", value: false }'],
  ["x no longer switches a widget off", 'token === "space" || token === "x"', 'token === "space"'],
  ["capital X switches a widget off", 'token === "space" || token === "x"', 'token === "space" || token === "x" || token === "X"'],
  ["Shift+Up no longer reorders", 'token === "shift+up" || token === "K"', 'token === "K"'],
  ["number keys pick the wrong lane", 'kind: "send", lane: Number(token) - 1', 'kind: "send", lane: Number(token)', 2],
  [
    "a fourth lane key is accepted",
    'if (token === "1" || token === "2" || token === "3") return { kind: "send"',
    'if (token === "1" || token === "2" || token === "3" || token === "4") return { kind: "send"',
    2
  ],
  [
    "Enter saves instead of restoring",
    'if (token === "enter") return { kind: "restore" }',
    'if (token === "enter") return { kind: "save" }'
  ],
  ["any layout row can be saved by hand", 'token === "s" && row.kind === "mine"', 'token === "s"'],
  ["Esc ignores a pending restore", 'return ctx.armed ? { kind: "disarm" } : { kind: "close" }', 'return { kind: "close" }'],
  ["parentHeader can run past the end", "for (var i = Math.min(from, rows.length - 1); i >= 0; i--)", "for (var i = from; i >= 0; i--)"],
  ["the highlight can start on a header", 'if (rows[i].type === "widget") return i', 'if (rows[i].type !== "header") return i'],
  [
    "Omaseiton's own row offers Space off",
    'return row.isSelf ? "Omaseiton stays on the bar · 1 2 3 lane"',
    'return false ? "Omaseiton stays on the bar · 1 2 3 lane"'
  ],
  ["the pending-restore hint is empty", 'if (armed) return "Enter again to restore · Esc cancel"', 'if (armed) return ""'],
  ["the hint for My layout is wrong", 'return row.exists ? "Enter twice restore · s save" : "s save"', 'return "s save"']
]

// The same idea for the two shell scripts: [script, description, find, replace, count]
const shellMutants = [
  ["layout.sh", "five automatic snapshots become fifty", "KEEP_AUTO=5", "KEEP_AUTO=50"],
  ["layout.sh", "pruning keeps the oldest instead of the newest", "sort -r | tail -n +", "sort | tail -n +"],
  ["layout.sh", "any auto-* name is a valid slot", "auto-[0-9]{8}-[0-9]{6}(-[0-9]{1,9})?", "auto-.*"],
  [
    "layout.sh",
    "a snapshot also holds which bar plugin is active",
    "{position, transparent, centerAnchor, layout} | with_entries",
    "{id, position, transparent, centerAnchor, layout} | with_entries"
  ],
  ["layout.sh", "restore keeps the old position and anchor", "del(.position, .transparent, .centerAnchor, .layout)", "del(.layout)"],
  ["layout.sh", "restore skips the safety snapshot", 'snapshot "$snap" "$reason"', "true"],
  ["layout.sh", "restore forgets to keep Omaseiton on the bar", "| ensure(\\$id; \\$spot)", ""],
  ["layout.sh", "the file mode is not kept", 'chmod --reference="$real" "$new" 2>/dev/null || chmod 600 "$new"', 'chmod 600 "$new"'],
  ["layout.sh", "symlinks are replaced instead of followed", 'real=$(readlink -f "$CONFIG_FILE")', 'real="$CONFIG_FILE"', 2],
  ["layout.sh", "the stock bar is worked out in the real home", 'HOME="$tmp_home" omarchy bar defaults', "omarchy bar defaults"],
  ["layout.sh", "the reopen flag loses the monitor name", `printf '%s' "\${OMASEITON_REOPEN_SCREEN:-}"`, "printf ''"],
  [
    "layout.sh",
    "a restore that cannot apply keeps its snapshot",
    'rm -f "$tmp" "$LAYOUT_DIR/$snap.json"\n    fail "could not apply',
    'rm -f "$tmp"\n    fail "could not apply'
  ],
  [
    "layout.sh",
    "a restore that cannot write keeps its snapshot",
    '|| {\n    rm -f "$LAYOUT_DIR/$snap.json"\n    fail "cannot write next to',
    '|| {\n    fail "cannot write next to'
  ],
  ["layout.sh", "saving does not keep the version it replaces", "backup=$(auto_slot)", 'backup=""'],
  ["layout.sh", "snapshot names can repeat", "while [[ -e $LAYOUT_DIR/$slot.json ]]; do", "while false; do"],
  ["layout.sh", "a bad read is accepted as a snapshot", '! jq -e "$JQ_LAYOUT_OK" "$tmp"', "false"],
  ["update.sh", "the update applies whatever the remote has now", 'merge --ff-only --quiet "$sha"', "merge --ff-only --quiet FETCH_HEAD"],
  ["update.sh", "validation is skipped", "if ! omarchy-plugin-validate", "if false && ! omarchy-plugin-validate"],
  ["update.sh", "a failed validation is not rolled back", "reset --hard --quiet ORIG_HEAD", "status --short"],
  [
    "update.sh",
    "diverged copies are offered an update",
    'if ! git_safe -C "$dir" merge-base --is-ancestor HEAD "$sha"',
    'if false && ! git_safe -C "$dir" merge-base --is-ancestor HEAD "$sha"'
  ],
  [
    "update.sh",
    "copies with local commits are offered an update",
    'if git_safe -C "$dir" merge-base --is-ancestor "$sha" HEAD',
    'if false && git_safe -C "$dir" merge-base --is-ancestor "$sha" HEAD'
  ],
  ["update.sh", "local changes are not checked", "if [[ -n $(git_safe -C", "if false && [[ -n $(git_safe -C"],
  ["update.sh", "a plugin's fsmonitor setting is honoured", "-c core.fsmonitor= ", ""],
  ["update.sh", "a plugin's hooks are honoured", "-c core.hooksPath=/dev/null ", ""],
  ["update.sh", "the transport allowlist is removed", "GIT_ALLOW_PROTOCOL=https:ssh:git:file ", ""],
  [
    "update.sh",
    "ext:: is added to the transport allowlist",
    "GIT_ALLOW_PROTOCOL=https:ssh:git:file ",
    "GIT_ALLOW_PROTOCOL=https:ssh:git:file:ext "
  ],
  [
    "update.sh",
    "any helper transport is added to the allowlist",
    "GIT_ALLOW_PROTOCOL=https:ssh:git:file ",
    "GIT_ALLOW_PROTOCOL=https:ssh:git:file:zzz "
  ],
  ["update.sh", "symlinked plugins are swept", "[[ -L $dir ]] && continue", "true"],
  ["update.sh", "a rescan is not requested after an update", "omarchy-shell shell rescanPlugins", "true"],
  ["update.sh", "the user is not asked", 'if ! ask "Update $id to ${sha:0:9}?"; then', "if false; then"]
]

function runShell(script, testFile, envName, file) {
  return spawnSync("bash", [path.join(__dirname, testFile)], { env: { ...process.env, [envName]: file }, encoding: "utf8" })
}

let survived = 0
let total = 0

for (const [name, find, replace, expected] of mutants) {
  total++
  const occurrences = original.split(find).length - 1
  const want = expected || 1
  if (occurrences !== want) {
    console.error("BROKEN MUTANT (found " + occurrences + " times, expected " + want + "): " + name)
    process.exit(2)
  }
  const file = path.join(scratch, "Layout.mutant.js")
  fs.writeFileSync(file, original.split(find).join(replace))
  const result = spawnSync("node", [path.join(__dirname, "layout.test.js")], { env: { ...process.env, LAYOUT_JS: file }, encoding: "utf8" })
  if (result.status === 0) {
    survived++
    console.error("SURVIVED: Layout.js: " + name)
  }
}

for (const [script, name, find, replace, expected] of shellMutants) {
  total++
  const source = fs.readFileSync(path.join(root, "scripts", script), "utf8")
  const occurrences = source.split(find).length - 1
  const want = expected || 1
  if (occurrences !== want) {
    console.error("BROKEN MUTANT (found " + occurrences + " times, expected " + want + "): " + script + ": " + name)
    process.exit(2)
  }
  const file = path.join(scratch, script)
  fs.writeFileSync(file, source.split(find).join(replace))
  const result =
    script === "layout.sh"
      ? runShell(script, "layout-script.test.sh", "LAYOUT_SH", file)
      : runShell(script, "update-script.test.sh", "UPDATE_SH", file)
  if (result.status === 0) {
    survived++
    console.error("SURVIVED: " + script + ": " + name)
  }
}
fs.rmSync(scratch, { recursive: true, force: true })

if (checksum() !== canaryBefore) {
  console.error("CANARY: the real shell.json CHANGED during the mutation check. Something escaped the sandbox.")
  process.exit(3)
}

console.log("mutation check: " + (total - survived) + " of " + total + " mutants caught")
process.exit(survived === 0 ? 0 : 1)
