import QtQuick
import qs.Commons
import qs.Ui

// Shared chrome for the palette's custom modals (rename, help): centered
// card, click swallow, small-caps caption, content column. The delete
// confirmation uses qs.Ui ConfirmDialog instead.
BorderSurface {
  id: surface

  property string caption: ""
  property int maxWidth: Style.space(720)
  property color foreground
  property string fontFamily

  default property alias content: body.data

  width: Math.min(maxWidth, parent ? parent.width - Style.gapsOut * 2 : maxWidth)
  height: col.height + Style.space(64)
  radius: Style.cornerRadius
  anchors.centerIn: parent
  padding: Style.space(24)

  MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }

  Column {
    id: col
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(32)
    anchors.rightMargin: Style.space(32)
    spacing: Style.spacing.lg

    Text {
      width: parent.width
      visible: surface.caption !== ""
      text: surface.caption
      color: surface.foreground
      opacity: 0.4
      font.family: surface.fontFamily
      font.pixelSize: Style.font.body
      font.letterSpacing: 2
    }

    Column {
      id: body
      width: parent.width
      spacing: Style.spacing.lg
    }
  }
}
