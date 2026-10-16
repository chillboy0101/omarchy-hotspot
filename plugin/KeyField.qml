import QtQuick
import qs.Commons
import qs.Ui

// Single-line text entry built from key presses alone, styled like qs.Ui
// TextField. It never creates a TextInput, so Qt has no reason to read the
// Wayland clipboard on the shell's behalf; paste (Ctrl+V, middle click) is
// intentionally unsupported for the same reason.
//
// Data flows one way: the parent binds `text` and stores each
// `textEdited(value)`, so a reset from the panel always reaches the field.
// Editing is append-only: printable text without Ctrl/Alt/Meta is added at
// the end, Backspace removes one code point, Return/Enter emit `accepted`
// and Escape emits `cancelled`. Tab is left to the focus chain.
FocusScope {
  id: root

  property string text: ""
  property string placeholderText: ""
  property bool password: false
  // Counted in UTF-16 units, like TextInput.maximumLength and String.length.
  property int maximumLength: 32767
  property color foreground: Color.foreground
  property color accent: Color.accent
  property font font
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY

  readonly property bool _focused: activeFocus
  readonly property bool _hot: mouse.containsMouse
  readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, root.accent)
  readonly property string _shownText: password ? "\u25cf".repeat(_codePoints(text).length) : text
  property bool _caretOn: true

  property real leftPadding: horizontalPadding + Border.left(_borderSpec)
  property real rightPadding: horizontalPadding + Border.right(_borderSpec)
  property real topPadding: verticalPadding + Border.top(_borderSpec)
  property real bottomPadding: verticalPadding + Border.bottom(_borderSpec)

  signal textEdited(string value)
  signal accepted()
  signal cancelled()

  font.family: Style.font.family
  font.pixelSize: Style.font.body

  implicitWidth: Math.max(label.implicitWidth, placeholder.implicitWidth) + caret.width + leftPadding + rightPadding
  implicitHeight: Math.ceil(metrics.height) + topPadding + bottomPadding
  activeFocusOnTab: true

  Accessible.role: Accessible.EditableText
  Accessible.name: placeholderText
  Accessible.passwordEdit: password

  // Splits by hand: the QML engine's string iterator (Array.from, for-of)
  // walks UTF-16 units and would cut surrogate pairs apart.
  function _codePoints(value) {
    var points = []
    for (var i = 0; i < value.length; i++) {
      var unit = value.charCodeAt(i)
      var next = i + 1 < value.length ? value.charCodeAt(i + 1) : 0
      var pair = unit >= 0xd800 && unit <= 0xdbff && next >= 0xdc00 && next <= 0xdfff
      points.push(value.substr(i, pair ? 2 : 1))
      if (pair) i++
    }
    return points
  }

  // Rejects C0/C1 controls; a surrogate pair is checked by its lead unit.
  function _isPrintable(point) {
    var unit = point.charCodeAt(0)
    return unit >= 0x20 && !(unit >= 0x7f && unit <= 0x9f)
  }

  function _withoutLastCodePoint(value) {
    var end = value.length - 1
    var last = value.charCodeAt(end)
    if (end > 0 && last >= 0xdc00 && last <= 0xdfff) {
      var previous = value.charCodeAt(end - 1)
      if (previous >= 0xd800 && previous <= 0xdbff) end--
    }
    return value.slice(0, end)
  }

  function _append(value, codePoints) {
    var next = value
    for (var i = 0; i < codePoints.length; i++) {
      if (next.length + codePoints[i].length > maximumLength) break
      next += codePoints[i]
    }
    return next
  }

  function _restartCaret() {
    _caretOn = true
    if (activeFocus && caretBlink.interval > 0) caretBlink.restart()
    else caretBlink.stop()
  }

  onTextChanged: _restartCaret()
  onActiveFocusChanged: _restartCaret()

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      event.accepted = true
      root.accepted()
      return
    }
    if (event.key === Qt.Key_Escape) {
      event.accepted = true
      root.cancelled()
      return
    }
    var commandModifiers = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)
    if (event.key === Qt.Key_Backspace) {
      event.accepted = true
      if (!commandModifiers && root.text.length > 0) root.textEdited(_withoutLastCodePoint(root.text))
      return
    }
    var typed = _codePoints(event.text || "")
    // Tab, Delete and other unprintable keys fall through to the focus chain.
    if (commandModifiers || typed.length === 0 || !typed.every(_isPrintable)) {
      event.accepted = false
      return
    }
    event.accepted = true
    var next = _append(root.text, typed)
    if (next !== root.text) root.textEdited(next)
  }

  FontMetrics {
    id: metrics
    font: root.font
  }

  Timer {
    id: caretBlink
    interval: Math.max(0, Qt.styleHints.cursorFlashTime / 2)
    repeat: true
    onTriggered: root._caretOn = !root._caretOn
  }

  BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(root._focused, root._hot, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }

  Item {
    id: viewport
    x: root.leftPadding
    y: root.topPadding
    width: Math.max(0, root.width - root.leftPadding - root.rightPadding)
    height: Math.max(0, root.height - root.topPadding - root.bottomPadding)
    clip: true

    Text {
      id: placeholder
      visible: root.text === ""
      width: parent.width
      anchors.verticalCenter: parent.verticalCenter
      text: root.placeholderText
      textFormat: Text.PlainText
      color: Qt.darker(root.foreground, 1.6)
      font: root.font
      elide: Text.ElideRight
    }

    // Scrolls left once the text is wider than the field so the end stays
    // in view, as TextInput does for a caret at the end.
    Text {
      id: label
      x: Math.min(0, viewport.width - implicitWidth - caret.width)
      anchors.verticalCenter: parent.verticalCenter
      text: root._shownText
      textFormat: Text.PlainText
      color: root.foreground
      font: root.font
    }

    Rectangle {
      id: caret
      visible: root.activeFocus && root._caretOn
      x: label.x + label.implicitWidth
      anchors.verticalCenter: parent.verticalCenter
      width: 1
      height: Math.ceil(metrics.height)
      color: root.foreground
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.IBeamCursor
    acceptedButtons: Qt.LeftButton
    onPressed: root.forceActiveFocus()
  }
}
