import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "SearchModel.js" as Search

// Omaconv — Claude Code conversation resume palette (PRD M2).
// The QML never reads the .jsonl transcripts: it displays the index that
// omaconv-index writes to ~/.local/state/omaconv/index.json (PRD §6).
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property int selectedIndex: 0
  property string filterText: ""
  property var sessions: []
  property var prepared: []
  property var preparedSkills: []
  property var results: []
  // "/" as first character switches the palette to the skills namespace.
  readonly property bool skillMode: filterText.indexOf("/") === 0

  readonly property string stateDir: {
    var xdg = Quickshell.env("XDG_STATE_HOME")
    var base = (xdg && xdg.length > 0) ? xdg : Quickshell.env("HOME") + "/.local/state"
    return base + "/omaconv"
  }
  // Helpers live next to this file; resolve them relative to the plugin dir.
  function pluginFile(name) {
    var url = Qt.resolvedUrl(name).toString()
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
  }
  readonly property string indexerPath: pluginFile("omaconv-index")
  readonly property string grepperPath: pluginFile("omaconv-grep")
  readonly property string titlerPath: pluginFile("omaconv-set-title")
  readonly property string resumerPath: pluginFile("omaconv-resume")
  readonly property string rendererPath: pluginFile("omaconv-render")

  // Delete confirmation modal: Ctrl+D stores the target here, ↵ (or
  // Ctrl+D again) confirms, esc cancels.
  property var confirmDeleteSession: null

  // UI preferences (pins): ours, stored in stateDir. Renames are NOT
  // here — they append to the transcript itself (see commitRename),
  // one of the two documented writes into ~/.claude (PRD §10).
  property var prefs: ({})

  // Rename mode (Ctrl+R): a small modal over the palette. Same idiom as
  // confirmDeleteSession — one nullable session object carries both the
  // open state and the target; only the typed text lives apart. The
  // rename is written into the transcript itself (custom-title +
  // agent-name lines, append-only) so Claude Code's own picker and
  // title chip follow.
  property var renameSession: null
  property string renameText: ""

  // Ctrl+K: shortcuts help modal.
  property bool helpActive: false

  function cancelModals() {
    root.renameSession = null
    root.helpActive = false
    root.confirmDeleteSession = null
  }

  // What each agent's CLI/store can support is greyed out, never silently
  // broken — the per-agent rationale lives in PRD §F9. Default = claude.
  readonly property var agentCapsTable: ({
    codex: { fork: false, rename: false, remove: true },
    opencode: { fork: true, rename: false, remove: false },
    antigravity: { fork: false, rename: false, remove: false },
    pi: { fork: true, rename: false, remove: true }
  })
  function agentCaps(agent) {
    return root.agentCapsTable[agent] || { fork: true, rename: true, remove: true }
  }

  // [menu] surface tokens, same idiom as omarchy.emojis: themes that style
  // the menu style this palette too.
  property color background: Color.menu.background
  property real cardOpacity: 0.92
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  // The theme's second hue: the "active" accent the bar uses (urgent by
  // default) — visibly distinct from selectedText in most themes.
  property color highlight: Color.bar.active
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  // Airy layout, design-inspo/raindrop: the palette takes ~2/3 of the
  // screen, wide margins, roomy rows.
  property int contentMargin: Style.space(28)
  // Preview (PRD F4): side pane when the screen is wide enough, otherwise
  // two extra lines under the selected row. The wide pane shows the last
  // turns of the conversation, rendered by omaconv-render --preview.
  readonly property bool widePreview: panel.width >= Style.space(1000)
  // Gutter between the list and the preview pane, hairline in the middle.
  readonly property int previewGap: Style.space(48)
  property int cardWidth: Math.min(
    Math.max(Style.space(680), Math.round(panel.width * (widePreview ? 0.72 : 0.55))),
    panel.width - Style.gapsOut * 2, Style.space(1320))
  property int cardHeight: Math.min(
    Math.max(Style.space(480), Math.round(panel.height * 0.68)),
    panel.height - Style.gapsOut * 2)

  readonly property var selectedSession: (root.results.length > 0
    && root.selectedIndex >= 0 && root.selectedIndex < root.results.length)
    ? (root.results[root.selectedIndex].session || null) : null
  readonly property var selectedSkill: (root.results.length > 0
    && root.selectedIndex >= 0 && root.selectedIndex < root.results.length)
    ? (root.results[root.selectedIndex].skill || null) : null
  readonly property string previewFirst: (selectedSession && Array.isArray(selectedSession.prompts)
    && selectedSession.prompts.length > 0) ? selectedSession.prompts[0] : ""
  readonly property string previewLast: (selectedSession && Array.isArray(selectedSession.prompts)
    && selectedSession.prompts.length > 1)
    ? selectedSession.prompts[selectedSession.prompts.length - 1] : ""

  // Wide-pane dialogue preview: last turns of the selected transcript,
  // fetched by a debounced omaconv-render --preview run. previewSessionId
  // tracks what the pane currently shows, so re-selecting the same row
  // (or an index reload) doesn't re-render.
  property var previewTurns: []
  property var previewSkillDoc: null
  property bool previewLoading: false
  property string previewSessionId: ""
  property string previewPendingId: ""

  onSelectedSessionChanged: root.requestPreview()
  onSelectedSkillChanged: root.requestPreview()

  // What the pane should show: the session id, or the skill's SKILL.md
  // path in the skills namespace. Empty → nothing previewable.
  function previewTargetId() {
    if (root.selectedSession) return root.selectedSession.transcriptPath ? root.selectedSession.id : ""
    return (root.selectedSkill && root.selectedSkill.path) ? root.selectedSkill.path : ""
  }

  function requestPreview() {
    var id = root.previewTargetId()
    if (!root.widePreview || !id) {
      previewTimer.stop()
      previewProc.running = false
      root.previewTurns = []
      root.previewSkillDoc = null
      root.previewSessionId = ""
      root.previewLoading = false
      return
    }
    if (id === root.previewSessionId) return
    previewProc.running = false
    root.previewTurns = []
    root.previewSkillDoc = null
    root.previewLoading = true
    previewTimer.restart()
  }

  function applyPreview(raw) {
    // A run killed by a newer selection can still flush its collector:
    // only the run matching the current selection may touch the pane.
    if (root.previewTargetId() !== root.previewPendingId) return
    root.previewLoading = false
    var parsed = null
    try { parsed = JSON.parse(raw) } catch (e) {
      console.warn("omaconv: unreadable preview:", e)
    }
    root.previewTurns = (parsed && Array.isArray(parsed.turns)) ? parsed.turns : []
    root.previewSkillDoc = (parsed && parsed.skill) ? parsed.skill : null
    root.previewSessionId = root.previewPendingId
    skillFlick.contentY = 0
  }

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.confirmDeleteSession = null
    root.opError = ""
    root.rebuild()
    // Freshness (PRD §6): show the cache instantly, reindex in the
    // background, let the FileView reload if anything changed.
    if (!reindex.running) reindex.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    // The shell destroys this instance on hide (no keepLoaded), but reset
    // the modals anyway so a future keepLoaded can't resurrect stale state.
    root.cancelModals()
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "slcode777.omaconv")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function loadIndex(raw) {
    var parsed = null
    try { parsed = JSON.parse(raw) } catch (e) {
      console.warn("omaconv: unreadable index:", e)
    }
    root.sessions = parsed && Array.isArray(parsed.sessions) ? parsed.sessions : []
    root.preparedSkills = Search.prepareSkills(
      parsed && Array.isArray(parsed.skills) ? parsed.skills : [])
    root.prepared = Search.prepare(root.sessions)
    root.rebuild()
  }

  // Empty query: pinned + the 10 most recent (PRD F2). Otherwise search
  // all three fields, capped at 50 rows. Leading "/": skills namespace.
  function rebuild() {
    var out
    if (root.skillMode)
      out = Search.searchSkills(root.preparedSkills, root.filterText.substring(1), 50)
    else if (root.filterText)
      out = Search.search(root.prepared, root.filterText, 50)
    else
      out = Search.recentRows(root.prepared, root.prefs.pinned || [], 10, Date.now())
    root.results = out
    if (root.selectedIndex >= out.length || root.selectedIndex < 0
        || (out[root.selectedIndex] && out[root.selectedIndex].header !== undefined))
      root.selectedIndex = root.firstSelectable()
  }

  function firstSelectable() {
    for (var i = 0; i < root.results.length; i++)
      if (root.results[i].header === undefined) return i
    return 0
  }

  function loadPrefs(raw) {
    var parsed = null
    try { parsed = JSON.parse(raw) } catch (e) { /* first run or corrupt: defaults */ }
    root.prefs = (parsed && typeof parsed === "object") ? parsed : {}
    root.rebuild()
  }

  function savePrefs() {
    prefsFile.setText(JSON.stringify(root.prefs))
  }

  function togglePin(index) {
    var s = root.sessionAt(index)
    if (!s) return
    var arr = (root.prefs.pinned || []).slice()
    var at = arr.indexOf(s.id)
    if (at === -1) arr.push(s.id)
    else arr.splice(at, 1)
    var next = {}
    for (var k in root.prefs) next[k] = root.prefs[k]
    next.pinned = arr
    root.prefs = next
    root.savePrefs()
    root.rebuild()
    // Keep the cursor on the same conversation after it moved section.
    for (var i = 0; i < root.results.length; i++) {
      if (root.results[i].session && root.results[i].session.id === s.id) {
        root.selectedIndex = i
        resultList.positionViewAtIndex(i, ListView.Contain)
        break
      }
    }
  }

  function startRename(index) {
    var s = root.sessionAt(index)
    if (!s || !s.transcriptPath || !root.agentCaps(s.agent).rename) return
    root.renameText = ""
    root.renameSession = s
  }

  // Empty input = cancel, never a silent reset.
  function commitRename() {
    var s = root.renameSession
    root.renameSession = null
    if (!s || !root.renameText.trim()) return
    root.enqueueOp(["python3", root.titlerPath, s.transcriptPath, root.renameText.trim()], "rename")
  }

  // Explicit reset: an empty title makes the auto title win again.
  function commitResetTitle() {
    var s = root.renameSession
    root.renameSession = null
    if (!s) return
    root.enqueueOp(["python3", root.titlerPath, s.transcriptPath, ""], "title reset")
  }

  function skillAt(index) {
    return (index >= 0 && index < root.results.length) ? (root.results[index].skill || null) : null
  }

  function openSkill(index) {
    var s = root.skillAt(index)
    if (!s || !s.path) return
    root.dismiss()
    Quickshell.execDetached(["setsid", "uwsm-app", "--", "omarchy-launch-editor", s.path])
  }

  function copySkillName(index) {
    var s = root.skillAt(index)
    if (!s) return
    Quickshell.execDetached(["wl-copy", "/" + s.name])
    root.dismiss()
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    root.rebuild()
  }

  function select(delta) {
    var n = root.results.length
    if (n === 0) return
    var i = root.selectedIndex
    for (var step = 0; step < n; step++) {
      i = (i + delta + n) % n
      if (root.results[i].header === undefined) {
        root.selectedIndex = i
        break
      }
    }
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function sessionAt(index) {
    return (index >= 0 && index < root.results.length) ? root.results[index].session : null
  }

  // Copy works even when the cwd folder is gone — it is the fallback the
  // PRD §9 prescribes for vanished directories. Only a missing cwd blocks it.
  function copyCommand(index) {
    var s = root.sessionAt(index)
    var cwd = s ? (s.resumeCwd || s.cwd) : null
    if (!cwd) return
    Quickshell.execDetached(["wl-copy", Search.resumeCommand(cwd, s.id, s.agent)])
    root.dismiss()
  }

  function openTerminal(index) {
    var s = root.sessionAt(index)
    if (!s || !s.resumeCwd) return
    root.dismiss()
    Quickshell.execDetached(["setsid", "uwsm-app", "--", "xdg-terminal-exec", "--dir=" + s.resumeCwd])
  }

  function revealTranscript(index) {
    var s = root.sessionAt(index)
    if (!s || !s.transcriptPath) return
    root.dismiss()
    Quickshell.execDetached(["setsid", "uwsm-app", "--", "nautilus", "--select", s.transcriptPath])
  }

  function grepTranscript(index) {
    var s = root.sessionAt(index)
    if (!s || !s.transcriptPath) return
    var pattern = root.filterText
    root.dismiss()
    Quickshell.execDetached([
      "setsid", "uwsm-app", "--", "xdg-terminal-exec",
      root.grepperPath, pattern, s.transcriptPath, s.agent || "claude", s.id
    ])
  }

  function requestDelete(index) {
    var s = root.sessionAt(index)
    // Never offer to trash a shared store (opencode's single db).
    if (s && root.agentCaps(s.agent).remove) root.confirmDeleteSession = s
  }

  function confirmDelete() {
    var s = root.confirmDeleteSession
    root.confirmDeleteSession = null
    if (!s || !s.transcriptPath) return
    // To the trash, never rm — recoverable. Only Claude keeps a sibling
    // <id>/ subdir (subagents); it may not exist, gio processes each
    // argument independently.
    var args = ["gio", "trash", s.transcriptPath]
    if ((s.agent || "claude") === "claude")
      args.push(s.transcriptPath.slice(0, -".jsonl".length))
    root.enqueueOp(args, "delete")
  }

  function resumeIndex(index, fork) {
    var s = root.sessionAt(index)
    if (!s) return
    // resumeCwd: the session's home dir, or the most recent surviving cwd
    // when the home is gone (shown with ↪). Null → nothing left (PRD §9).
    if (!s.resumeCwd) return
    // Agents without fork support resume normally instead.
    if (fork && !root.agentCaps(s.agent).fork) fork = false
    root.dismiss()
    // A session already running as a background agent refuses --resume:
    // open the attach picker instead (forking it is fine, though).
    if (s.running === "bg" && !fork) {
      Quickshell.execDetached([
        "setsid", "uwsm-app", "--",
        "xdg-terminal-exec", "--dir=" + s.resumeCwd,
        "claude", "agents"
      ])
      return
    }
    // Argument array, never an interpolated shell string: cwd and id come
    // from disk and are untrusted data (PRD §10). The wrapper keeps the
    // terminal open when claude exits with an error.
    var cmd = [
      "setsid", "uwsm-app", "--",
      "xdg-terminal-exec", root.resumerPath, s.resumeCwd, s.id,
      "--agent", s.agent || "claude"
    ]
    // Fork: inherit the context in a NEW session id, the original stays
    // untouched.
    if (fork) cmd.push("--fork")
    Quickshell.execDetached(cmd)
  }

  function homeAbbrev(path) {
    if (!path) return "?"
    var home = Quickshell.env("HOME")
    if (home && path.indexOf(home) === 0)
      return "~" + path.substring(home.length)
    return path
  }

  // Calendar days, same arithmetic as SearchModel.sectionFor — so
  // "yesterday" here always sits under the YESTERDAY section.
  function relativeDate(iso) {
    if (!iso) return ""
    var then = new Date(iso)
    if (isNaN(then.getTime())) return ""
    var now = new Date()
    var startToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    var startThen = new Date(then.getFullYear(), then.getMonth(), then.getDate()).getTime()
    var dayDiff = Math.round((startToday - startThen) / 86400000)
    if (dayDiff <= 0) {
      var mins = Math.floor((now.getTime() - then.getTime()) / 60000)
      if (mins < 1) return "now"
      if (mins < 60) return mins + " min ago"
      return Math.floor(mins / 60) + " h ago"
    }
    if (dayDiff === 1) return "yesterday"
    if (dayDiff < 30) return dayDiff + " days ago"
    var months = Math.floor(dayDiff / 30)
    return months + (months === 1 ? " month ago" : " months ago")
  }

  // Footer hints, clipse-style: accent-colored key, dim description,
  // "·" separators. Two explicit colors instead of Text.opacity, which
  // would dim the accent too.
  function dimColor() {
    var f = root.foreground
    var b = root.background
    return Qt.rgba(f.r * 0.55 + b.r * 0.45, f.g * 0.55 + b.g * 0.45, f.b * 0.55 + b.b * 0.45, 1)
  }

  function footerHints(pairs) {
    var accent = "" + root.selectedText
    var dim = "" + dimColor()
    var parts = []
    for (var i = 0; i < pairs.length; i++) {
      parts.push("<font color=\"" + accent + "\">" + pairs[i][0] + "</font>"
        + "<font color=\"" + dim + "\"> " + pairs[i][1] + "</font>")
    }
    return parts.join("<font color=\"" + ("" + root.highlight) + "\">  ·  </font>")
  }

  function dimText(text) {
    return "<font color=\"" + ("" + dimColor()) + "\">" + text + "</font>"
  }

  function escapeHtml(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  // Styled text: consumers must set textFormat: Text.StyledText.
  function subtitleFor(s) {
    // ↪ marks a fallback: the home dir is gone, resume lands elsewhere —
    // shown, never silent (PRD §5).
    var parts = [escapeHtml(s.cwdFallback ? "↪ " + homeAbbrev(s.resumeCwd) : homeAbbrev(s.cwd))]
    // Agent badge, only when it isn't the default agent — 100 rows of
    // "claude" would be noise.
    if (s.agent && s.agent !== "claude")
      parts.unshift("<font color=\"" + ("" + root.selectedText) + "\">" + escapeHtml(s.agent) + "</font>")
    if (s.running) parts.unshift("<font color=\"" + ("" + root.highlight) + "\">● live"
      + (s.running === "bg" ? " (bg)" : "") + "</font>")
    if (s.gitBranch) parts.push(escapeHtml(s.gitBranch))
    var when = relativeDate(s.lastActivity)
    if (when) parts.push(when)
    return parts.join("  ·  ")
  }

  Process {
    id: reindex
    command: ["python3", root.indexerPath, "--quiet"]
    onExited: indexFile.reload()
  }

  // Debounce so arrow-key travel doesn't spawn one render per row.
  Timer {
    id: previewTimer
    interval: 90
    repeat: false
    onTriggered: {
      var s = root.selectedSession
      var k = root.selectedSkill
      if (s && s.transcriptPath) {
        root.previewPendingId = s.id
        // --session is always passed; the renderer alone knows which
        // agents' stores are shared and actually need it.
        previewProc.command = ["python3", root.rendererPath, "--preview",
          "--agent", s.agent || "claude", "--session", s.id, s.transcriptPath]
      } else if (k && k.path) {
        root.previewPendingId = k.path
        previewProc.command = ["python3", root.rendererPath, "--skill", k.path]
      } else {
        return
      }
      previewProc.running = true
    }
  }

  Process {
    id: previewProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPreview(text)
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 && root.previewTargetId() === root.previewPendingId)
        root.previewLoading = false
    }
  }

  // Mutations (trash, rename) run sequentially through a small queue:
  // setting running=true on a live Process is a no-op, so back-to-back
  // operations would otherwise drop the second one on a slow filesystem.
  property var opQueue: []
  property string opCurrentLabel: ""
  // Last failed operation, shown in the footer until the next open/op.
  property string opError: ""

  function enqueueOp(cmd, label) {
    var next = root.opQueue.slice()
    next.push({ cmd: cmd, label: label })
    root.opQueue = next
    root.opError = ""
    root.pumpOps()
  }

  function pumpOps() {
    if (opRunner.running || root.opQueue.length === 0) return
    var next = root.opQueue.slice()
    var op = next.shift()
    root.opQueue = next
    root.opCurrentLabel = op.label
    opRunner.command = op.cmd
    opRunner.running = true
  }

  Process {
    id: opRunner
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        root.opError = root.opCurrentLabel + " failed (exit " + exitCode + ")"
        console.warn("omaconv:", root.opError, "—", JSON.stringify(command))
      }
      if (!reindex.running) reindex.running = true
      root.pumpOps()
    }
  }

  FileView {
    id: prefsFile
    path: root.stateDir + "/prefs.json"
    onLoaded: root.loadPrefs(text())
  }

  FileView {
    id: indexFile
    path: root.stateDir + "/index.json"
    watchChanges: true
    onLoaded: root.loadIndex(text())
    onFileChanged: reload()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omaconv"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: Qt.alpha(root.background, root.cardOpacity)
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          // Rename mode captures everything until save or cancel.
          if (root.renameSession) {
            if (event.key === Qt.Key_Escape) {
              root.renameSession = null
            } else if (event.key === Qt.Key_R && event.modifiers === Qt.ControlModifier) {
              root.commitResetTitle()
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.commitRename()
            } else if (Util.editsFilter(event, root.renameText)) {
              root.renameText = Util.editedFilter(event, root.renameText)
            } else if (event.text && event.text.length === 1
                && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
              root.renameText += event.text
            }
            event.accepted = true
            return
          }
          if (root.helpActive) {
            if (event.key === Qt.Key_Escape
                || (event.key === Qt.Key_K && event.modifiers === Qt.ControlModifier))
              root.helpActive = false
            event.accepted = true
            return
          }
          var isDeleteChord = event.key === Qt.Key_D && event.modifiers === Qt.ControlModifier
          // Delete guard BEFORE the Ctrl+K opener, so help can't stack on
          // top of an armed confirmation.
          if (root.confirmDeleteSession) {
            // The dialog owns esc/enter/tab; Ctrl+D again also confirms.
            if (!deleteDialog.handleKey(event) && isDeleteChord) root.confirmDelete()
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_K && event.modifiers === Qt.ControlModifier) {
            root.helpActive = true
            event.accepted = true
            return
          }
          if (isDeleteChord) {
            root.requestDelete(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.skillMode) {
              if (event.modifiers & Qt.ControlModifier) root.copySkillName(root.selectedIndex)
              else root.openSkill(root.selectedIndex)
            } else if (event.modifiers & Qt.ControlModifier) {
              root.copyCommand(root.selectedIndex)
            } else {
              root.resumeIndex(root.selectedIndex, (event.modifiers & Qt.AltModifier) !== 0)
            }
            event.accepted = true
          } else if (event.key === Qt.Key_O && event.modifiers === Qt.ControlModifier) {
            root.openTerminal(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_T && event.modifiers === Qt.ControlModifier) {
            root.revealTranscript(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_G && event.modifiers === Qt.ControlModifier) {
            root.grepTranscript(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_P && event.modifiers === Qt.ControlModifier) {
            root.togglePin(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_R && event.modifiers === Qt.ControlModifier) {
            root.startRename(root.selectedIndex)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // Search line + esc badge (design-inspo/hark, PRD §7 mock).
        Item {
          width: parent.width
          height: Math.max(Style.fontPx(1.5) + Style.space(8), escBadge.height)

          Text {
            anchors.left: parent.left
            anchors.right: escBadge.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.filterText || ("Search " + root.sessions.length + " conversations OR type \"/\" for skills…")
            color: root.foreground
            opacity: root.filterText ? 1 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.fontPx(1.5)
            elide: Text.ElideRight
          }

          Rectangle {
            id: escBadge
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: escText.width + Style.space(16)
            height: escText.height + Style.space(8)
            radius: Style.space(4)
            color: "transparent"
            border.color: root.foreground
            border.width: 1
            opacity: 0.35

            Text {
              id: escText
              anchors.centerIn: parent
              text: "esc"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        // Section label, small caps (design-inspo/raindrop, PRD §7 mock).
        // Empty query: sections come inline from recentRows() instead.
        Text {
          visible: root.skillMode || root.filterText !== ""
          width: parent.width
          text: root.skillMode ? "SKILLS" : "RESULTS"
          color: root.selectedText
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 2
        }

        Item {
          width: parent.width
          height: parent.height - y - footer.height - Style.spacing.md

          ListView {
            id: resultList
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            // Roughly 50/50 with the preview pane when it is visible.
            width: root.widePreview
              ? Math.round((parent.width - root.previewGap) * 0.5) : parent.width
            model: root.results
            clip: true
            spacing: Style.space(4)
            boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            id: row
            required property int index
            required property var modelData

            readonly property bool isHeader: modelData.header !== undefined
            readonly property bool isSkill: modelData.skill !== undefined
            readonly property var session: modelData.session || null
            readonly property bool current: !isHeader && index === root.selectedIndex
            readonly property bool resumable: isSkill || !!(session && session.resumeCwd)
            readonly property bool hasExcerpt: !isSkill && modelData.excerpt !== null && modelData.excerpt !== undefined
            // Narrow-screen preview: two extra lines under the selected row.
            readonly property bool inlinePreview: !isSkill && current && !root.widePreview

            width: resultList.width
            height: isHeader ? headerLabel.height + Style.space(18) : contentCol.height + Style.space(22)
            radius: root.cornerRadius
            color: current ? root.selectedBackground : "transparent"

            // Section label row (PINNED / RECENT): not selectable.
            Text {
              id: headerLabel
              visible: row.isHeader
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(4)
              text: row.isHeader ? modelData.header : ""
              color: root.selectedText
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 2
            }

            // Accent bar on the selected row (design-inspo).
            Rectangle {
              visible: row.current
              width: Math.max(2, Style.space(3))
              height: parent.height - Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: Style.space(4)
              radius: width / 2
              color: root.highlight
            }

            // Agent mark (assets/<agent>.svg), like every row is signed.
            Image {
              visible: !row.isHeader && !row.isSkill && row.session !== null
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(18)
              height: Style.space(18)
              source: row.session
                ? Qt.resolvedUrl("assets/" + (row.session.agent || "claude") + ".svg") : ""
              sourceSize: Qt.size(width, height)
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
            }

            Column {
              id: contentCol
              visible: !row.isHeader
              anchors.left: parent.left
              anchors.right: returnHint.left
              anchors.leftMargin: row.isSkill ? Style.space(18) : Style.space(46)
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              // PlainText wherever transcript-derived text lands: the
              // AutoText default renders it as rich text and Qt would
              // fetch any <img> URL it contains — network egress from
              // untrusted content. StyledText sinks escape instead.
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: row.isSkill ? "/" + row.modelData.skill.name
                  : (row.session ? (row.session.title || row.session.id) : "")
                color: row.current ? root.highlight : root.foreground
                opacity: row.resumable ? 1 : 0.4
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.StyledText
                text: row.isSkill
                  ? root.escapeHtml(root.homeAbbrev(row.modelData.skill.dir) + "  ·  " + (row.modelData.skill.description || "—"))
                  : (row.session ? root.subtitleFor(row.session) : "")
                color: row.current ? root.selectedText : root.foreground
                opacity: row.resumable ? 0.58 : 0.3
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              // Why this row matched: the prompt excerpt, term highlighted
              // (PRD §7 — without it the hit is unexplainable).
              Text {
                visible: row.hasExcerpt
                width: parent.width
                text: row.hasExcerpt
                  ? Search.excerptStyled(row.modelData.excerpt,
                      "" + (row.current ? root.selectedText : root.foreground))
                  : ""
                textFormat: Text.StyledText
                color: row.current ? root.selectedText : root.foreground
                opacity: row.resumable ? 0.75 : 0.3
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                visible: row.inlinePreview && root.previewFirst !== ""
                width: parent.width
                textFormat: Text.PlainText
                text: "› " + root.previewFirst
                color: root.selectedText
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.italic: true
                elide: Text.ElideRight
              }

              Text {
                visible: row.inlinePreview && root.previewLast !== ""
                width: parent.width
                textFormat: Text.PlainText
                text: "» " + root.previewLast
                color: root.selectedText
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.italic: true
                elide: Text.ElideRight
              }
            }

            Text {
              id: returnHint
              visible: row.current && row.resumable
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              text: "↵"
              color: root.selectedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            MouseArea {
              anchors.fill: parent
              enabled: !row.isHeader
              hoverEnabled: !row.isHeader
              cursorShape: row.resumable ? Qt.PointingHandCursor : Qt.ArrowCursor
              onContainsMouseChanged: if (containsMouse) root.selectedIndex = row.index
              onClicked: row.isSkill ? root.openSkill(row.index) : root.resumeIndex(row.index)
            }
          }

            Text {
              anchors.centerIn: parent
              visible: root.results.length === 0
              textFormat: Text.PlainText
              text: root.filterText
                ? "No matches for “" + root.filterText + "”"
                : "No conversations indexed yet"
              color: root.foreground
              opacity: 0.58
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }
          }

          // Vertical hairline in the middle of the gutter.
          Rectangle {
            visible: root.widePreview
            width: 1
            anchors.left: resultList.right
            anchors.leftMargin: Math.round(root.previewGap / 2)
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            color: root.foreground
            opacity: 0.12
          }

          // Side preview (PRD F4): a fixed header (title, metas, actions)
          // over the YOU/CLAUDE dialogue of the whole conversation.
          Item {
            visible: root.widePreview
            width: parent.width - resultList.width - root.previewGap
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom

            // Square bordered action button, esc-badge styling. The icon
            // is a Nerd Font glyph — the shell's monospace font ships them.
            component PaneButton: Rectangle {
              id: btn
              property string icon: ""
              property string label: ""
              signal activated()
              width: btnText.width + Style.space(20)
              height: btnText.height + Style.space(10)
              radius: 0
              color: btn.enabled && btnMouse.containsMouse
                ? root.selectedBackground : "transparent"
              border.color: btn.enabled && btnMouse.containsMouse
                ? root.highlight : root.foreground
              border.width: 1
              opacity: btn.enabled ? (btnMouse.containsMouse ? 0.95 : 0.55) : 0.25

              Text {
                id: btnText
                anchors.centerIn: parent
                text: (btn.icon ? btn.icon + " " : "") + btn.label
                color: btn.enabled && btnMouse.containsMouse
                  ? root.highlight : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              MouseArea {
                id: btnMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: btn.activated()
              }
            }

            Column {
              id: previewHeader
              visible: root.selectedSkill === null && root.selectedSession !== null
              height: visible ? implicitHeight : 0
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              spacing: Style.space(12)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.selectedSession
                  ? (root.selectedSession.title || root.selectedSession.id) : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.StyledText
                text: root.selectedSession ? root.subtitleFor(root.selectedSession) : ""
                color: root.foreground
                opacity: 0.58
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              // Every conversation action, mirrored from the shortcuts —
              // Flow wraps them onto extra lines when the pane is narrow.
              Flow {
                width: parent.width
                spacing: Style.spacing.sm

                PaneButton {
                  icon: ""
                  label: "RESUME"
                  enabled: !!(root.selectedSession && root.selectedSession.resumeCwd)
                  onActivated: root.resumeIndex(root.selectedIndex, false)
                }

                PaneButton {
                  icon: ""
                  label: "FORK"
                  enabled: !!(root.selectedSession && root.selectedSession.resumeCwd
                    && root.agentCaps(root.selectedSession.agent).fork)
                  onActivated: root.resumeIndex(root.selectedIndex, true)
                }

                PaneButton {
                  icon: ""
                  label: "COPY CMD"
                  enabled: !!(root.selectedSession
                    && (root.selectedSession.resumeCwd || root.selectedSession.cwd))
                  onActivated: root.copyCommand(root.selectedIndex)
                }

                PaneButton {
                  icon: ""
                  label: (root.selectedSession && (root.prefs.pinned || [])
                    .indexOf(root.selectedSession.id) !== -1) ? "UNPIN" : "PIN"
                  enabled: root.selectedSession !== null
                  onActivated: root.togglePin(root.selectedIndex)
                }

                PaneButton {
                  icon: ""
                  label: "RENAME"
                  enabled: !!(root.selectedSession && root.selectedSession.transcriptPath
                    && root.agentCaps(root.selectedSession.agent).rename)
                  onActivated: root.startRename(root.selectedIndex)
                }

                PaneButton {
                  icon: ""
                  label: "DELETE"
                  enabled: !!(root.selectedSession && root.selectedSession.transcriptPath
                    && root.agentCaps(root.selectedSession.agent).remove)
                  onActivated: root.requestDelete(root.selectedIndex)
                }
              }

              Rectangle {
                width: parent.width
                height: 1
                color: root.foreground
                opacity: 0.12
              }
            }

            // The whole dialogue, virtualized: only visible turns are
            // instantiated, so a 250-turn conversation costs nothing.
            ListView {
              id: previewList
              anchors.top: previewHeader.bottom
              anchors.topMargin: previewHeader.visible ? Style.spacing.md : 0
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              visible: root.selectedSkill === null
              clip: true
              // Style.spacing tokens are tiny (sm = 4px): a real breath
              // between two messages needs an explicit value.
              spacing: Style.space(24)
              model: root.previewTurns
              boundsBehavior: Flickable.StopAtBounds
              // Land on the most recent turn; scroll back up to the start.
              onCountChanged: if (count > 0)
                Qt.callLater(function() { previewList.positionViewAtEnd() })

              delegate: Column {
                required property var modelData
                width: previewList.width
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: (parent.modelData.who === "you" ? "YOU" : String(parent.modelData.who).toUpperCase())
                    + (parent.modelData.time ? "  ·  " + parent.modelData.time : "")
                  color: root.selectedText
                  opacity: 0.9
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.letterSpacing: 2
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: parent.modelData.text
                  color: root.foreground
                  opacity: 0.75
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  wrapMode: Text.Wrap
                }
              }
            }

            Text {
              anchors.centerIn: parent
              visible: root.selectedSkill === null && root.previewTurns.length === 0
              textFormat: Text.PlainText
              text: root.previewLoading ? "…"
                : (root.selectedSession ? "(nothing to preview)" : "")
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            // Skills namespace: same shape as the conversation preview —
            // fixed header (name, description, dir, actions), scrollable
            // SKILL.md below (frontmatter, then body).
            Column {
              id: skillHeader
              visible: root.selectedSkill !== null
              height: visible ? implicitHeight : 0
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              spacing: Style.space(12)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.selectedSkill ? "/" + root.selectedSkill.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: !!(root.selectedSkill && root.selectedSkill.description)
                textFormat: Text.PlainText
                text: root.selectedSkill ? (root.selectedSkill.description || "") : ""
                color: root.foreground
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.selectedSkill ? root.homeAbbrev(root.selectedSkill.dir) : ""
                color: root.foreground
                opacity: 0.58
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Flow {
                width: parent.width
                spacing: Style.spacing.sm

                PaneButton {
                  icon: ""
                  label: "OPEN"
                  enabled: !!(root.selectedSkill && root.selectedSkill.path)
                  onActivated: root.openSkill(root.selectedIndex)
                }

                PaneButton {
                  icon: ""
                  label: "COPY NAME"
                  enabled: root.selectedSkill !== null
                  onActivated: root.copySkillName(root.selectedIndex)
                }
              }

              Rectangle {
                width: parent.width
                height: 1
                color: root.foreground
                opacity: 0.12
              }
            }

            Flickable {
              id: skillFlick
              visible: root.selectedSkill !== null
              anchors.top: skillHeader.bottom
              anchors.topMargin: skillHeader.visible ? Style.spacing.md : 0
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              clip: true
              contentHeight: skillDoc.height
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: skillDoc
                width: skillFlick.width

                // The frontmatter is already distilled into the header
                // (name, description): only the body is worth reading.
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.previewSkillDoc ? (root.previewSkillDoc.body || "") : ""
                  color: root.foreground
                  opacity: 0.75
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  wrapMode: Text.Wrap
                }
              }
            }
          }
        }

        // Footer separated by a hairline (design-inspo/hark), shortcuts
        // spelled out — no cryptic caret notation.
        Column {
          id: footer
          width: parent.width
          spacing: Style.spacing.md

          Rectangle {
            width: parent.width
            height: 1
            color: root.foreground
            opacity: 0.12
          }

          Text {
            width: parent.width
            textFormat: Text.StyledText
            text: root.opError
              ? "⚠ " + root.opError
              : root.renameSession
              ? root.dimText("renaming…")
              : (root.skillMode
                ? root.footerHints([["↵", "open SKILL.md"], ["ctrl+↵", "copy /name"], ["esc", "back"]])
                : root.footerHints([["↵", "resume"], ["ctrl+↵", "copy command"], ["ctrl+k", "all shortcuts"], ["/", "skills"]]))
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            elide: Text.ElideRight
          }
        }
      }
    }

    // Mouse shield for the custom modals (the ConfirmDialog below ships
    // its own scrim): swallows hover and clicks that would otherwise
    // reach the rows behind; clicking outside cancels.
    MouseArea {
      visible: root.renameSession !== null || root.helpActive
      anchors.fill: parent
      hoverEnabled: true
      onClicked: root.cancelModals()
    }

    // Delete confirmation (Ctrl+D): local copy of the shell's dialog with
    // the palette's type scale — scrim, urgent-styled confirm button and
    // handleKey come built in.
    ConfirmBox {
      id: deleteDialog
      anchors.fill: parent
      opened: root.confirmDeleteSession !== null
      message: root.confirmDeleteSession
        ? "Delete “" + (root.confirmDeleteSession.title || root.confirmDeleteSession.id)
          + "”?\n\nThe transcript moves to the trash — recoverable from Files."
        : ""
      confirmText: "Delete"
      background: root.background
      foreground: root.foreground
      scrim: root.scrim
      selectedBackground: root.selectedBackground
      selectedText: root.selectedText
      fontFamily: root.fontFamily
      cornerRadius: root.cornerRadius
      onCanceled: root.confirmDeleteSession = null
      onConfirmed: root.confirmDelete()
    }

    // Shortcuts help modal (Ctrl+K).
    ModalSurface {
      visible: root.helpActive
      caption: "SHORTCUTS"
      color: root.background
      borderSpec: root.borderSpec
      foreground: root.foreground
      fontFamily: root.fontFamily

      Column {
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: [
            { key: "↵",       what: "resume in its directory" },
            { key: "alt+↵",   what: "resume as a fork (new session, same context)" },
            { key: "ctrl+↵",  what: "copy the resume command" },
            { key: "ctrl+p",  what: "pin / unpin" },
            { key: "ctrl+r",  what: "rename" },
            { key: "ctrl+o",  what: "open a terminal in its directory" },
            { key: "ctrl+t",  what: "reveal the transcript in Files" },
            { key: "ctrl+g",  what: "search inside the transcript" },
            { key: "ctrl+d",  what: "delete to trash (asks to confirm)" },
            { key: "/",       what: "skills namespace" },
            { key: "esc",     what: "clear search, then close" }
          ]

          Item {
            required property var modelData
            width: parent.width
            height: Style.font.title + Style.space(10)

            Text {
              width: Style.space(110)
              text: parent.modelData.key
              color: root.selectedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(120)
              anchors.right: parent.right
              text: parent.modelData.what
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              elide: Text.ElideRight
            }
          }
        }

        Text {
          width: parent.width
          textFormat: Text.StyledText
          text: root.footerHints([["esc", "close"]])
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }

    // Rename modal (Ctrl+R). Keys stay handled by keyCatcher.
    ModalSurface {
      visible: root.renameSession !== null
      caption: "RENAME CONVERSATION"
      color: root.background
      borderSpec: root.borderSpec
      foreground: root.foreground
      fontFamily: root.fontFamily

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.renameSession ? (root.renameSession.title || root.renameSession.id) : ""
        color: root.foreground
        opacity: 0.58
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        elide: Text.ElideRight
      }

      Rectangle {
        width: parent.width
        height: renameInput.height + Style.space(24)
        radius: Style.space(4)
        color: "transparent"
        border.color: root.foreground
        border.width: 1
        opacity: 0.9

        Text {
          id: renameInput
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.renameText ? root.renameText + "▏" : "New title…"
          color: root.foreground
          opacity: root.renameText ? 1 : 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.fontPx(1.5)
          elide: Text.ElideLeft
        }
      }

      Text {
        width: parent.width
        textFormat: Text.StyledText
        text: root.footerHints([["↵", "save"], ["ctrl+r", "reset auto title"], ["esc", "cancel"]])
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }
    }
  }
}
