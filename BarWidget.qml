import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "nichovski.spotify"

  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") || "") + "/.config") + "/omarchy"
  readonly property string credentialsFile: configDir + "/spotify/credentials.env"
  readonly property string outputFile: configDir + "/spotify/now_playing.json"
  readonly property string fetchScript: configDir + "/plugins/nichovski.spotify/fetch.sh"
  readonly property string controlScript: configDir + "/plugins/nichovski.spotify/control.sh"

  function close() { popupOpen = false }

  property bool hasCredentials: false
  property bool isPlaying: false
  property string title: ""
  property string artist: ""
  property string album: ""
  property string artUrl: ""
  property int progressMs: 0
  property int durationMs: 0
  property string lastTimestamp: ""
  property string errorMessage: ""
  property string deviceName: ""
  property var devices: []

  readonly property string activeDeviceName: {
    if (root.deviceName !== "") return root.deviceName
    for (var i = 0; i < root.devices.length; i++) {
      if (root.devices[i].is_active) return root.devices[i].name || ""
    }
    return ""
  }

  property bool popupOpen: false
  property real maxLabelWidth: 180
  property real maxArtistWidth: 160

  visible: hasCredentials && (title !== "" || errorMessage !== "")
  implicitWidth: hasCredentials ? row.implicitWidth + Style.space(14) : 0
  implicitHeight: barSize

  FileView {
    id: credFile
    path: root.credentialsFile
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.hasCredentials = String(text() || "").length > 0
      if (root.hasCredentials) {
        fetchTimer.restart()
      }
    }
    onLoadFailed: root.hasCredentials = false
    onFileChanged: reload()
  }

  function parseNowPlaying(content) {
    if (!content || content.length === 0) return
    try {
      var data = JSON.parse(content)
      root.isPlaying = data.is_playing || false
      root.title = data.title || ""
      root.artist = data.artist || ""
      root.album = data.album || ""
      root.artUrl = data.art_url || ""
      root.progressMs = data.progress_ms || 0
      root.durationMs = data.duration_ms || 0
      root.lastTimestamp = String(data.timestamp || "")
      root.errorMessage = data.error || ""
      root.deviceName = data.device || ""
      root.devices = data.devices || []
    } catch (e) {
      // Ignore parse errors
    }
  }

  FileView {
    id: outputFile
    path: root.outputFile
    watchChanges: true
    printErrors: false
    onLoaded: root.parseNowPlaying(String(text() || ""))
    onFileChanged: reload()
  }

  Timer {
    id: fetchTimer
    interval: 100
    repeat: false
    onTriggered: fetchProcess.running = true
  }

  Timer {
    id: pollTimer
    interval: root.isPlaying ? 5000 : 15000
    repeat: true
    running: root.hasCredentials
    triggeredOnStart: true
    onTriggered: fetchProcess.running = true
  }

  Timer {
    id: progressTimer
    interval: 1000
    repeat: true
    running: root.isPlaying
    onTriggered: root.progressMs = Math.min(root.progressMs + 1000, root.durationMs)
  }

  Process {
    id: fetchProcess
    command: ["bash", root.fetchScript]
    running: false
    onRunningChanged: if (!running) pollTimer.restart()
  }

  property var pendingArgs: []

  Process {
    id: controlProcess
    command: ["bash", root.controlScript].concat(root.pendingArgs)
    running: false
    onRunningChanged: if (!running) fetchTimer.restart()
  }

  function control(action, arg) {
    if (controlProcess.running) return
    root.pendingArgs = (arg !== undefined && arg !== null) ? [action, String(arg)] : [action]
    controlProcess.running = true
    // Optimistic UI update while the API call is in flight
    if (action === "playpause") root.isPlaying = !root.isPlaying
  }

  function formatTime(ms) {
    var totalSec = Math.floor(ms / 1000)
    var min = Math.floor(totalSec / 60)
    var sec = totalSec % 60
    return min + ":" + (sec < 10 ? "0" : "") + sec
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: glyph
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.isPlaying ? "\u{f04c}" : "\u{f04b}"
      color: root.isPlaying ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      Behavior on color {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }

    Text {
      id: iconGlyph
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: "\u{f1bc}"
      color: Qt.darker(root.bar.barForeground, 1.3)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Item {
      id: scrollClip
      width: Math.min(root.maxLabelWidth, labelText.implicitWidth)
      height: glyph.height
      clip: true
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.bar.vertical && root.title !== ""

      Text {
        id: labelText
        textFormat: Text.PlainText
        text: root.title + (root.artist ? "  ·  " + root.artist : "")
        color: root.bar.barForeground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter

        property bool needsScroll: implicitWidth > scrollClip.width

        NumberAnimation on x {
          id: scrollAnim
          running: labelText.needsScroll && !root.popupOpen && !root.bar.vertical
          loops: Animation.Infinite
          duration: Math.max(6000, labelText.implicitWidth * 25)
          from: scrollClip.width
          to: -labelText.implicitWidth
          easing.type: Easing.Linear
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.title ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (!root.title) return
      if (mouse.button === Qt.MiddleButton) {
        root.control("next")
      } else if (mouse.button === Qt.RightButton) {
        root.popupOpen = !root.popupOpen
      } else {
        root.control("playpause")
      }
    }
    onWheel: function(wheel) {
      if (!root.title) return
      if (wheel.angleDelta.y > 0) root.control("previous")
      else if (wheel.angleDelta.y < 0) root.control("next")
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.title ? (root.title + (root.artist ? " — " + root.artist : "")) : "Spotify Mini Player")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      // Album art + track info
      Row {
        spacing: Style.space(10)
        width: parent.width

        BorderSurface {
          width: Style.space(64)
          height: Style.space(64)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            source: root.artUrl
            sourceSize.width: 128
            sourceSize.height: 128
            visible: source !== ""
          }

          Text {
            anchors.centerIn: parent
            visible: root.artUrl === ""
            text: "\u{f1bc}"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          spacing: Style.space(4)
          width: parent.width - Style.space(74)

          Text {
            textFormat: Text.PlainText
            text: root.title || "Not playing"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: root.artist
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }

          Text {
            textFormat: Text.PlainText
            text: root.album
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }
      }

      // Progress bar
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.durationMs > 0

        Rectangle {
          width: parent.width
          height: Style.space(4)
          radius: Style.space(2)
          color: Qt.darker(root.bar.foreground, 1.8)

          Rectangle {
            width: root.durationMs > 0 ? parent.width * (root.progressMs / root.durationMs) : 0
            height: parent.height
            radius: Style.space(2)
            color: Color.accent

            Behavior on width {
              enabled: root.isPlaying
              NumberAnimation { duration: 1000; easing.type: Easing.Linear }
            }
          }
        }

        Row {
          width: parent.width

          Text {
            id: timeLeft
            textFormat: Text.PlainText
            text: formatTime(root.progressMs)
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Item { width: parent.width - timeLeft.implicitWidth - timeRight.implicitWidth; height: 1 }

          Text {
            id: timeRight
            textFormat: Text.PlainText
            text: "-" + formatTime(root.durationMs - root.progressMs)
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Playback controls (work on any Spotify Connect device)
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)
        visible: root.title !== ""

        Button {
          iconText: "\u{f048}"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.control("previous")
        }

        Button {
          iconText: root.isPlaying ? "\u{f04c}" : "\u{f04b}"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.panelGap
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          onClicked: root.control("playpause")
        }

        Button {
          iconText: "\u{f051}"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.control("next")
        }
      }

      // Devices (Spotify Connect)
      PanelSeparator {
        visible: root.devices.length > 0
        foreground: root.bar.foreground
      }

      Column {
        id: deviceList
        visible: root.devices.length > 0
        width: parent.width
        spacing: Style.space(4)

        Text {
          textFormat: Text.PlainText
          text: root.activeDeviceName !== "" ? "Playing on " + root.activeDeviceName : "Devices"
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }

        Repeater {
          model: root.devices

          BorderSurface {
            id: deviceRow
            required property var modelData

            readonly property bool isActive: modelData.is_active || modelData.name === root.activeDeviceName

            width: deviceList.width
            height: deviceInner.implicitHeight + Style.space(8)
            radius: Style.spacing.labelGap
            color: isActive ? Style.selectedFillFor(root.bar.foreground, Color.accent) : "transparent"
            borderSpec: isActive ? Border.controlSpec("normal", root.bar.foreground, Color.accent) : Border.none()

            Row {
              id: deviceInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: deviceRow.borderLeft + Style.space(8)
              anchors.rightMargin: deviceRow.borderRight + Style.space(8)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: {
                  var t = (modelData.type || "").toLowerCase()
                  if (t === "smartphone") return "\u{f10b}"
                  if (t === "computer") return "\u{f108}"
                  if (t === "speaker" || t === "castaudio") return "\u{f028}"
                  if (t === "tv") return "\u{f26c}"
                  return "\u{f001}"
                }
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                width: Style.space(18)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: (modelData.name || "Unknown device") + (modelData.type ? "  ·  " + modelData.type : "")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: deviceRow.isActive
                elide: Text.ElideRight
                width: parent.width - Style.space(26)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: deviceRow.isActive ? Qt.ArrowCursor : Qt.PointingHandCursor
              onClicked: {
                if (!deviceRow.isActive && modelData.id) root.control("device", modelData.id)
              }
            }
          }
        }
      }

      // Status
      Text {
        textFormat: Text.PlainText
        text: root.isPlaying ? "Playing" : (root.title ? "Paused" : "Open Spotify to start playing")
        color: Qt.darker(root.bar.foreground, 1.3)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
      }

      // Error message
      Text {
        textFormat: Text.PlainText
        text: root.errorMessage
        color: Color.urgent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        visible: text !== ""
        wrapMode: Text.WordWrap
      }
    }
  }
}
