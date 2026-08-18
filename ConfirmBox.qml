import QtQuick
import qs.Commons
import qs.Ui

// Confirmation dialog derived from the omarchy shell's Ui/ConfirmDialog.qml
// (same behavior: own scrim, click-blocking, handleKey), with the palette's
// larger type scale — the stock component hardcodes caption-size buttons.
Item {
  id: root

  property bool opened: false
  property string message: ""
  property string cancelText: "Cancel"
  property string confirmText: "Confirm"
  property int selectedIndex: 1
  property color background: Color.background
  property color foreground: Color.foreground
  property color scrim: Util.alpha(Color.background, 0.7)
  property color selectedBackground: Util.alpha(Color.foreground, 0.08)
  property color selectedText: Color.accent
  property string fontFamily: Style.font.family
  property int cornerRadius: Style.cornerRadius

  signal canceled()
  signal confirmed()

  function handleKey(event) {
    if (!root.opened) return false

    if (event.key === Qt.Key_Escape) {
      root.canceled()
      return true
    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      root.selectedIndex = root.selectedIndex === 0 ? 1 : 0
      return true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (root.selectedIndex === 0) root.canceled()
      else root.confirmed()
      return true
    }

    return false
  }

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: root.scrim

    MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(32), Style.space(460))
      height: card.contentTopInset + card.contentBottomInset + messageText.implicitHeight + Style.space(24) + Style.space(42)
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.selectedText, Style.normalBorderWidth)
      padding: Style.space(24)
      radius: root.cornerRadius

      MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        Text {
          id: messageText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          // Messages may quote a transcript-derived title: never AutoText.
          textFormat: Text.PlainText
          text: root.message
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          wrapMode: Text.WordWrap
        }

        Row {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          spacing: Style.space(12)

          Repeater {
            model: [root.cancelText, root.confirmText]

            BorderSurface {
              required property int index
              required property string modelData

              readonly property bool selected: root.selectedIndex === index
              readonly property bool destructive: index === 1

              width: Style.space(112)
              height: Style.space(42)
              color: selected
                ? (destructive ? Util.alpha(Color.urgent, 0.22) : root.selectedBackground)
                : "transparent"
              borderSpec: Border.flat(destructive
                ? (selected ? Color.urgent : Util.alpha(Color.urgent, 0.56))
                : (selected ? root.selectedText : Util.alpha(root.foreground, 0.38)), Style.normalBorderWidth)
              radius: 0

              Text {
                anchors.centerIn: parent
                text: modelData
                color: destructive ? (selected ? Color.urgent : root.foreground) : (selected ? root.selectedText : root.foreground)
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectedIndex = index
                onClicked: {
                  if (index === 0) root.canceled()
                  else root.confirmed()
                }
              }
            }
          }
        }
      }
    }
  }
}
