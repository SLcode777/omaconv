// Pure search helpers shared by Menu.qml and the Node test suite.
// Fields searched: title, cwd, prompts (PRD §7). Match is literal only,
// accent- and case-insensitive; multi-term queries are AND. No
// subsequence fuzzing: it surfaced rows no excerpt could explain
// (scattered-letter matches), against the PRD §7 rule.

var TitleWordStart = 120
var TitleSubstring = 100
var CwdSubstring = 60
var PromptSubstring = 40
var ExcerptBefore = 24
var ExcerptAfter = 56

function normalize(text) {
  if (!text) return ""
  return String(text).toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "")
}

function tokenize(query) {
  var out = []
  var parts = normalize(query).split(/\s+/)
  for (var i = 0; i < parts.length; i++)
    if (parts[i]) out.push(parts[i])
  return out
}

// Precompute normalized fields once per index load, not per keystroke.
function prepare(sessions) {
  var out = []
  for (var i = 0; i < (sessions || []).length; i++) {
    var s = sessions[i]
    if (!s || typeof s !== "object") continue
    var prompts = Array.isArray(s.prompts) ? s.prompts : []
    var normPrompts = []
    for (var j = 0; j < prompts.length; j++) normPrompts.push(normalize(prompts[j]))
    out.push({
      session: s,
      normTitle: normalize(s.title),
      normCwd: normalize(s.cwd),
      normPrompts: normPrompts
    })
  }
  return out
}

function wordStartsWith(haystack, needle, at) {
  return at === 0 || haystack[at - 1] === " " || haystack[at - 1] === "-" || haystack[at - 1] === "/"
}

// Best match of one term against one prepared session.
// Returns { score, prompt: {index, start, length} | null } or null.
function matchTerm(entry, term) {
  var at = entry.normTitle.indexOf(term)
  if (at !== -1)
    return { score: wordStartsWith(entry.normTitle, term, at) ? TitleWordStart : TitleSubstring, prompt: null }
  if (entry.normCwd.indexOf(term) !== -1)
    return { score: CwdSubstring, prompt: null }
  for (var i = 0; i < entry.normPrompts.length; i++) {
    var p = entry.normPrompts[i].indexOf(term)
    if (p !== -1)
      return { score: PromptSubstring, prompt: { index: i, start: p, length: term.length } }
  }
  return null
}

function collapseWhitespace(text) {
  return text.replace(/\s+/g, " ")
}

// Offsets come from the normalized string, which maps 1:1 onto the raw
// prompt (NFD marks are stripped in place); slice raw first, collapse
// whitespace per piece after, so newlines never shift the window. Clamp
// so a drifted offset degrades to a shifted excerpt, never a crash.
function buildExcerpt(prompt, start, length) {
  var text = String(prompt)
  var from = Math.max(0, Math.min(start, text.length))
  var to = Math.max(from, Math.min(start + length, text.length))
  var begin = Math.max(0, from - ExcerptBefore)
  var end = Math.min(text.length, to + ExcerptAfter)
  return {
    before: (begin > 0 ? "…" : "") + collapseWhitespace(text.slice(begin, from)),
    match: collapseWhitespace(text.slice(from, to)),
    after: collapseWhitespace(text.slice(to, end)) + (end < text.length ? "…" : "")
  }
}

var DAY_MS = 86400000

// Relative date section for a session, local calendar days (timestamps
// are UTC in the transcripts). THIS WEEK = the last 7 days.
function sectionFor(iso, nowMs) {
  var t = iso ? new Date(iso).getTime() : NaN
  if (isNaN(t)) return "OLDER"
  var now = new Date(nowMs)
  var startToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  if (t >= startToday) return "TODAY"
  if (t >= startToday - DAY_MS) return "YESTERDAY"
  if (t >= startToday - 6 * DAY_MS) return "THIS WEEK"
  return "OLDER"
}

// Empty-query view: pinned sessions first, then the `limit` most recent
// unpinned ones grouped by relative date. Header rows ({header: "..."})
// are rendered as section labels and skipped by selection.
function recentRows(prepared, pinnedIds, limit, nowMs) {
  var pinnedSet = {}
  for (var p = 0; p < (pinnedIds || []).length; p++) pinnedSet[pinnedIds[p]] = true
  var rows = []
  var pinned = []
  var recentCount = 0
  var lastSection = null
  var recentRowsOut = []
  for (var i = 0; i < prepared.length; i++) {
    var session = prepared[i].session
    if (pinnedSet[session.id]) {
      pinned.push({ session: session, score: 0, excerpt: null })
    } else if (recentCount < limit) {
      var section = sectionFor(session.lastActivity, nowMs)
      if (section !== lastSection) {
        recentRowsOut.push({ header: section })
        lastSection = section
      }
      recentRowsOut.push({ session: session, score: 0, excerpt: null })
      recentCount++
    }
  }
  if (pinned.length) rows.push({ header: "PINNED" })
  rows.push.apply(rows, pinned)
  rows.push.apply(rows, recentRowsOut)
  return rows
}

// AND across terms: every term must match; the first prompt hit feeds the
// excerpt. Null when any term misses.
function scoreEntry(entry, terms) {
  var total = 0
  var promptHit = null
  for (var t = 0; t < terms.length; t++) {
    var m = matchTerm(entry, terms[t])
    if (!m) return null
    total += m.score
    if (!promptHit && m.prompt) promptHit = m.prompt
  }
  return { score: total, prompt: promptHit }
}

// query "" → the `limit` most recent sessions (PRD F2).
// Otherwise: every term must match somewhere; score is the sum of the
// best field score per term; ties break on recency.
function search(prepared, query, limit) {
  var terms = tokenize(query)
  var out = []
  var i
  if (terms.length === 0) {
    for (i = 0; i < prepared.length && out.length < limit; i++)
      out.push({ session: prepared[i].session, score: 0, excerpt: null })
    return out
  }
  var scored = []
  for (i = 0; i < prepared.length; i++) {
    var entry = prepared[i]
    var hit = scoreEntry(entry, terms)
    if (!hit) continue
    var excerpt = hit.prompt
      ? buildExcerpt(entry.session.prompts[hit.prompt.index], hit.prompt.start, hit.prompt.length)
      : null
    scored.push({ session: entry.session, score: hit.score, excerpt: excerpt })
  }
  scored.sort(function(a, b) {
    if (b.score !== a.score) return b.score - a.score
    var la = a.session.lastActivity || ""
    var lb = b.session.lastActivity || ""
    return la < lb ? 1 : (la > lb ? -1 : 0)
  })
  return scored.slice(0, limit)
}

// Skills namespace: same literal matching over name + description.
function prepareSkills(skills) {
  var out = []
  for (var i = 0; i < (skills || []).length; i++) {
    var s = skills[i]
    if (!s || typeof s !== "object" || !s.name) continue
    out.push({ skill: s, normName: normalize(s.name), normDesc: normalize(s.description) })
  }
  return out
}

function searchSkills(prepared, query, limit) {
  var terms = tokenize(query)
  var scored = []
  for (var i = 0; i < prepared.length; i++) {
    var entry = prepared[i]
    var total = 0
    var dead = false
    for (var t = 0; t < terms.length; t++) {
      var term = terms[t]
      var at = entry.normName.indexOf(term)
      if (at !== -1) total += wordStartsWith(entry.normName, term, at) ? TitleWordStart : TitleSubstring
      else if (entry.normDesc.indexOf(term) !== -1) total += PromptSubstring
      else { dead = true; break }
    }
    if (dead) continue
    scored.push({ skill: entry.skill, score: total })
  }
  scored.sort(function(a, b) {
    if (b.score !== a.score) return b.score - a.score
    return a.skill.name < b.skill.name ? -1 : (a.skill.name > b.skill.name ? 1 : 0)
  })
  return scored.slice(0, limit)
}

// cwd and session id come from disk: quote them as data, single-quote
// POSIX style, so a hostile path cannot inject into the copied command
// (PRD §10).
function shellQuote(text) {
  return "'" + String(text).replace(/'/g, "'\\''") + "'"
}

function resumeCommand(cwd, id) {
  return "cd " + shellQuote(cwd) + " && claude --resume " + shellQuote(id)
}

function escapeStyled(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

// Excerpt → Qt StyledText markup with the match highlighted.
function excerptStyled(excerpt, highlightColor) {
  if (!excerpt) return ""
  return escapeStyled(excerpt.before)
    + "<b><font color=\"" + highlightColor + "\">" + escapeStyled(excerpt.match) + "</font></b>"
    + escapeStyled(excerpt.after)
}
