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

  // Delete confirmation modal: Ctrl+D stores the target here, ↵ (or
  // Ctrl+D again) confirms, esc cancels.
  property var confirmDeleteSession: null

  // UI preferences (pins, renames): ours, stored in stateDir — Claude's
  // transcript files are never written to.
  property var prefs: ({})

  // Rename mode (Ctrl+R): a small modal over the palette. The rename is
  // written into the transcript itself (custom-title + agent-name lines,
  // append-only) so Claude Code's own picker and title chip follow.
  property bool renameActive: false
  property string renameText: ""
  property string renameTargetPath: ""
  property string renameCurrentTitle: ""

  // Ctrl+K: shortcuts help modal.
  property bool helpActive: false

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
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  // Airy layout, design-inspo/raindrop: the palette takes ~2/3 of the
  // screen, wide margins, roomy rows.
  property int contentMargin: Style.space(28)
  // Preview (PRD F4): side pane when the screen is wide enough, otherwise
  // two extra lines under the selected row.
  readonly property bool widePreview: panel.width >= Style.space(1000)
  property int previewWidth: Style.space(340)
  property int cardWidth: Math.min(
    Math.max(Style.space(680), Math.round(panel.width * (widePreview ? 0.66 : 0.55))),
    panel.width - Style.gapsOut * 2, Style.space(1180))
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

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.confirmDeleteSession = null
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
    if (!s || !s.transcriptPath) return
    root.renameTargetPath = s.transcriptPath
    root.renameCurrentTitle = s.title || ""
    root.renameText = ""
    root.renameActive = true
  }

  // Empty input = cancel, never a silent reset.
  function commitRename() {
    root.renameActive = false
    if (!root.renameTargetPath || !root.renameText.trim()) return
    titler.command = ["python3", root.titlerPath, root.renameTargetPath, root.renameText.trim()]
    titler.running = true
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
    Quickshell.execDetached(["wl-copy", Search.resumeCommand(cwd, s.id)])
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
      root.grepperPath, pattern, s.transcriptPath
    ])
  }

  function requestDelete(index) {
    var s = root.sessionAt(index)
    if (s) root.confirmDeleteSession = s
  }

  function confirmDelete() {
    var s = root.confirmDeleteSession
    root.confirmDeleteSession = null
    if (!s || !s.transcriptPath) return
    // To the trash, never rm — recoverable. The session subdir (subagents)
    // may not exist; gio processes each argument independently.
    trasher.command = ["gio", "trash",
      s.transcriptPath,
      s.transcriptPath.slice(0, -".jsonl".length)]
    trasher.running = true
  }

  function resumeIndex(index, fork) {
    var s = root.sessionAt(index)
    if (!s) return
    // resumeCwd: the session's home dir, or the most recent surviving cwd
    // when the home is gone (shown with ↪). Null → nothing left (PRD §9).
    if (!s.resumeCwd) return
    root.dismiss()
    // Argument array, never an interpolated shell string: cwd and id come
    // from disk and are untrusted data (PRD §10).
    var cmd = [
      "setsid", "uwsm-app", "--",
      "xdg-terminal-exec", "--dir=" + s.resumeCwd,
      "claude", "--resume", s.id
    ]
    // Fork: inherit the context in a NEW session id, the original stays
    // untouched.
    if (fork) cmd.push("--fork-session")
    Quickshell.execDetached(cmd)
  }

  function homeAbbrev(path) {
    if (!path) return "?"
    var home = Quickshell.env("HOME")
    if (home && path.indexOf(home) === 0)
      return "~" + path.substring(home.length)
    return path
  }

  function relativeDate(iso) {
    if (!iso) return ""
    var then = new Date(iso)
    if (isNaN(then.getTime())) return ""
    var mins = Math.floor((Date.now() - then.getTime()) / 60000)
    if (mins < 1) return "now"
    if (mins < 60) return mins + " min ago"
    var hours = Math.floor(mins / 60)
    if (hours < 24) return hours + " h ago"
    var days = Math.floor(hours / 24)
    if (days === 1) return "yesterday"
    if (days < 30) return days + " days ago"
    var months = Math.floor(days / 30)
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
    return parts.join("<font color=\"" + dim + "\">  ·  </font>")
  }

  function dimText(text) {
    return "<font color=\"" + ("" + dimColor()) + "\">" + text + "</font>"
  }

  function subtitleFor(s) {
    // ↪ marks a fallback: the home dir is gone, resume lands elsewhere —
    // shown, never silent (PRD §5).
    var parts = [s.cwdFallback ? "↪ " + homeAbbrev(s.resumeCwd) : homeAbbrev(s.cwd)]
    if (s.gitBranch) parts.push(s.gitBranch)
    var when = relativeDate(s.lastActivity)
    if (when) parts.push(when)
    return parts.join("  ·  ")
  }

  Process {
    id: reindex
    command: ["python3", root.indexerPath, "--quiet"]
    onExited: indexFile.reload()
  }

  Process {
    id: trasher
    onExited: if (!reindex.running) reindex.running = true
  }

  Process {
    id: titler
    onExited: if (!reindex.running) reindex.running = true
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
          if (root.renameActive) {
            if (event.key === Qt.Key_Escape) {
              root.renameActive = false
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
          if (event.key === Qt.Key_K && event.modifiers === Qt.ControlModifier) {
            root.helpActive = true
            event.accepted = true
            return
          }
          var isDeleteChord = event.key === Qt.Key_D && event.modifiers === Qt.ControlModifier
          if (root.confirmDeleteSession) {
            if (event.key === Qt.Key_Escape) root.confirmDeleteSession = null
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || isDeleteChord)
              root.confirmDelete()
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
          color: root.foreground
          opacity: 0.4
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
            width: root.widePreview ? parent.width - root.previewWidth - Style.spacing.lg : parent.width
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
              color: root.foreground
              opacity: 0.4
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
              color: root.selectedText
            }

            Column {
              id: contentCol
              visible: !row.isHeader
              anchors.left: parent.left
              anchors.right: returnHint.left
              anchors.leftMargin: Style.space(18)
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                width: parent.width
                text: row.isSkill ? "/" + row.modelData.skill.name
                  : (row.session ? (row.session.title || row.session.id) : "")
                color: row.current ? root.selectedText : root.foreground
                opacity: row.resumable ? 1 : 0.4
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: row.isSkill
                  ? root.homeAbbrev(row.modelData.skill.dir) + "  ·  " + (row.modelData.skill.description || "—")
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
              text: root.filterText
                ? "No matches for “" + root.filterText + "”"
                : "No conversations indexed yet"
              color: root.foreground
              opacity: 0.58
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }
          }

          // Side preview (PRD F4): first prompt + latest prompt of the
          // selection — enough to recognize a conversation without any LLM.
          Column {
            visible: root.widePreview
            width: root.previewWidth
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Style.spacing.sm

            Text {
              width: parent.width
              visible: root.previewFirst !== ""
              text: "FIRST PROMPT"
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 2
            }

            Text {
              width: parent.width
              visible: root.previewFirst !== ""
              text: root.previewFirst
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
              maximumLineCount: 9
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              visible: root.previewLast !== ""
              text: "LAST PROMPT"
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 2
            }

            Text {
              width: parent.width
              visible: root.previewLast !== ""
              text: root.previewLast
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
              maximumLineCount: 7
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              visible: root.selectedSession !== null && root.previewFirst === ""
              text: "(no prompts recorded)"
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              width: parent.width
              visible: root.selectedSkill !== null
              text: "LOCATION"
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 2
            }

            Text {
              width: parent.width
              visible: root.selectedSkill !== null
              text: root.selectedSkill ? root.homeAbbrev(root.selectedSkill.dir) : ""
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WrapAnywhere
              maximumLineCount: 2
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              visible: root.selectedSkill !== null
              text: "DESCRIPTION"
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 2
            }

            Text {
              width: parent.width
              visible: root.selectedSkill !== null
              text: root.selectedSkill ? (root.selectedSkill.description || "—") : ""
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
              maximumLineCount: 16
              elide: Text.ElideRight
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
            text: root.renameActive
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

    // Delete confirmation modal (Ctrl+D).
    BorderSurface {
      visible: root.confirmDeleteSession !== null
      width: Math.min(Style.space(720), panel.width - Style.gapsOut * 2)
      height: deleteCol.height + Style.space(64)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.space(24)

      Column {
        id: deleteCol
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(32)
        anchors.rightMargin: Style.space(32)
        spacing: Style.spacing.lg

        Text {
          width: parent.width
          text: "DELETE CONVERSATION — ARE YOU SURE?"
          color: root.foreground
          opacity: 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.letterSpacing: 2
        }

        Text {
          width: parent.width
          text: root.confirmDeleteSession ? (root.confirmDeleteSession.title || root.confirmDeleteSession.id) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.fontPx(1.5)
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: root.confirmDeleteSession ? root.subtitleFor(root.confirmDeleteSession) : ""
          color: root.foreground
          opacity: 0.58
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: "The transcript moves to the trash — recoverable from Files."
          color: root.foreground
          opacity: 0.75
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          wrapMode: Text.Wrap
        }

        Text {
          width: parent.width
          textFormat: Text.StyledText
          text: root.footerHints([["↵", "delete"], ["esc", "cancel"]])
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }
      }
    }

    // Shortcuts help modal (Ctrl+K).
    BorderSurface {
      visible: root.helpActive
      width: Math.min(Style.space(640), panel.width - Style.gapsOut * 2)
      height: helpCol.height + Style.space(64)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.space(24)

      Column {
        id: helpCol
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(32)
        anchors.rightMargin: Style.space(32)
        spacing: Style.spacing.md

        Text {
          width: parent.width
          text: "SHORTCUTS"
          color: root.foreground
          opacity: 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.letterSpacing: 2
        }

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
            width: helpCol.width
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

    // Rename modal, on top of the card. Keys stay handled by keyCatcher.
    BorderSurface {
      visible: root.renameActive
      width: Math.min(Style.space(720), panel.width - Style.gapsOut * 2)
      height: renameCol.height + Style.space(64)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.space(24)

      Column {
        id: renameCol
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(32)
        anchors.rightMargin: Style.space(32)
        spacing: Style.spacing.lg

        Text {
          width: parent.width
          text: "RENAME CONVERSATION"
          color: root.foreground
          opacity: 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.letterSpacing: 2
        }

        Text {
          width: parent.width
          text: root.renameCurrentTitle
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
          text: root.footerHints([["↵", "save"], ["esc", "cancel"]])
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }
      }
    }
  }
}
