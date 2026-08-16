#!/usr/bin/env node
// Unit tests for SearchModel.js (PRD M3), run with: node tests/search-model.test.js

// Pin the timezone so date-section tests behave the same on any machine,
// and so the DST test actually crosses a transition.
process.env.TZ = "Europe/Paris"

const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const source = fs.readFileSync(path.join(__dirname, "..", "SearchModel.js"), "utf8")
const model = {}
vm.createContext(model)
vm.runInContext(source, model, { filename: "SearchModel.js" })

function ids(out) {
  return Array.prototype.map.call(out, r => r.session.id).join(",")
}

function session(over) {
  return Object.assign({
    id: "s", title: "", cwd: "/home/lucy", cwds: [], prompts: [],
    lastActivity: "2026-08-01T00:00:00Z", cwdExists: true
  }, over)
}

let passed = 0
function test(name, fn) {
  fn()
  passed++
  console.log("ok - " + name)
}

test("normalize strips accents and case", () => {
  assert.equal(model.normalize("Créé à Zürich"), "cree a zurich")
})

test("empty query returns most recent up to limit", () => {
  const prepared = model.prepare([
    session({ id: "a" }), session({ id: "b" }), session({ id: "c" })
  ])
  const out = model.search(prepared, "  ", 2)
  assert.equal(ids(out), "a,b")
  assert.equal(out[0].excerpt, null)
})

test("title match outranks prompt match", () => {
  const prepared = model.prepare([
    session({ id: "viaPrompt", prompts: ["parlons de quattro ici"] }),
    session({ id: "viaTitle", title: "Migration Quattro" })
  ])
  const out = model.search(prepared, "quattro", 10)
  assert.equal(ids(out), "viaTitle,viaPrompt")
})

test("accent-insensitive both ways", () => {
  const prepared = model.prepare([session({ id: "a", title: "Créer un dépôt" })])
  assert.equal(model.search(prepared, "creer", 10).length, 1)
  assert.equal(model.search(prepared, "dépôt", 10).length, 1)
})

test("cwd matches and ranks between title and prompt", () => {
  const prepared = model.prepare([
    session({ id: "viaCwd", cwd: "/home/lucy/DEV/omaconv" }),
    session({ id: "viaPrompt", prompts: ["le plugin omaconv avance"] })
  ])
  const out = model.search(prepared, "omaconv", 10)
  assert.equal(ids(out), "viaCwd,viaPrompt")
})

test("multi-term is AND across fields", () => {
  const prepared = model.prepare([
    session({ id: "both", title: "Quattro", prompts: ["souci de plugin"] }),
    session({ id: "one", title: "Quattro seulement" })
  ])
  const out = model.search(prepared, "quattro plugin", 10)
  assert.equal(ids(out), "both")
})

test("no match eliminates the session", () => {
  const prepared = model.prepare([session({ id: "a", title: "autre chose" })])
  assert.equal(model.search(prepared, "zzz", 10).length, 0)
})

test("prompt hit produces an excerpt around the term", () => {
  const prepared = model.prepare([
    session({ id: "a", prompts: ["x", "il faudrait vérifier le validateur omarchy avant de pousser la version"] })
  ])
  const out = model.search(prepared, "validateur", 10)
  assert.equal(out.length, 1)
  assert.equal(out[0].excerpt.match, "validateur")
  assert.ok(out[0].excerpt.before.includes("vérifier"))
  assert.ok(out[0].excerpt.after.includes("omarchy"))
})

test("excerpt offsets survive newlines and accents before the match", () => {
  const prompt = "déjà vu :\n\n  les   accents\net les retours chariot décalent tout"
  const prepared = model.prepare([session({ id: "a", prompts: [prompt] })])
  const out = model.search(prepared, "chariot", 10)
  assert.equal(out[0].excerpt.match, "chariot")
})

test("excerpt is truncated with ellipses on long prompts", () => {
  const prompt = "a".repeat(100) + " cible " + "b".repeat(100)
  const prepared = model.prepare([session({ id: "a", prompts: [prompt] })])
  const e = model.search(prepared, "cible", 10)[0].excerpt
  assert.ok(e.before.startsWith("…"))
  assert.ok(e.after.endsWith("…"))
})

test("scattered-letter subsequences do not match (real false positive)", () => {
  const prepared = model.prepare([
    session({ id: "kando", title: "Commandes de screenshot et OCR pour Kando" })
  ])
  assert.equal(model.search(prepared, "omadoro", 10).length, 0)
})

test("equal scores tie-break on recency", () => {
  const prepared = model.prepare([
    session({ id: "old", title: "omarchy", lastActivity: "2026-01-01T00:00:00Z" }),
    session({ id: "new", title: "omarchy", lastActivity: "2026-08-01T00:00:00Z" })
  ])
  const out = model.search(prepared, "omarchy", 10)
  assert.equal(ids(out), "new,old")
})

test("word-start title match outranks mid-word match", () => {
  const prepared = model.prepare([
    session({ id: "mid", title: "chatons" }),
    session({ id: "start", title: "un ton posé" })
  ])
  const out = model.search(prepared, "ton", 10)
  assert.equal(ids(out), "start,mid")
})

test("styled excerpt escapes markup and highlights the match", () => {
  const styled = model.excerptStyled(
    { before: "a <b> ", match: "cible & co", after: " fin" }, "#ff0000")
  assert.ok(styled.includes("a &lt;b&gt; "))
  assert.ok(styled.includes("<font color=\"#ff0000\">cible &amp; co</font>"))
})

test("resume command quotes cwd and id as data", () => {
  assert.equal(
    model.resumeCommand("/home/lucy/mes projets", "abc-123"),
    "cd '/home/lucy/mes projets' && claude --resume 'abc-123'")
  assert.equal(
    model.resumeCommand("/tmp/l'atelier; rm -rf /", "id"),
    "cd '/tmp/l'\\''atelier; rm -rf /' && claude --resume 'id'")
})

test("resume command per agent", () => {
  assert.equal(
    model.resumeCommand("/tmp", "u1", "codex"),
    "cd '/tmp' && codex resume 'u1'")
  assert.equal(
    model.resumeCommand("/tmp", "ses_1", "opencode"),
    "cd '/tmp' && opencode --session 'ses_1'")
  assert.equal(
    model.resumeCommand("/tmp", "conv-1", "antigravity"),
    "cd '/tmp' && agy --conversation 'conv-1'")
  assert.equal(
    model.resumeCommand("/tmp", "uuid-1", "pi"),
    "cd '/tmp' && pi --session 'uuid-1'")
  assert.equal(
    model.resumeCommand("/tmp", "u1", "claude"),
    "cd '/tmp' && claude --resume 'u1'")
})

test("agent name is searchable as a prefix", () => {
  const prepared = model.prepare([
    { id: "a", agent: "codex", title: "fix login", cwd: "/tmp/x", prompts: [], lastActivity: "2026-08-16" },
    { id: "b", title: "codex is mentioned here", cwd: "/tmp/y", prompts: [], lastActivity: "2026-08-15" },
    { id: "c", title: "unrelated", cwd: "/tmp/z", prompts: ["something else"], lastActivity: "2026-08-14" }
  ])
  const hits = model.search(prepared, "codex", 10)
  assert.equal(hits.map(h => h.session.id).join(","), "b,a")
  const prefix = model.search(prepared, "cod", 10)
  assert.equal(prefix.map(h => h.session.id).join(","), "b,a")
})

test("skill search: name outranks description, empty query lists all", () => {
  const prepared = model.prepareSkills([
    { name: "omarchy", description: "desktop config", path: "/a" },
    { name: "sonar-check", description: "predict omarchy alerts", path: "/b" },
    null, { name: "" }
  ])
  const all = model.searchSkills(prepared, "", 10)
  assert.equal(all.length, 2)
  const out = model.searchSkills(prepared, "omarchy", 10)
  assert.equal(Array.prototype.map.call(out, r => r.skill.name).join(","), "omarchy,sonar-check")
})

// Fixed "now": 2026-08-15 15:00 local time.
const NOW = new Date(2026, 7, 15, 15, 0, 0).getTime()

function atLocal(y, mo, d, h) {
  return new Date(y, mo, d, h, 0, 0).toISOString()
}

test("sectionFor buckets by local calendar day", () => {
  assert.equal(model.sectionFor(atLocal(2026, 7, 15, 9), NOW), "TODAY")
  assert.equal(model.sectionFor(atLocal(2026, 7, 14, 23), NOW), "YESTERDAY")
  assert.equal(model.sectionFor(atLocal(2026, 7, 10, 12), NOW), "THIS WEEK")
  assert.equal(model.sectionFor(atLocal(2026, 7, 1, 12), NOW), "OLDER")
  assert.equal(model.sectionFor(null, NOW), "OLDER")
  assert.equal(model.sectionFor("garbage", NOW), "OLDER")
})

test("sectionFor survives the fall-back DST transition", () => {
  // Paris, Mon 2026-10-26: the clocks went back on Sunday (25h day).
  // A Sunday 00:30 session must land in YESTERDAY, not THIS WEEK.
  const monday = new Date(2026, 9, 26, 15, 0, 0).getTime()
  assert.equal(model.sectionFor(atLocal(2026, 9, 25, 0.5), monday), "YESTERDAY")
  assert.equal(model.sectionFor(atLocal(2026, 9, 26, 9), monday), "TODAY")
})

test("recentRows: pinned first, then date sections, limit caps recents", () => {
  const prepared = model.prepare([
    session({ id: "today1", lastActivity: atLocal(2026, 7, 15, 12) }),
    session({ id: "today2", lastActivity: atLocal(2026, 7, 15, 8) }),
    session({ id: "yday", lastActivity: atLocal(2026, 7, 14, 12) }),
    session({ id: "week", lastActivity: atLocal(2026, 7, 11, 12) }),
    session({ id: "old", lastActivity: atLocal(2026, 6, 1, 12) }),
    session({ id: "pinned1", lastActivity: atLocal(2026, 7, 13, 12) })
  ])
  const rows = model.recentRows(prepared, ["pinned1"], 4, NOW)
  const shape = Array.prototype.map.call(rows, r => r.header || r.session.id).join(",")
  assert.equal(shape, "PINNED,pinned1,TODAY,today1,today2,YESTERDAY,yday,THIS WEEK,week")
})

test("recentRows: empty input yields no rows", () => {
  assert.equal(model.recentRows(model.prepare([]), null, 10, NOW).length, 0)
})

test("prepare tolerates malformed sessions", () => {
  const prepared = model.prepare([null, "junk", session({ id: "ok", prompts: null, title: null, cwd: null })])
  assert.equal(prepared.length, 1)
  assert.equal(model.search(prepared, "", 10).length, 1)
})

console.log(passed + " tests passed")
