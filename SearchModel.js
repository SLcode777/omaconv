// Pure search helpers shared by Menu.qml and the Node test suite.
// Fields searched: title, cwd, prompts (PRD §7). Match is literal,
// accent- and case-insensitive; a light subsequence fallback on the
// title catches typo-ish queries. Multi-term queries are AND.

var TitleWordStart = 120
var TitleSubstring = 100
var CwdSubstring = 60
var PromptSubstring = 40
var TitleSubsequence = 25
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

function isSubsequence(needle, haystack) {
  var h = 0
  for (var n = 0; n < needle.length; n++) {
    h = haystack.indexOf(needle[n], h)
    if (h === -1) return false
    h++
  }
  return true
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
  if (term.length >= 3 && isSubsequence(term, entry.normTitle))
    return { score: TitleSubsequence, prompt: null }
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
    var total = 0
    var promptHit = null
    var dead = false
    for (var t = 0; t < terms.length; t++) {
      var m = matchTerm(entry, terms[t])
      if (!m) { dead = true; break }
      total += m.score
      if (!promptHit && m.prompt) promptHit = m.prompt
    }
    if (dead) continue
    var excerpt = promptHit
      ? buildExcerpt(entry.session.prompts[promptHit.index], promptHit.start, promptHit.length)
      : null
    scored.push({ session: entry.session, score: total, excerpt: excerpt })
  }
  scored.sort(function(a, b) {
    if (b.score !== a.score) return b.score - a.score
    var la = a.session.lastActivity || ""
    var lb = b.session.lastActivity || ""
    return la < lb ? 1 : (la > lb ? -1 : 0)
  })
  return scored.slice(0, limit)
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
