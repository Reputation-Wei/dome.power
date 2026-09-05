import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "dome.power"
  ipcTarget: "dome.power"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property int chargeLimit: -1
  property bool chargeLimitAvailable: false
  property string chargeLimitError: ""
  property int pendingChargeLimit: -1
  property bool pendingChargeToFull: false
  property int pendingDefaultChargeLimit: -1
  property int blockedChargeLimitTarget: -1
  property string cursorSection: "profiles"
  property int chargeControlIndex: 2
  readonly property int minimumChargeLimit: 40
  readonly property int maximumChargeLimit: 100
  readonly property int defaultChargeLimit: Model.clampChargeLimit(setting("defaultChargeLimit", 80))
  readonly property int fullChargeLimit: maximumChargeLimit
  readonly property int chargeLimitStep: Model.normalizeChargeLimitStep(setting("chargeLimitStep", 10))
  readonly property bool chargeToFull: setting("chargeToFull", false) === true
  readonly property bool chargeLimitBusy: chargeReadProc.running || chargeLimitProc.running
  readonly property bool boostVisualActive: chargeToFull || (chargeLimitProc.running && pendingChargeToFull)
  property bool cursorActive: false
  readonly property bool showPercentage: setting("showPercentage", false) === true
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function moveCursor(dx, dy) {
    if (!cursorActive) {
      cursorActive = true
      return
    }

    if (cursorSection === "charge") {
      if (dx !== 0) chargeControlIndex = Math.max(0, Math.min(2, chargeControlIndex + dx))
      else if (dy > 0) cursorSection = "profiles"
      return
    }

    if (dy < 0) {
      cursorSection = "charge"
      chargeControlIndex = 2
      return
    }

    if (dx !== 0) selectProfileByDelta(dx)
    else if (dy > 0) selectProfileByDelta(dy)
  }

  function activateCursor() {
    if (!cursorActive) return
    if (cursorSection === "charge") activateChargeControl()
    else activateSelectedProfile()
  }

  function activateChargeControl() {
    if (chargeControlIndex === 0) stepDefaultChargeLimit(-1)
    else if (chargeControlIndex === 1) stepDefaultChargeLimit(1)
    else toggleChargeToFull()
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Color.foreground
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    "Pumping power",
    "Injecting electrons",
    "Pouring juice",
    "Amassing watts",
    "Hoarding joules",
    "Sucking volts",
    "Topping reserves",
    "Soaking amps",
    "Inhaling kilowatts"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power",
    "Spending joules",
    "Draining watts",
    "Burning electrons",
    "Sipping juice",
    "Spending coulombs",
    "Bleeding amps",
    "Guzzling volts",
    "Munching reserves"
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    if (fullyCharged) return "Fully charged"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  function refresh() {
    if (!batteryPresent) return

    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!chargeReadProc.running && !chargeLimitProc.running) chargeReadProc.running = true
    if (!systemProc.running) systemProc.running = true
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") batteryInfo = next
    else systemInfo = next
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  function persistChargeToFull(enabled) {
    if (chargeToFull === enabled) return
    root.settings = Object.assign({}, root.settings, { chargeToFull: enabled })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function persistDefaultChargeLimit(limit) {
    var next = Model.clampChargeLimit(limit)
    if (defaultChargeLimit === next) return
    root.settings = Object.assign({}, root.settings, { defaultChargeLimit: next })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function requestChargeLimit(limit, enableFullCharge, newDefaultLimit) {
    if (chargeLimitProc.running || chargeReadProc.running) return
    pendingChargeLimit = limit
    pendingChargeToFull = enableFullCharge
    pendingDefaultChargeLimit = newDefaultLimit === undefined ? -1 : Model.clampChargeLimit(newDefaultLimit)
    blockedChargeLimitTarget = -1
    chargeLimitError = ""
    chargeLimitProc.command = ["sudo", "-n", "/usr/bin/framework_tool", "--charge-limit", String(limit)]
    chargeLimitProc.running = true
  }

  function stepDefaultChargeLimit(delta) {
    if (!chargeLimitAvailable || chargeLimitBusy || boostVisualActive) return
    var next = Model.stepChargeLimit(defaultChargeLimit, delta, chargeLimitStep)
    if (next === defaultChargeLimit) return
    requestChargeLimit(next, false, next)
  }

  function toggleChargeToFull() {
    if (!chargeLimitAvailable || chargeLimitBusy) return
    requestChargeLimit(chargeToFull ? defaultChargeLimit : fullChargeLimit, !chargeToFull)
  }

  function reconcileChargeLimit() {
    if (!chargeLimitAvailable || chargeLimitBusy) return

    var keepFullCharge = Model.keepBoostActive(chargeToFull, batteryFull)
    var desiredLimit = keepFullCharge ? fullChargeLimit : defaultChargeLimit
    if (chargeLimit === desiredLimit) {
      blockedChargeLimitTarget = -1
      if (chargeToFull !== keepFullCharge) persistChargeToFull(keepFullCharge)
      return
    }
    if (!Model.shouldRequestChargeLimit(chargeLimit, desiredLimit, blockedChargeLimitTarget)) return

    requestChargeLimit(desiredLimit, keepFullCharge)
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  IpcHandler {
    target: "dome.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }

      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
      cursorSection = "profiles"
    }
  }

  onBatteryPresentChanged: {
    if (!batteryPresent) close()
    else if (!chargeReadProc.running && !chargeLimitProc.running) chargeReadProc.running = true
  }
  onBatteryFullChanged: {
    blockedChargeLimitTarget = -1
    root.reconcileChargeLimit()
  }

  Component.onCompleted: {
    if (batteryPresent && !chargeReadProc.running) chargeReadProc.running = true
  }

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
  }

  Process {
    id: chargeReadProc
    command: ["sudo", "-n", "/usr/bin/framework_tool", "--charge-limit"]
    stdout: StdioCollector { id: chargeReadOutput; waitForEnd: true }
    stderr: StdioCollector { id: chargeReadError; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseChargeLimit(chargeReadOutput.text)
      chargeLimitAvailable = exitCode === 0 && parsed >= 0
      chargeLimit = chargeLimitAvailable ? parsed : -1
      chargeLimitError = chargeLimitAvailable
        ? ""
        : (String(chargeReadError.text || "").indexOf("password is required") >= 0
          ? "Install the passwordless sudoers rule to enable charge-limit control."
          : "Framework charge-limit status is unavailable.")
      if (chargeLimitAvailable) Qt.callLater(root.reconcileChargeLimit)
    }
  }

  Process {
    id: chargeLimitProc
    stdout: StdioCollector { id: chargeLimitOutput; waitForEnd: true }
    onExited: function(exitCode) {
      var completedLimit = pendingChargeLimit
      var completedFullCharge = pendingChargeToFull
      var completedDefaultLimit = pendingDefaultChargeLimit
      pendingChargeLimit = -1
      pendingChargeToFull = false
      pendingDefaultChargeLimit = -1

      if (exitCode === 0) {
        var parsed = Model.parseChargeLimit(chargeLimitOutput.text)
        chargeLimit = parsed >= 0 ? parsed : completedLimit
        chargeLimitAvailable = true
        if (chargeLimit === completedLimit) {
          blockedChargeLimitTarget = -1
          chargeLimitError = ""
          if (completedDefaultLimit >= minimumChargeLimit) persistDefaultChargeLimit(completedDefaultLimit)
          persistChargeToFull(completedFullCharge)
        } else {
          blockedChargeLimitTarget = completedLimit
          chargeLimitError = "Framework kept the charge limit at " + chargeLimit + "%."
        }
      } else {
        blockedChargeLimitTarget = completedLimit
        chargeLimitError = "Could not change the charge limit."
      }

      Qt.callLater(root.reconcileChargeLimit)
    }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showPercentage && !vertical
      ? Math.round(root.batteryFraction * 100) + "% " + root.batteryIcon()
      : root.batteryIcon()
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.batteryInfo.percentage || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Battery size"; value: root.batteryInfo.size || "" }
            InfoPair { label: "Charge cycles"; value: root.batteryInfo.cycles || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? "Charge limit" : (root.discharging ? "Time left" : "Time to full")
              value: root.chargeThresholdActive ? (root.batteryInfo.threshold || "-") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: root.chargeThresholdActive ? "Battery state" : (root.discharging ? "Discharging" : "Charging")
              value: root.chargeThresholdActive ? "Holding" : (root.batteryFull ? "-" : (root.batteryInfo.rate || ""))
            }
          }
        }

        // ---------- Framework charge limit ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "CHARGE LIMIT"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: chargeControlRow
            width: parent.width
            spacing: 0
            readonly property real controlHeight: Style.space(42)

            Item {
              id: defaultLimitControl
              width: Style.space(140)
              height: chargeControlRow.controlHeight
              opacity: root.boostVisualActive ? 0.35 : 1.0

              readonly property int displayedLimit: root.boostVisualActive
                ? root.defaultChargeLimit
                : (root.chargeLimitAvailable ? root.chargeLimit : root.defaultChargeLimit)

              Behavior on opacity { NumberAnimation { duration: 160 } }

              Button {
                id: decreaseLimitButton
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
                height: parent.height
                text: "−"
                fontSize: Style.font.title
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                hasCursor: root.cursorActive && root.cursorSection === "charge" && root.chargeControlIndex === 0
                enabled: root.chargeLimitAvailable && !root.chargeLimitBusy && !root.boostVisualActive
                  && root.defaultChargeLimit > root.minimumChargeLimit
                onClicked: root.stepDefaultChargeLimit(-1)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.cursorSection = "charge"
                    root.chargeControlIndex = 0
                  }
                }
              }

              Text {
                anchors.left: decreaseLimitButton.right
                anchors.right: increaseLimitButton.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: chargeReadProc.running && !root.chargeLimitAvailable
                  ? "…"
                  : defaultLimitControl.displayedLimit + "%"
                horizontalAlignment: Text.AlignHCenter
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Button {
                id: increaseLimitButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
                height: parent.height
                text: "+"
                fontSize: Style.font.title
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                hasCursor: root.cursorActive && root.cursorSection === "charge" && root.chargeControlIndex === 1
                enabled: root.chargeLimitAvailable && !root.chargeLimitBusy && !root.boostVisualActive
                  && root.defaultChargeLimit < root.maximumChargeLimit
                onClicked: root.stepDefaultChargeLimit(1)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.cursorSection = "charge"
                    root.chargeControlIndex = 1
                  }
                }
              }
            }

            Item {
              width: Math.max(Style.space(16), chargeControlRow.width - defaultLimitControl.width - boostButton.width)
              height: 1
            }

            Button {
              id: boostButton
              width: Style.space(128)
              height: chargeControlRow.controlHeight
              iconText: "⚡"
              iconSize: Style.font.body
              text: "Boost"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: root.boostVisualActive
              hasCursor: root.cursorActive && root.cursorSection === "charge" && root.chargeControlIndex === 2
              enabled: root.chargeLimitAvailable && !root.chargeLimitBusy
                && (root.chargeToFull || root.defaultChargeLimit < root.fullChargeLimit)
              onClicked: root.toggleChargeToFull()
              onHovered: function(h) {
                if (h) {
                  root.cursorActive = true
                  root.cursorSection = "charge"
                  root.chargeControlIndex = 2
                }
              }
            }
          }

          Text {
            visible: root.chargeLimitError !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.chargeLimitError
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.cursorSection === "profiles" && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.cursorSection = "profiles"
                    root.profileIndex = index
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
