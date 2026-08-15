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
  property var results: []

  readonly property string stateDir: {
    var xdg = Quickshell.env("XDG_STATE_HOME")
    var base = (xdg && xdg.length > 0) ? xdg : Quickshell.env("HOME") + "/.local/state"
    return base + "/omaconv"
  }
  // The indexer lives next to this file; resolve it relative to the plugin dir.
  readonly property string indexerPath: {
    var url = Qt.resolvedUrl("omaconv-index").toString()
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
  }

  // [menu] surface tokens, same idiom as omarchy.emojis: themes that style
  // the menu style this palette too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int rowHeight: Style.space(44)
  // Preview (PRD F4): side pane when the screen is wide enough, otherwise
  // two extra lines under the selected row.
  readonly property bool widePreview: panel.width >= Style.space(1000)
  property int previewWidth: Style.space(300)
  property int cardWidth: Math.min(widePreview ? Style.space(900) : Style.space(560), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(520), panel.height - Style.gapsOut * 2)

  readonly property var selectedSession: (root.results.length > 0
    && root.selectedIndex >= 0 && root.selectedIndex < root.results.length)
    ? root.results[root.selectedIndex].session : null
  readonly property string previewFirst: (selectedSession && Array.isArray(selectedSession.prompts)
    && selectedSession.prompts.length > 0) ? selectedSession.prompts[0] : ""
  readonly property string previewLast: (selectedSession && Array.isArray(selectedSession.prompts)
    && selectedSession.prompts.length > 1)
    ? selectedSession.prompts[selectedSession.prompts.length - 1] : ""

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
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
    var list = parsed && Array.isArray(parsed.sessions) ? parsed.sessions : []
    root.sessions = list
    root.prepared = Search.prepare(list)
    root.rebuild()
  }

  // Empty query: the 10 most recent (PRD F2). Otherwise search all three
  // fields, capped at 50 rows.
  function rebuild() {
    var out = Search.search(root.prepared, root.filterText, root.filterText ? 50 : 10)
    root.results = out
    if (root.selectedIndex >= out.length) root.selectedIndex = Math.max(0, out.length - 1)
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    root.rebuild()
  }

  function select(delta) {
    if (root.results.length === 0) return
    root.selectedIndex = (root.selectedIndex + delta + root.results.length) % root.results.length
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function sessionAt(index) {
    return (index >= 0 && index < root.results.length) ? root.results[index].session : null
  }

  // Copy works even when the cwd folder is gone — it is the fallback the
  // PRD §9 prescribes for vanished directories. Only a missing cwd blocks it.
  function copyCommand(index) {
    var s = root.sessionAt(index)
    if (!s || !s.cwd) return
    Quickshell.execDetached(["wl-copy", Search.resumeCommand(s.cwd, s.id)])
    root.dismiss()
  }

  function openInEditor(index) {
    var s = root.sessionAt(index)
    if (!s || s.cwdExists !== true) return
    root.dismiss()
    Quickshell.execDetached(["setsid", "uwsm-app", "--", "omarchy-launch-editor", s.cwd])
  }

  function revealTranscript(index) {
    var s = root.sessionAt(index)
    if (!s || !s.transcriptPath) return
    root.dismiss()
    var dir = s.transcriptPath.substring(0, s.transcriptPath.lastIndexOf("/"))
    Quickshell.execDetached(["setsid", "uwsm-app", "--", "nautilus", "--new-window", dir])
  }

  function resumeIndex(index) {
    var s = root.sessionAt(index)
    if (!s) return
    // A session whose cwd is gone cannot be resumed in place (PRD §9).
    if (!s.cwdExists || !s.cwd) return
    root.dismiss()
    // Argument array, never an interpolated shell string: cwd and id come
    // from disk and are untrusted data (PRD §10).
    Quickshell.execDetached([
      "setsid", "uwsm-app", "--",
      "xdg-terminal-exec", "--dir=" + s.cwd,
      "claude", "--resume", s.id
    ])
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

  function subtitleFor(s) {
    var parts = [homeAbbrev(s.cwd)]
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
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
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
            if (event.modifiers & Qt.ControlModifier) root.copyCommand(root.selectedIndex)
            else root.resumeIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_O && event.modifiers === Qt.ControlModifier) {
            root.openInEditor(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_T && event.modifiers === Qt.ControlModifier) {
            root.revealTranscript(root.selectedIndex)
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

        Text {
          width: parent.width
          text: root.filterText || ("Search " + root.sessions.length + " conversations…")
          color: root.foreground
          opacity: root.filterText ? 1 : 0.58
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          elide: Text.ElideRight
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
            boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            id: row
            required property int index
            required property var modelData

            readonly property var session: modelData.session
            readonly property bool current: index === root.selectedIndex
            readonly property bool resumable: session.cwdExists === true
            readonly property bool hasExcerpt: modelData.excerpt !== null && modelData.excerpt !== undefined
            // Narrow-screen preview: two extra lines under the selected row.
            readonly property bool inlinePreview: current && !root.widePreview

            width: resultList.width
            height: contentCol.height + Style.space(14)
            radius: root.cornerRadius
            color: current ? root.selectedBackground : "transparent"

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
              anchors.left: parent.left
              anchors.right: returnHint.left
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: row.session.title || row.session.id
                color: row.current ? root.selectedText : root.foreground
                opacity: row.resumable ? 1 : 0.4
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.subtitleFor(row.session)
                color: row.current ? root.selectedText : root.foreground
                opacity: row.resumable ? 0.58 : 0.3
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
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
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                visible: row.inlinePreview && root.previewFirst !== ""
                width: parent.width
                text: "› " + root.previewFirst
                color: root.selectedText
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
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
                font.pixelSize: Style.font.bodySmall
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
              font.pixelSize: Style.font.title
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: row.resumable ? Qt.PointingHandCursor : Qt.ArrowCursor
              onContainsMouseChanged: if (containsMouse) root.selectedIndex = row.index
              onClicked: root.resumeIndex(row.index)
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
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.previewFirst !== ""
              text: root.previewFirst
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
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
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.previewLast !== ""
              text: root.previewLast
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
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
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        Text {
          id: footer
          width: parent.width
          text: "↵ resume · ^↵ copy cmd · ^o editor · ^t transcript · esc close"
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }
}
