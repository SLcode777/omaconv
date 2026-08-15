#!/usr/bin/env node
// Unit tests for SearchModel.js (PRD M3), run with: node tests/search-model.test.js

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

test("recentRows: pinned first with headers, limit only caps recents", () => {
  const prepared = model.prepare([
    session({ id: "a" }), session({ id: "b" }), session({ id: "c" }), session({ id: "d" })
  ])
  const rows = model.recentRows(prepared, ["c"], 2)
  const shape = Array.prototype.map.call(rows, r => r.header || r.session.id).join(",")
  assert.equal(shape, "PINNED,c,RECENT,a,b")
})

test("recentRows: no pins means a single RECENT section", () => {
  const prepared = model.prepare([session({ id: "a" })])
  const rows = model.recentRows(prepared, [], 10)
  assert.equal(Array.prototype.map.call(rows, r => r.header || r.session.id).join(","), "RECENT,a")
  assert.equal(model.recentRows(model.prepare([]), null, 10).length, 0)
})

test("prepare tolerates malformed sessions", () => {
  const prepared = model.prepare([null, "junk", session({ id: "ok", prompts: null, title: null, cwd: null })])
  assert.equal(prepared.length, 1)
  assert.equal(model.search(prepared, "", 10).length, 1)
})

console.log(passed + " tests passed")
