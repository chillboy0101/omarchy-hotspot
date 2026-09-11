import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Mobile hotspot panel (io.github.shivamnarkar47.omarchy-hotspot), modeled on omarchy.network:
// a bar button that opens a keyboard-navigable popup with a hero toggle,
// a scannable QR code, and live connection details. The AP runs on a
// virtual interface (ap0) served by wpa_supplicant + dnsmasq via
// omarchy-hotspot-helper, so the station connection stays up the whole
// time. QR payload: WIFI:T:WPA;S:OmarchyHotspot;P:<password>;; rendered
// from the same 0/1 matrix format as omarchy.wifiqr.
Panel {
  id: root
  moduleName: "io.github.shivamnarkar47.omarchy-hotspot"
  ipcTarget: "io.github.shivamnarkar47.omarchy-hotspot"

  readonly property string helper: "/usr/local/bin/omarchy-hotspot-helper"
  readonly property string qrScript: decodeURIComponent(String(Qt.resolvedUrl("qr.sh")).replace(/^file:\/\//, ""))
  property string hotspotSsid: "OmarchyHotspot"
  readonly property string ssidFile: "/var/lib/omarchy-hotspot/ssid"
  readonly property string passwordFile: "/var/lib/omarchy-hotspot/password"

  // "off" | "on" | "busy" | "error"
  property string hotspotState: "off"
  property string hotspotPassword: ""
  property string hotspotUplink: ""
  property string hotspotChannel: ""
  property string hotspotClients: ""
  property var hotspotDevices: []
  property string lastError: ""
  property bool showPassword: false
  property bool qrOverlayOpen: false

  // SSID editing state.
  property bool editingSsid: false
  property string ssidDraft: ""
  property bool ssidBusy: false
  property string ssidError: ""
  property string pendingSsid: ""

  // Password editing state.
  property bool editingPassword: false
  property string passwordDraft: ""
  property bool passwordBusy: false
  property string passwordError: ""
  property string pendingPassword: ""

  property var qrRows: []
  property int qrSize: 0
  property bool qrLoading: false

  // Wi-Fi tethering icon: same Material Design icon family as Omarchy's
  // native network widget, with a fuller shape that reads at bar size.
  readonly property string iconText: "󰖩"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property bool isOn: hotspotState === "on"
  readonly property bool isBusy: hotspotState === "busy"
  readonly property bool isError: hotspotState === "error"
  readonly property bool showingQr: qrSize > 0 && !qrLoading && !isError
  readonly property color stateColor: isError ? root.urgent : root.foreground

  // Copy feedback: icon flips to a checkmark briefly.
  property bool copyFlash: false

  // Cursor: "hero" (toggle switch) | "actions" (copy password, refresh QR)
  property bool cursorActive: false
  property string focusSection: "hero"
  property int actionIndex: 0
  readonly property int actionCount: 3  // copy password, refresh QR, edit password

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function close() {
    root.controller.hide()
  }

  function openQrOverlay() {
    if (!isOn) return
    qrOverlayOpen = true
    if (!showingQr) generateQr()
  }

  function closeQrOverlay() {
    qrOverlayOpen = false
  }

  function refresh() {
    if (statusProc.running) return
    // pkexec (passwordless via polkit rule): channel + client counts need root.
    statusProc.command = ["bash", "-c", "pkexec " + root.helper + " status"]
    statusProc.running = true
    if (isOn && !clientsProc.running) {
      clientsProc.command = ["bash", "-c", "pkexec " + root.helper + " clients"]
      clientsProc.running = true
    }
  }

  function toggle() {
    if (toggleProc.running) return
    hotspotState = "busy"
    lastError = ""
    toggleProc.command = ["bash", "-c", "pkexec " + root.helper + " toggle"]
    toggleProc.running = true
  }

  function generateQr() {
    if (qrProc.running || !isOn) return
    qrLoading = true
    qrProc.command = ["bash", root.qrScript]
    qrProc.running = true
  }

  function applyStatus(raw) {
    var parts = String(raw || "").trim().split(/\s+/)
    if (parts[0] === "on") {
      hotspotState = "on"
      if (parts[1] && !root.editingSsid) hotspotSsid = parts[1]
      hotspotUplink = parts[2] || ""
      hotspotChannel = parts[3] || ""
      hotspotClients = parts[4] || ""
      if (!clientsProc.running) {
        clientsProc.command = ["bash", "-c", "pkexec " + root.helper + " clients"]
        clientsProc.running = true
      }
      if (qrSize === 0 && !qrProc.running) Qt.callLater(generateQr)
      // Pull the passphrase straight from the user-owned secret file rather
      // than from the status channel.
      readPassword()
    } else if (root.isError) {
      // We're showing a failure. A fresh status of "off" is expected right
      // after a failed toggle (the AP hasn't come up), so don't let the
      // periodic/refresh status call clobber the error detail the user needs
      // to see. It clears on the next successful toggle or once the hotspot
      // actually starts.
      return
    } else {
      hotspotState = "off"
      if (parts[1] && !root.editingSsid) hotspotSsid = parts[1]
      hotspotPassword = ""
      hotspotUplink = ""
      hotspotChannel = ""
      hotspotClients = ""
      hotspotDevices = []
    }
  }

  function readPassword() {
    if (passReadProc.running) return
    passReadProc.command = ["bash", "-c", "cat " + root.passwordFile]
    passReadProc.running = true
  }

  function applyQr(raw) {
    var lines = String(raw || "").trim().split(/\r?\n/).filter(function(l) { return l !== "" })
    // Drop the meta line if present (kept for parity with omarchy-network-qr).
    if (lines.length > 0 && lines[0].indexOf("meta\t") === 0) lines.shift()
    if (lines.length < 2) return
    var size = lines[0].length
    if (size !== lines.length) return
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].length !== size || !/^[01]+$/.test(lines[i])) return
    }
    qrRows = lines
    qrSize = size
    qrLoading = false
  }

  function copyPassword() {
    if (!root.bar || !hotspotPassword) return
    // Copy from the secret file (user-readable, 600) so the password never
    // appears in a process command line.
    Quickshell.execDetached(["bash", "-c", "cat " + root.passwordFile + " | wl-copy"])
    // Flash the copy icon to a checkmark so the click is visibly acknowledged.
    copyFlash = true
    copyFlashTimer.restart()
  }

  function startPasswordEdit() {
    if (passwordBusy) return
    if (editingSsid) cancelSsidEdit()
    passwordDraft = hotspotPassword || ""
    passwordError = ""
    editingPassword = true
    Qt.callLater(function() { if (passwordField) passwordField.forceActiveFocus() })
  }

  function cancelPasswordEdit() {
    editingPassword = false
    passwordDraft = ""
    passwordError = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function savePassword() {
    if (passwordBusy) return
    var draft = passwordDraft.trim()
    if (draft.length < 8) { passwordError = "Minimum 8 characters"; return }
    if (draft.length > 63) { passwordError = "Maximum 63 characters"; return }
    passwordBusy = true
    passwordError = ""
    // Feed the passphrase over stdin (not argv) so it is never exposed in the
    // process command line. The helper reads it from stdin.
    pendingPassword = draft
    passProc.command = ["bash", "-c", "pkexec " + root.helper + " set-password"]
    passProc.running = true
  }

  function startSsidEdit() {
    if (ssidBusy) return
    if (editingPassword) cancelPasswordEdit()
    ssidDraft = hotspotSsid || "OmarchyHotspot"
    ssidError = ""
    editingSsid = true
    Qt.callLater(function() {
      if (typeof qrSsidField !== "undefined" && qrSsidField && qrSsidField.visible) qrSsidField.forceActiveFocus()
    })
  }

  function cancelSsidEdit() {
    editingSsid = false
    ssidDraft = ""
    ssidError = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function saveSsid() {
    if (ssidBusy) return
    var draft = ssidDraft.trim()
    if (draft.length < 1) { ssidError = "SSID cannot be empty"; return }
    if (draft.length > 32) { ssidError = "Maximum 32 characters"; return }
    ssidBusy = true
    ssidError = ""
    pendingSsid = draft
    ssidProc.command = ["bash", "-c", "pkexec " + root.helper + " set-ssid"]
    ssidProc.running = true
  }

  function statusLine() {
    if (isOn) return ""
    if (isBusy) return ""
    if (isError) return "Unable to start"
    return ""
  }

  // ---- Cursor navigation ------------------------------------------------
  function moveCursor(dy) {
    if (!cursorActive) { cursorActive = true; return }
    if (dy < 0 && focusSection === "actions") focusSection = "hero"
    else if (dy > 0 && focusSection === "hero") { focusSection = "actions"; actionIndex = 0 }
  }

  function activate() {
    if (!cursorActive) return
    if (focusSection === "hero") toggle()
    else if (actionIndex === 0) copyPassword()
    else if (actionIndex === 1) generateQr()
    else if (actionIndex === 2) startPasswordEdit()
  }

  function setSection(section, index) {
    cursorActive = true
    focusSection = section
    actionIndex = index === undefined ? 0 : index
  }

  readonly property bool heroHasCursor: cursorActive && focusSection === "hero"
  readonly property bool copyHasCursor: cursorActive && focusSection === "actions" && actionIndex === 0
  readonly property bool qrHasCursor: cursorActive && focusSection === "actions" && actionIndex === 1
  readonly property bool editHasCursor: cursorActive && focusSection === "actions" && actionIndex === 2

  // ---- Processes --------------------------------------------------------
  Process {
    id: statusProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
    onExited: function(code) {
      if (code !== 0 && hotspotState !== "busy") hotspotState = "error"
    }
  }

  Process {
    id: clientsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows = String(text || "").trim().split(/\r?\n/).filter(function(line) { return line !== "" })
        root.hotspotDevices = rows.map(function(line) {
          var p = line.split("\t")
          return { mac: p[0] || "", signal: p[1] || "", connected: p[2] || "" }
        }).filter(function(device) { return device.mac !== "" })
      }
    }
    onExited: function(code) { if (code !== 0) root.hotspotDevices = [] }
  }

  Process {
    id: toggleProc
    stdout: StdioCollector { id: toggleOut; waitForEnd: true }
    stderr: StdioCollector { id: toggleErr; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) {
        var detail = String(toggleErr.text || toggleOut.text || "").replace(/\s+/g, " ").trim()
        root.lastError = detail ? detail.slice(0, 120) : ("exit " + code)
        root.hotspotState = "error"
      }
      Qt.callLater(function() {
        root.refresh()
        if (root.isOn) root.generateQr()
      })
    }
  }

  Process {
    id: qrProc
    stdout: StdioCollector { id: qrOut; waitForEnd: true; onStreamFinished: root.applyQr(text) }
    stderr: StdioCollector { id: qrErr; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) root.lastError = String(qrErr.text || "").trim().slice(0, 120) || ("QR failed: exit " + code)
      qrLoading = false
    }
  }

  Process {
    id: ssidProc
    stdinEnabled: true
    stdout: StdioCollector { id: ssidOut; waitForEnd: true }
    stderr: StdioCollector { id: ssidErr; waitForEnd: true }
    onStarted: function() {
      ssidProc.write(root.pendingSsid + "\n")
    }
    onExited: function(code) {
      ssidBusy = false
      if (code !== 0) {
        ssidError = String(ssidErr.text || ssidOut.text || "").replace(/\s+/g, " ").trim().slice(0, 120) || ("exit " + code)
        return
      }
      root.hotspotSsid = root.pendingSsid
      editingSsid = false
      ssidDraft = ""
      root.refresh()
      if (root.isOn) root.generateQr()
    }
  }

  Process {
    id: passProc
    stdinEnabled: true
    stdout: StdioCollector { id: passOut; waitForEnd: true }
    stderr: StdioCollector { id: passErr; waitForEnd: true }
    onStarted: function() {
      // Send the passphrase as a single line (newline-terminated); the helper
      // reads one line, so we never need to close stdin.
      passProc.write(root.pendingPassword + "\n")
    }
    onExited: function(code) {
      passwordBusy = false
      if (code !== 0) {
        passwordError = String(passErr.text || passOut.text || "").replace(/\s+/g, " ").trim().slice(0, 120) || ("exit " + code)
        return
      }
      editingPassword = false
      passwordDraft = ""
      root.refresh()
      if (root.isOn) root.generateQr()
    }
  }

  // Reads the passphrase directly from the user-owned secret file (no root,
  // no passwordless pkexec), keeping it out of the status channel.
  Process {
    id: passReadProc
    stdout: StdioCollector {
      id: passReadOut
      waitForEnd: true
      onStreamFinished: function() {
        if (root.isOn) {
          root.hotspotPassword = String(passReadOut.text || "").trim()
          root.showPassword = false
        }
      }
    }
  }

  Timer {
    id: copyFlashTimer
    interval: 1200
    repeat: false
    onTriggered: root.copyFlash = false
  }

  Timer {
    interval: 4000
    repeat: true
    // Poll only while the panel is visible; avoid background pkexec/nmcli
    // work competing with the bar and other shell widgets.
    running: root.opened
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      if (isOn) generateQr()
      cursorActive = false
      focusSection = "hero"
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    }
  }

  onHotspotStateChanged: {
    if (isOn && qrSize === 0 && opened) Qt.callLater(generateQr)
  }

  // ---- Bar button -------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconText
    // Keep the icon in the same neutral bar colour as Network and the other
    // widgets; the on/off state is shown inside the popup and by the toggle.
    active: false

    onPressed: function(btn) {
      if (btn !== Qt.LeftButton) return
      if (root.opened) root.close()
      else root.open()
    }
  }

  // ---- Popup ------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingPassword || root.passwordBusy

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        if (dx !== 0 && root.focusSection === "actions") {
          root.actionIndex = Math.max(0, Math.min(root.actionCount - 1, root.actionIndex + (dx > 0 ? 1 : -1)))
        }
      }
      onActivateRequested: root.activate()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(12)

      // ---------- Hero: icon · name + state · toggle ----------
      Item {
        width: parent.width
        implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

        Text {
          id: heroIcon
          text: root.iconText
          color: root.isOn ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

          RowLayout {
            id: heroActions
            spacing: Style.space(8)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Button {
              visible: root.isOn
              iconText: "󰐲"
              tooltipText: "Show QR code"
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconSize: Style.font.subtitle * 1.5
              horizontalPadding: Style.space(5)
              verticalPadding: Style.space(2)
              hasCursor: root.qrHasCursor
              onHovered: function(on) { if (on) root.setSection("actions", 1) }
              onClicked: root.openQrOverlay()
            }

            PanelActionButton {
            visible: root.isOn
            iconText: "󰏫"
            tooltipText: "Edit network name"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.startSsidEdit()
          }

          ToggleSwitch {
            id: powerSwitch
            checked: root.isOn
            busy: root.isBusy
            hasCursor: root.heroHasCursor
            foreground: root.foreground
            Layout.alignment: Qt.AlignVCenter
            onHovered: function(on) { if (on) root.setSection("hero") }
            onToggled: root.toggle()

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: root.isOn ? "Turn hotspot off" : "Turn hotspot on"
              fontFamily: root.fontFamily
            }
          }
        }

        Column {
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: parent.right
          anchors.rightMargin: heroActions.width > 0 ? heroActions.width + Style.space(12) : 0
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: root.hotspotSsid
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }

          Row {
            visible: root.isError
            spacing: Style.space(5)

            Rectangle {
              width: Style.space(6)
              height: width
              radius: width / 2
              color: root.stateColor
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: root.statusLine()
              textFormat: Text.PlainText
              color: root.stateColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
            }
          }

        }
      }

      // ---------- Error notification (hotspot failed to start) ----------
      Rectangle {
        id: errorBox
        visible: root.isError
        width: parent.width
        implicitHeight: errorBoxInner.implicitHeight + Style.space(20)
        color: Qt.alpha(root.urgent, 0.12)
        radius: Style.cornerRadius
        border.color: Qt.alpha(root.urgent, 0.45)
        border.width: 1

        Column {
          id: errorBoxInner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          Text {
            width: parent.width
            text: "⚠ HOTSPOT FAILED TO START"
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }

          Text {
            width: parent.width
            text: root.lastError || "Check the logs: journalctl -u omarchy-hotspot"
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          Text {
            width: parent.width
            text: "Toggle again once the issue is fixed."
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }
      }

      Column {
        visible: root.isOn
        width: parent.width
        spacing: Style.space(10)

        /* QR is shown in the native-style overlay opened from the header. */
        /*
          width: parent.width
          implicitHeight: Math.max(qrTitle.implicitHeight, qrRefreshRow.implicitHeight)

          PanelSectionHeader {
            id: qrTitle
            text: "SCAN TO JOIN"
            foreground: root.foreground
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Row {
            id: qrRefreshRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              id: qrRefreshButton
              iconText: "󰐲"
              tooltipText: "Regenerate QR"
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconSize: Style.font.subtitle * 1.5
              horizontalPadding: Style.space(5)
              verticalPadding: Style.space(2)
              hasCursor: root.qrHasCursor
              onHovered: function(on) { if (on) root.setSection("actions", 1) }
              onClicked: root.openQrOverlay()
            }
          }
        }

        // White rounded canvas; only dark modules paint. Same rendering
        // approach as omarchy.wifiqr.
        Rectangle {
          id: qrCanvas
          readonly property int moduleSize: root.qrSize > 0
            ? Math.max(4, Math.floor(Style.space(240) / root.qrSize))
            : 0

          visible: root.showingQr
          width: root.qrSize * moduleSize
          height: width
          color: "white"
          radius: Style.cornerRadius
          anchors.horizontalCenter: parent.horizontalCenter

          Grid {
            anchors.fill: parent
            columns: root.qrSize

            Repeater {
              model: root.qrSize * root.qrSize

              Rectangle {
                required property int index
                readonly property int matrixRow: Math.floor(index / root.qrSize)
                readonly property int matrixColumn: index % root.qrSize

                width: qrCanvas.moduleSize
                height: qrCanvas.moduleSize
                color: root.qrRows[matrixRow].charAt(matrixColumn) === "1" ? "#111111" : "transparent"
              }
            }
          }
        }

        Text {
          visible: root.qrLoading
          text: "Generating QR code…"
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          anchors.horizontalCenter: parent.horizontalCenter
        }

        */
        // Password appears once, with its edit and copy actions.
        RowLayout {
          visible: !root.editingSsid && !root.editingPassword
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: "Password"
            color: root.foreground
            opacity: 0.65
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            text: root.hotspotPassword ? (root.showPassword ? root.hotspotPassword : "••••••••••") : "—"
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
          }

          PanelActionButton {
            iconText: root.showPassword ? "󰈈" : "󰈉"
            tooltipText: root.showPassword ? "Hide password" : "Show password"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.showPassword = !root.showPassword
          }

          PanelActionButton {
            iconText: "󰏫"
            tooltipText: "Edit password"
            foreground: root.foreground
            fontFamily: root.fontFamily
            hasCursor: root.editHasCursor
            onHovered: function(on) { if (on) root.setSection("actions", 2) }
            onClicked: root.startPasswordEdit()
          }

          PanelActionButton {
            iconText: root.copyFlash ? "" : ""
            tooltipText: root.copyFlash ? "Copied" : "Copy password"
            foreground: root.foreground
            fontFamily: root.fontFamily
            hasCursor: root.copyHasCursor
            onHovered: function(on) { if (on) root.setSection("actions", 0) }
            onClicked: root.copyPassword()
          }

          Text {
            visible: root.copyFlash
            text: "Copied"
            color: root.stateColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            verticalAlignment: Text.AlignVCenter
          }
        }

        PanelSeparator {
          visible: root.isOn
          foreground: root.foreground
        }

        RowLayout {
          visible: root.isOn && !root.editingSsid && !root.editingPassword
          width: parent.width

          Text {
            text: "Connected devices"
            color: root.foreground
            opacity: 0.65
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Item { Layout.fillWidth: true }

          Text {
            text: String(Number(root.hotspotClients || 0))
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }

        Column {
          visible: root.isOn && root.hotspotDevices.length > 0 && !root.editingSsid && !root.editingPassword
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.hotspotDevices

            RowLayout {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              Text {
                text: "•"
                color: root.foreground
                opacity: 0.65
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                text: modelData.mac
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                Layout.fillWidth: true
              }

              Text {
                text: modelData.signal ? modelData.signal + " dBm" : ""
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                text: modelData.connected ? modelData.connected + "s" : ""
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // Editing SSID: centered row
        Row {
          visible: root.editingSsid
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(6)

          TextField {
            id: qrSsidField
            width: Style.space(140)
            text: root.ssidDraft
            placeholderText: "Hotspot Name"
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            foreground: root.foreground
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(3)
            onTextChanged: if (visible && text !== root.ssidDraft) root.ssidDraft = text
            onAccepted: root.saveSsid()
            Keys.onEscapePressed: root.cancelSsidEdit()
          }

          PanelActionButton {
            iconText: ""
            tooltipText: "Save name"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.saveSsid()
          }

          PanelActionButton {
            iconText: "󰜺"
            tooltipText: "Cancel"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.cancelSsidEdit()
          }
        }

        // Editing Password: centered row
        Row {
          visible: root.editingPassword
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(6)

          TextField {
            id: passwordField
            width: Style.space(140)
            text: root.passwordDraft
            placeholderText: "New password (8+)"
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            foreground: root.foreground
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(3)
            onTextChanged: if (visible && text !== root.passwordDraft) root.passwordDraft = text
            onAccepted: root.savePassword()
            Keys.onEscapePressed: root.cancelPasswordEdit()
          }

          PanelActionButton {
            iconText: ""
            tooltipText: "Save password"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.savePassword()
          }

          PanelActionButton {
            iconText: "󰜺"
            tooltipText: "Cancel"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.cancelPasswordEdit()
          }
        }

        Text {
          visible: root.ssidError !== ""
          text: root.ssidError
          textFormat: Text.PlainText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.horizontalCenter: parent.horizontalCenter
        }

        Text {
          visible: root.passwordError !== ""
          text: root.passwordError
          textFormat: Text.PlainText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.horizontalCenter: parent.horizontalCenter
        }
      }


    }
  }

  // Native-style QR presentation, matching omarchy.wifiqr's centered code
  // and dark scrim while keeping the hotspot payload local to this plugin.
  PanelWindow {
    visible: root.qrOverlayOpen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-hotspot-qr"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.78)
      MouseArea { anchors.fill: parent; onClicked: root.closeQrOverlay() }
    }

    Item {
      id: qrOverlayContent
      anchors.centerIn: parent
      width: qrOverlayColumn.implicitWidth
      height: qrOverlayColumn.implicitHeight
      focus: true
      Keys.onEscapePressed: root.closeQrOverlay()
      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: qrOverlayColumn
        spacing: Style.space(16)

        Text {
          text: String(root.hotspotSsid || "Hotspot").toUpperCase()
          color: Qt.rgba(1, 1, 1, 0.55)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 2
          anchors.horizontalCenter: parent.horizontalCenter
        }

        Rectangle {
          id: qrOverlayCanvas
          readonly property int moduleSize: root.qrSize > 0
            ? Math.max(4, Math.floor(Style.space(240) / root.qrSize)) : 0
          visible: root.showingQr
          width: root.qrSize * moduleSize
          height: width
          color: "white"
          radius: Style.cornerRadius
          anchors.horizontalCenter: parent.horizontalCenter

          Grid {
            anchors.fill: parent
            columns: root.qrSize
            Repeater {
              model: root.qrSize * root.qrSize
              Rectangle {
                required property int index
                readonly property int matrixRow: Math.floor(index / root.qrSize)
                readonly property int matrixColumn: index % root.qrSize
                width: qrOverlayCanvas.moduleSize
                height: width
                color: root.qrRows[matrixRow].charAt(matrixColumn) === "1" ? "#111111" : "transparent"
              }
            }
          }
        }

        Text {
          visible: root.qrLoading
          text: "Generating QR code…"
          color: Qt.rgba(1, 1, 1, 0.55)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          anchors.horizontalCenter: parent.horizontalCenter
        }

        Text {
          visible: root.showingQr
          text: "Scan to join this network"
          color: Qt.rgba(1, 1, 1, 0.55)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          anchors.horizontalCenter: parent.horizontalCenter
        }
      }
    }
  }

}
