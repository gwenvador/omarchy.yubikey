import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// YubiKey management for Omarchy.
//
// Four pages, one per question people actually have about a security key:
// what is this key (Device), how do I log into this machine with it (System),
// how do I log into my accounts with it (Accounts), and why is nothing working
// (Setup). Everything is drawn from qs.Ui, so the panel follows the active
// theme with no styling of its own.
//
// The panel holds no state it did not just read. Every page re-reads from
// `bin/omarchy-yubikey` on open and after every change, because the key is a
// physical object that can be pulled out mid-session and a cached view of it
// is a lie waiting to happen.
//
// Nothing that prompts for a PIN, a touch, or a password runs inside the shell
// process. Those go out to `omarchy-yubikey term <cmd>`, which opens a real
// terminal — the same thing `omarchy setup security fido2` does, and the only
// honest way to ask for a touch.
Item {
  id: root

  // ---- plugin lifecycle ---------------------------------------------------
  property bool closingFromHost: false
  property var shell: null
  property var manifest: null

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    reloadAll()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    else window.visible = false
  }

  // ---- theme --------------------------------------------------------------
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color dimmer: Qt.darker(foreground, 1.6)
  readonly property string fontFamily: Style.font.family

  // ---- backend ------------------------------------------------------------
  //
  // PluginRegistry stamps __sourceDir onto the manifest, which is how the QML
  // locates the script it ships with without knowing where plugins live.
  readonly property string pluginId: (manifest && manifest.id) ? String(manifest.id) : "eusener.yubikey"
  readonly property string sourceDir: (manifest && manifest.__sourceDir) ? String(manifest.__sourceDir) : ""
  readonly property string helper: sourceDir ? sourceDir + "/bin/omarchy-yubikey" : ""

  property string errorText: ""
  property string busyText: ""

  // ---- data ---------------------------------------------------------------
  property var status: ({ present: false, devices: [], pins: {}, pivSlots: [], missingTool: true })
  property var deps: ({ deps: [], missing: 0, pcscdRunning: false })
  property var pam: ({ services: [], registered: false, keyCount: 0, authfile: "/etc/fido2/fido2" })
  property var ssh: ({ skKeys: [], pkcs11Module: "", gpgSshEnabled: false })
  property var luks: ({ devices: [], hasCryptenroll: false })
  property var oath: ({ locked: false, accounts: [], error: "" })
  property var providers: []

  readonly property var device: (status && status.devices && status.devices.length > 0) ? status.devices[0] : null
  readonly property bool toolingMissing: !!(status && status.missingTool)
  readonly property bool keyPresent: !!(status && status.present)

  // Applets the panel offers a switch for, in the order a person meets them.
  // Names match what `ykman info` prints; a key that lacks one simply has no
  // row, because the table it is read from has no row either.
  // Spelled exactly as `ykman info` prints them — the backend maps these to the
  // short keys `ykman config usb` wants, since the two vocabularies differ.
  readonly property var appletOrder: ["FIDO2", "FIDO U2F", "OATH", "PIV", "OpenPGP", "Yubico OTP", "YubiHSM Auth"]

  readonly property var applets: {
    var out = []
    if (!device || !device.applications) return out
    for (var i = 0; i < appletOrder.length; i++) {
      var name = appletOrder[i]
      var row = device.applications[name]
      if (!row) continue
      var usb = String(row.usb || "")
      if (usb.toLowerCase().indexOf("not available") >= 0) continue
      out.push({ name: name, enabled: usb.toLowerCase().indexOf("enabled") >= 0, nfc: String(row.nfc || "") })
    }
    return out
  }

  // ---- readers ------------------------------------------------------------
  //
  // One shape for every read: run the backend, parse JSON, hand it to a
  // callback. A read that produces no JSON leaves the previous value in place
  // and says so, rather than blanking the page.
  component JsonReader: Process {
    id: reader
    property var argv: []
    property var sink: null
    property string label: ""
    property bool parsedOk: false

    // Everything goes through sh so a missing backend still produces an exit
    // code instead of silently never running.
    command: ["/bin/sh", "-c", "exec \"$0\" \"$@\"", root.helper].concat(argv)
    onRunningChanged: if (running) parsedOk = false
    onExited: function(exitCode) {
      if (!parsedOk && exitCode !== 0)
        root.errorText = "`omarchy-yubikey " + argv.join(" ") + "` failed (exit " + exitCode + ")."
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || ""))
          reader.parsedOk = true
          if (reader.sink) reader.sink(d)
        } catch (e) {
          // Left deliberately quiet: onExited reports the real failure, and a
          // parse error with exit 0 means an empty read, not a broken one.
        }
      }
    }
  }

  JsonReader { id: statusReader;    argv: ["status"];      sink: function(d) { root.status = d; root.errorText = "" } }
  JsonReader { id: depsReader;      argv: ["deps"];        sink: function(d) { root.deps = d } }
  JsonReader { id: pamReader;       argv: ["pam-status"];  sink: function(d) { root.pam = d } }
  JsonReader { id: sshReader;       argv: ["ssh-status"];  sink: function(d) { root.ssh = d } }
  JsonReader { id: luksReader;      argv: ["luks-status"]; sink: function(d) { root.luks = d } }
  JsonReader { id: oathReader;      argv: ["oath-list"];   sink: function(d) { root.oath = d; root.clampCursor() } }
  JsonReader { id: providersReader; argv: ["providers"];   sink: function(d) { root.providers = d } }

  function reloadAll() {
    if (!helper) {
      errorText = "This panel could not locate its own plugin directory, so the backend cannot be run."
      return
    }
    statusReader.running = true
    depsReader.running = true
    pamReader.running = true
    sshReader.running = true
    luksReader.running = true
    oathReader.running = true
    if (!providers || providers.length === 0) providersReader.running = true
  }

  // ---- actions ------------------------------------------------------------
  //
  // Two kinds. `run` is a change the shell can make on its own; it refreshes
  // when it finishes. `runTerm` is a change that needs a human at a keyboard
  // (a PIN, a touch, a sudo password) and opens a terminal to get one.
  Process {
    id: actionProc
    property string describe: ""
    onExited: function(exitCode) {
      root.busyText = ""
      if (exitCode !== 0) root.errorText = describe + " failed (exit " + exitCode + ")."
      else root.errorText = ""
      root.reloadAll()
    }
  }

  function run(argv, describe) {
    if (!helper || actionProc.running) return
    actionProc.describe = describe || argv.join(" ")
    busyText = describe || ""
    errorText = ""
    actionProc.command = ["/bin/sh", "-c", "exec \"$0\" \"$@\"", helper].concat(argv)
    actionProc.running = true
  }

  // The terminal owns the interaction from here, so the panel stops guessing
  // and re-reads once the window has had time to close.
  function runTerm(argv) {
    if (!helper) return
    Quickshell.execDetached(["/bin/sh", "-c", "exec \"$0\" term \"$@\"", helper].concat(argv))
    termRefresh.restart()
  }

  Timer { id: termRefresh; interval: 2500; repeat: true; triggeredOnStart: false
    property int ticks: 0
    onTriggered: { root.reloadAll(); ticks++; if (ticks > 8) { stop(); ticks = 0 } }
    onRunningChanged: if (running) ticks = 0
  }

  function openUrl(url) { Quickshell.execDetached(["xdg-open", url]) }

  // ---- cursor model -------------------------------------------------------
  //
  // One flat list of targets per page, same as the gallery and the stock
  // panels, so j/k crosses section boundaries without special cases. Entries
  // that stand for a row of live data carry the row's id after a colon.
  property string tab: "device"
  property string focusSection: "tabs"

  readonly property var tabs: [
    { value: "device",   label: "Device",   icon: "󰌆" },
    { value: "system",   label: "System",   icon: "󰌾" },
    { value: "accounts", label: "Accounts", icon: "󰇮" },
    { value: "setup",    label: "Setup",    icon: "󰒓" }
  ]

  readonly property var visibleSections: {
    var s = ["tabs", "refresh"]
    if (tab === "device") {
      if (keyPresent) {
        for (var i = 0; i < applets.length; i++) s.push("app:" + applets[i].name)
        s = s.concat(["pin:fido2", "pin:piv", "pin:openpgp",
                      "reset:fido2", "reset:piv", "reset:oath", "reset:openpgp"])
      }
    } else if (tab === "system") {
      s.push("pam-register")
      var svcs = (pam && pam.services) ? pam.services : []
      for (var j = 0; j < svcs.length; j++) s.push("pam:" + svcs[j].service)
      s = s.concat(["ssh-sk", "ssh-sk-plain", "ssh-recover", "ssh-piv", "gpg-ssh"])
      if (luks && luks.devices && luks.devices.length > 0) s.push("luks-enroll")
      s.push("pam-forget")
    } else if (tab === "accounts") {
      s = s.concat(["oath-scan", "oath-issuer", "oath-name", "oath-secret", "oath-touch", "oath-add"])
      var accts = (oath && oath.accounts) ? oath.accounts : []
      for (var k = 0; k < accts.length; k++) s.push("oath:" + accts[k].id)
      for (var m = 0; m < providers.length; m++) s.push("prov:" + providers[m].id)
    } else {
      s.push("install-deps")
    }
    return s
  }

  function moveCursor(dy) {
    var list = visibleSections
    var i = list.indexOf(focusSection)
    if (i < 0) i = 0
    focusSection = list[Math.max(0, Math.min(list.length - 1, i + (dy > 0 ? 1 : -1)))]
  }

  // h/l only means something on the tab row; elsewhere it stays a no-op rather
  // than jumping the cursor somewhere the user did not ask for.
  function moveCursorH(dx) {
    if (focusSection !== "tabs") return
    var i = 0
    for (var t = 0; t < tabs.length; t++) if (tabs[t].value === tab) i = t
    setTab(tabs[Math.max(0, Math.min(tabs.length - 1, i + (dx > 0 ? 1 : -1)))].value)
  }

  function setTab(v) {
    if (tab === v) return
    tab = v
    focusSection = "tabs"
  }

  function clampCursor() {
    if (visibleSections.indexOf(focusSection) < 0) focusSection = "tabs"
  }
  onTabChanged: {
    clampCursor()
    // A new page starts at the top; otherwise the old page's scroll offset
    // carries over and the page opens somewhere in its middle.
    if (scrollArea && scrollArea.contentItem) scrollArea.contentItem.contentY = 0
  }

  // These pages are longer than the window, so walking the cursor with j/k has
  // to bring the view along with it. Same shape as the gallery's version.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var margin = Style.space(12)
    if (top < flick.contentY + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function activateCursor() {
    var s = focusSection
    if (s === "refresh") { reloadAll(); return }
    if (s === "pam-register") { runTerm(["pam-register"]); return }
    if (s === "pam-forget") { runTerm(["pam-forget"]); return }
    if (s === "ssh-sk") { runTerm(["ssh-sk", "ed25519-sk", "resident"]); return }
    if (s === "ssh-sk-plain") { runTerm(["ssh-sk", "ed25519-sk", "nonresident"]); return }
    if (s === "ssh-recover") { runTerm(["ssh-recover"]); return }
    if (s === "ssh-piv") { runTerm(["ssh-piv"]); return }
    if (s === "gpg-ssh") { run(["gpg-ssh", ssh.gpgSshEnabled ? "off" : "on"], "Switching gpg-agent SSH support"); return }
    if (s === "luks-enroll") { runTerm(["luks-enroll"]); return }
    if (s === "install-deps") { runTerm(["install-deps"]); return }
    if (s === "oath-scan") { runTerm(["oath-scan"]); return }
    if (s === "oath-add") { submitAccount(); return }
    if (s === "oath-touch") { newTouch = !newTouch; return }
    if (s.indexOf("pam:") === 0) { togglePam(s.substring(4)); return }
    if (s.indexOf("app:") === 0) { toggleApplet(s.substring(4)); return }
    if (s.indexOf("pin:") === 0) { runTerm(["pin", s.substring(4)]); return }
    if (s.indexOf("reset:") === 0) { runTerm(["reset", s.substring(6)]); return }
    if (s.indexOf("oath:") === 0) { generateCode(s.substring(5)); return }
    if (s.indexOf("prov:") === 0) { openProvider(s.substring(5)); return }
  }

  // ---- page actions -------------------------------------------------------

  function pamService(name) {
    var svcs = (pam && pam.services) ? pam.services : []
    for (var i = 0; i < svcs.length; i++) if (svcs[i].service === name) return svcs[i]
    return null
  }

  function togglePam(name) {
    var svc = pamService(name)
    if (!svc) return
    // Turning a stack on with nothing registered would prompt for a touch from
    // a key that PAM has never been introduced to, and quietly fall through
    // forever. Send the user to registration instead of writing the line.
    if (!svc.enabled && !pam.registered) {
      errorText = "Register the key with PAM first — there is nothing in " + pam.authfile + " to match against."
      return
    }
    run([svc.enabled ? "pam-disable" : "pam-enable", name],
        (svc.enabled ? "Removing " : "Adding ") + "pam_u2f " + (svc.enabled ? "from " : "to ") + name)
  }

  function toggleApplet(name) {
    var target = null
    for (var i = 0; i < applets.length; i++) if (applets[i].name === name) target = applets[i]
    if (!target) return
    if (target.enabled) {
      // Disabling is the destructive direction: an applet switched off over
      // USB takes every credential on it out of reach until it is switched
      // back on, and switching FIDO2 off can lock the key out of this session.
      confirm.message = "Disable the " + name + " applet over USB?\n\nAnything relying on it stops working until you turn it back on."
      confirm.confirmText = "Disable"
      confirm.action = function() { root.run(["app", name, "off"], "Disabling " + name) }
      confirm.opened = true
    } else {
      run(["app", name, "on"], "Enabling " + name)
    }
  }

  // ---- account entry ------------------------------------------------------
  property string newIssuer: ""
  property string newName: ""
  property string newSecret: ""
  property bool newTouch: false

  function submitAccount() {
    if (newName.length === 0 || newSecret.length === 0) {
      errorText = "An account needs at least a name and the secret the provider showed you."
      return
    }
    run(["oath-add", newIssuer, newName, newSecret, newTouch ? "touch" : "no"],
        "Adding " + (newIssuer ? newIssuer + ":" : "") + newName)
    newIssuer = ""; newName = ""; newSecret = ""; newTouch = false
  }

  // The code lands on the clipboard and in a notification; the panel only
  // reports that it is waiting, since a touch-protected account can sit here
  // for as long as it takes someone to reach the key.
  function generateCode(id) {
    run(["oath-code", id], "Reading a code for " + id + " — touch the key if it blinks")
  }

  function deleteAccount(id) {
    confirm.message = "Delete " + id + " from the key?\n\nThe secret is destroyed. Re-adding it needs the original from the provider."
    confirm.confirmText = "Delete"
    confirm.action = function() { root.run(["oath-delete", id], "Deleting " + id) }
    confirm.opened = true
  }

  function openProvider(id) {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].id === id) { openUrl(providers[i].url); return }
  }

  // ---- shared row ---------------------------------------------------------
  //
  // Almost every control on these pages is the same thing: an icon, a title, a
  // line of explanation, and some state on the right. Defining it once keeps
  // the three pages consistent and keeps the cursor plumbing in one place.
  component ActionRow: CursorSurface {
    id: rowRoot
    property string section: ""
    property string icon: ""
    property string title: ""
    property string description: ""
    property string trailing: ""
    property color trailingColor: root.dim
    property bool enabledLook: true
    signal activated()

    outline: true
    foreground: root.foreground
    accent: root.accent
    hasCursor: root.focusSection === rowRoot.section
    implicitHeight: rowBody.implicitHeight + Style.spacing.rowPaddingX * 2
    opacity: enabledLook ? 1.0 : 0.45

    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(rowRoot)

    HoverHandler { onHoveredChanged: if (hovered) root.focusSection = rowRoot.section }
    TapHandler {
      onTapped: {
        if (!rowRoot.enabledLook) return
        root.focusSection = rowRoot.section
        rowRoot.activated()
      }
    }

    Row {
      id: rowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(14)
      anchors.rightMargin: Style.space(14)
      spacing: Style.space(12)

      Text {
        text: rowRoot.icon
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        width: 22
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
        visible: rowRoot.icon.length > 0
      }

      Column {
        width: parent.width - (rowRoot.icon.length > 0 ? 34 : 0) - trailingText.width - Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          text: rowRoot.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          width: parent.width
          elide: Text.ElideRight
        }
        Text {
          text: rowRoot.description
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          width: parent.width
          wrapMode: Text.WordWrap
          visible: rowRoot.description.length > 0
        }
      }

      Text {
        id: trailingText
        text: rowRoot.trailing
        color: rowRoot.trailingColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  // A label/value line for the device facts, where the value is the point and
  // wrapping it would be worse than eliding it.
  component Fact: Row {
    property string label: ""
    property string value: ""
    spacing: Style.space(10)
    visible: value.length > 0

    Text {
      text: parent.label
      color: root.dimmer
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      width: 130
    }
    Text {
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // ---- window -------------------------------------------------------------
  FloatingWindow {
    id: window
    title: "YubiKey"
    color: root.background
    implicitWidth: 660
    implicitHeight: 820
    minimumSize: Qt.size(520, 520)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    FocusScope {
      anchors.fill: parent
      focus: true

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: confirm.opened || issuerField.activeFocus || nameField.activeFocus || secretField.activeFocus
        onMoveRequested: function(dx, dy) {
          if (dy !== 0) root.moveCursor(dy)
          else if (dx !== 0) root.moveCursorH(dx)
        }
        onActivateRequested: root.activateCursor()
        onTabRequested: function(direction) { root.moveCursorH(direction) }
        onCloseRequested: root.requestClose()

        ScrollView {
          id: scrollArea
          anchors.fill: parent
          anchors.margins: Style.space(18)
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

          Column {
            width: scrollArea.availableWidth
            spacing: Style.space(18)

            // ---- header --------------------------------------------------
            Row {
              width: parent.width
              spacing: Style.space(14)

              Text {
                text: root.keyPresent ? "󰌆" : "󰌊"
                color: root.keyPresent ? root.accent : root.dimmer
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - 60 - refreshButton.width - Style.space(28)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  text: root.device ? (root.device.name || "YubiKey") : "YubiKey"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }
                Text {
                  text: {
                    if (root.toolingMissing) return "Supporting packages are missing — open Setup."
                    if (!root.keyPresent) return "No key detected. Plug one in, then refresh."
                    var bits = []
                    if (root.device.serial) bits.push("Serial " + root.device.serial)
                    if (root.device.version) bits.push("Firmware " + root.device.version)
                    if (root.status.count > 1) bits.push(root.status.count + " keys connected")
                    return bits.join("  ·  ")
                  }
                  color: root.keyPresent ? root.dim : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }

              Button {
                id: refreshButton
                text: "Refresh"
                iconText: "󰑙"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                hasCursor: root.focusSection === "refresh"
                anchors.verticalCenter: parent.verticalCenter
                onHovered: function(h) { if (h) root.focusSection = "refresh" }
                onClicked: { root.focusSection = "refresh"; root.reloadAll() }
              }
            }

            // ---- tabs ----------------------------------------------------
            ButtonGroup {
              width: parent.width
              options: root.tabs
              value: root.tab
              foreground: root.foreground
              background: root.background
              accent: root.accent
              fontFamily: root.fontFamily
              cursorIndex: -1
              onChanged: function(v) { root.focusSection = "tabs"; root.setTab(v) }
              onHovered: function(index, isHovered) { if (isHovered) root.focusSection = "tabs" }
            }

            // ---- messages ------------------------------------------------
            BorderSurface {
              width: parent.width
              visible: root.errorText.length > 0 || root.busyText.length > 0
              implicitHeight: msgCol.implicitHeight + Style.spacing.rowPaddingX * 2
              radius: Style.cornerRadius
              readonly property color tint: root.errorText.length > 0 ? root.urgent : root.accent
              color: Qt.rgba(tint.r, tint.g, tint.b, 0.10)
              borderSpec: Border.flat(Qt.rgba(tint.r, tint.g, tint.b, 0.45), 1)

              Column {
                id: msgCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(14)
                anchors.rightMargin: Style.space(14)
                spacing: Style.space(3)

                Text {
                  text: root.errorText.length > 0 ? "Something went wrong" : "Working"
                  color: root.errorText.length > 0 ? root.urgent : root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
                Text {
                  text: root.errorText.length > 0 ? root.errorText : root.busyText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }
            }

            // ================================================== DEVICE ====
            Column {
              width: parent.width
              spacing: Style.space(20)
              visible: root.tab === "device"

              // Nothing plugged in, or nothing to read it with. Both are
              // ordinary states, not errors, so they get a plain explanation
              // rather than the red banner.
              Column {
                width: parent.width
                spacing: Style.space(6)
                visible: !root.keyPresent

                Text {
                  text: root.toolingMissing ? "The YubiKey tools are not installed yet" : "No YubiKey detected"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  text: root.toolingMissing
                    ? "This page reads the key through ykman, which is not on this machine yet. The Setup tab installs it along with everything else the other pages need."
                    : "Plug the key in and press Refresh. If it is already in, the key may have an applet disabled, or the smartcard daemon may not be running — Setup can tell you which."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }

              // ---- identity ----------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.keyPresent

                PanelSectionHeader { text: "This key"; foreground: root.foreground; fontFamily: root.fontFamily }

                BorderSurface {
                  width: parent.width
                  implicitHeight: factCol.implicitHeight + Style.spacing.rowPaddingX * 2
                  radius: Style.cornerRadius
                  color: Style.normalFill
                  borderSpec: Border.flat(Style.normalBorderColor, 1)

                  Column {
                    id: factCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(14)
                    anchors.rightMargin: Style.space(14)
                    spacing: Style.space(5)

                    Fact { label: "Model";        value: root.device ? String(root.device.name || "") : "" }
                    Fact { label: "Serial";       value: root.device ? String(root.device.serial || "") : "" }
                    Fact { label: "Firmware";     value: root.device ? String(root.device.version || "") : "" }
                    Fact { label: "Form factor";  value: root.device ? String(root.device.formFactor || "") : "" }
                    Fact { label: "USB interfaces"; value: root.device ? String(root.device.interfaces || "") : "" }
                    Fact { label: "NFC";          value: root.device ? (root.device.nfc ? "Enabled" : "Not available") : "" }
                    Fact { label: "FIPS";         value: (root.device && root.device.fips) ? "Yes" : "" }
                  }
                }
              }

              // ---- applets ------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.keyPresent

                PanelSectionHeader { text: "Applets"; foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: "A YubiKey is several independent devices sharing one body. Switching one off over USB hides it from this machine entirely — useful for narrowing what a key exposes, and an easy way to lose access to something if you forget you did it."
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: root.applets
                  delegate: ActionRow {
                    required property var modelData
                    width: parent.width
                    section: "app:" + modelData.name
                    icon: {
                      switch (modelData.name) {
                        case "FIDO2": return "󰯄"
                        case "FIDO U2F": return "󰯄"
                        case "OATH": return "󰥔"
                        case "PIV": return "󰄀"
                        case "OpenPGP": return "󰌾"
                        case "Yubico OTP": return "󰌌"
                        default: return "󰘦"
                      }
                    }
                    title: modelData.name
                    description: {
                      switch (modelData.name) {
                        case "FIDO2": return "Passkeys, WebAuthn security keys, SSH -sk keys, LUKS unlock"
                        case "FIDO U2F": return "The older second-factor protocol, still used by some sites"
                        case "OATH": return "TOTP codes for Gmail, Outlook, AWS — the Accounts tab"
                        case "PIV": return "Smartcard certificates, usable for SSH over PKCS#11"
                        case "OpenPGP": return "GPG keys on the card, and gpg-agent as an SSH agent"
                        case "YubiHSM Auth": return "Credential store for YubiHSM 2 devices"
                        case "Yubico OTP": return "Yubico OTP and the static-password slots"
                        default: return ""
                      }
                    }
                    trailing: modelData.enabled ? "Enabled" : "Off"
                    trailingColor: modelData.enabled ? root.accent : root.dimmer
                    onActivated: root.toggleApplet(modelData.name)
                  }
                }
              }

              // ---- PINs ---------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.keyPresent

                PanelSectionHeader { text: "PINs"; foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: "Each applet keeps its own PIN and its own retry counter. Run out of retries and the applet locks; on FIDO2 that means a factory reset and re-registering everywhere. These open a terminal, because a PIN prompt belongs in one."
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                ActionRow {
                  width: parent.width
                  section: "pin:fido2"
                  icon: "󰯄"
                  title: (root.status.pins && root.status.pins.fido && root.status.pins.fido.set) ? "Change the FIDO2 PIN" : "Set a FIDO2 PIN"
                  description: (root.status.pins && root.status.pins.fido && root.status.pins.fido.set)
                    ? "Required by passkeys and by SSH keys made with verify-required."
                    : "Not set yet. Passkeys and verify-required SSH keys need one."
                  trailing: {
                    var f = root.status.pins ? root.status.pins.fido : null
                    if (!f) return ""
                    if (!f.set) return "Not set"
                    return f.retries ? f.retries + " tries left" : "Set"
                  }
                  trailingColor: (root.status.pins && root.status.pins.fido && root.status.pins.fido.set) ? root.dim : root.urgent
                  enabledLook: root.keyPresent
                  onActivated: root.runTerm(["pin", "fido2"])
                }

                ActionRow {
                  width: parent.width
                  section: "pin:piv"
                  icon: "󰄀"
                  title: "Change the PIV PIN"
                  description: {
                    var p = root.status.pins ? root.status.pins.piv : null
                    if (p && p.defaultPin)
                      return "Still on the factory PIN (123456) — anyone with the key in hand can use the slots. Change it before putting anything in one."
                    return "Guards the smartcard slots."
                  }
                  trailing: {
                    var p = root.status.pins ? root.status.pins.piv : null
                    return (p && p.retries) ? p.retries + " tries left" : ""
                  }
                  enabledLook: !!(root.status.pins && root.status.pins.piv && root.status.pins.piv.present)
                  onActivated: root.runTerm(["pin", "piv"])
                }

                Text {
                  text: {
                    var p = root.status.pins ? root.status.pins.piv : null
                    if (!p) return ""
                    var stale = []
                    if (p.defaultPuk) stale.push("PUK")
                    if (p.defaultMgmt) stale.push("management key")
                    if (stale.length === 0) return ""
                    return "The PIV " + stale.join(" and the ") + " " + (stale.length > 1 ? "are" : "is")
                      + " still set to the factory default. Change "
                      + (stale.length > 1 ? "them" : "it")
                      + " from a terminal with `omarchy-yubikey pin piv-puk` and `omarchy-yubikey pin piv-mgmt` "
                      + "before the PIV applet holds anything worth guarding."
                  }
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                  visible: text.length > 0
                }

                ActionRow {
                  width: parent.width
                  section: "pin:openpgp"
                  icon: "󰌾"
                  title: "Change the OpenPGP PIN"
                  description: "Guards the GPG keys on the card. Default is 123456, with 12345678 as the admin PIN."
                  trailing: {
                    var g = root.status.pins ? root.status.pins.openpgp : null
                    return (g && g.retries) ? g.retries + " tries left" : ""
                  }
                  enabledLook: !!(root.status.pins && root.status.pins.openpgp && root.status.pins.openpgp.present)
                  onActivated: root.runTerm(["pin", "openpgp"])
                }
              }

              PanelSeparator { foreground: root.foreground; visible: root.keyPresent }

              // ---- resets --------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.keyPresent

                PanelSectionHeader { text: "Reset an applet"; foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: "Each of these wipes one applet back to factory state and cannot be undone. The terminal asks you to type the applet name before anything happens."
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Grid {
                  width: parent.width
                  columns: 2
                  spacing: Style.space(8)

                  Repeater {
                    model: [
                      { app: "fido2",   label: "Reset FIDO2",   note: "Drops every passkey and site registration" },
                      { app: "piv",     label: "Reset PIV",     note: "Destroys all slot keypairs and certificates" },
                      { app: "oath",    label: "Reset OATH",    note: "Destroys every stored TOTP account" },
                      { app: "openpgp", label: "Reset OpenPGP", note: "Destroys the GPG keys on the card" }
                    ]
                    delegate: ActionRow {
                      required property var modelData
                      width: (parent.width - Style.space(8)) / 2
                      section: "reset:" + modelData.app
                      icon: "󰦞"
                      title: modelData.label
                      description: modelData.note
                      trailingColor: root.urgent
                      onActivated: root.runTerm(["reset", modelData.app])
                    }
                  }
                }
              }
            }

            // ================================================== SYSTEM ====
            Column {
              width: parent.width
              spacing: Style.space(20)
              visible: root.tab === "system"

              // ---- PAM ----------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader { text: "Logging into this machine"; foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: "PAM is the stack every password prompt on this machine goes through. Registering writes this key's public credential to " + root.pam.authfile + "; each switch below then adds one `sufficient` line to that prompt's stack, so a touch satisfies it and your password still works if the key is not around."
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                ActionRow {
                  width: parent.width
                  section: "pam-register"
                  icon: "󰌆"
                  title: root.pam.registered ? "Register another key" : "Register this key with PAM"
                  description: root.pam.registered
                    ? "Adds a second key to the same file — worth doing before you rely on the first one."
                    : "Opens a terminal, asks for a touch, and writes the credential. Nothing below works until this is done."
                  trailing: root.pam.keyCount > 0 ? root.pam.keyCount + " registered" : "None yet"
                  trailingColor: root.pam.registered ? root.accent : root.urgent
                  onActivated: root.runTerm(["pam-register"])
                }

                Repeater {
                  model: root.pam.services || []
                  delegate: ActionRow {
                    required property var modelData
                    width: parent.width
                    section: "pam:" + modelData.service
                    icon: {
                      switch (modelData.service) {
                        case "sudo": return "󰆍"
                        case "polkit": return "󰒘"
                        case "login": return "󰌾"
                        case "lock": return "󰍁"
                        default: return "󰘦"
                      }
                    }
                    title: {
                      switch (modelData.service) {
                        case "sudo": return "sudo"
                        case "polkit": return "Graphical privilege prompts"
                        case "login": return "Console login"
                        case "lock": return "Lock screen"
                        default: return modelData.service
                      }
                    }
                    description: {
                      switch (modelData.service) {
                        case "sudo": return "Touch the key instead of typing your password at a sudo prompt."
                        case "polkit": return "The dialog Omarchy raises when an app needs root. The file is created if it does not exist."
                        case "login": return "The text logins on tty2–tty6. The graphical greeter has its own stack and is not covered."
                        case "lock": return "Omarchy's lock screen. Note the trade: the stack asks for a touch before it checks the password, so unlocking without the key means waiting that prompt out first."
                        default: return modelData.file
                      }
                    }
                    trailing: modelData.enabled ? "On" : "Off"
                    trailingColor: modelData.enabled ? root.accent : root.dimmer
                    onActivated: root.togglePam(modelData.service)
                  }
                }
              }

              // ---- SSH ----------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader { text: "SSH"; foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: "Three unrelated ways to put an SSH identity on the key, and a key can hold all three. FIDO2 is the simple one: OpenSSH speaks it directly, with no agent and no daemon."
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                ActionRow {
                  width: parent.width
                  section: "ssh-sk"
                  icon: "󰌘"
                  title: "New resident SSH key (recommended)"
                  description: "ed25519-sk stored on the key itself, protected by the FIDO2 PIN and a touch. Because it is resident, you can pull it back onto a new machine with nothing but the key."
                  trailing: (root.ssh.skKeys && root.ssh.skKeys.length > 0) ? root.ssh.skKeys.length + " on disk" : ""
                  onActivated: root.runTerm(["ssh-sk", "ed25519-sk", "resident"])
                }

                ActionRow {
                  width: parent.width
                  section: "ssh-sk-plain"
                  icon: "󰌘"
                  title: "New non-resident SSH key"
                  description: "Same touch requirement, but the handle lives only in ~/.ssh — lose the file and the key cannot recover it. Use this where a PIN prompt on every connection would be in the way."
                  onActivated: root.runTerm(["ssh-sk", "ed25519-sk", "nonresident"])
                }

                ActionRow {
                  width: parent.width
                  section: "ssh-recover"
                  icon: "󰃨"
                  title: "Recover resident keys from the key"
                  description: "Writes the key handles for every resident credential back into ~/.ssh. This is what you run on a machine that has never seen this YubiKey."
                  onActivated: root.runTerm(["ssh-recover"])
                }

                ActionRow {
                  width: parent.width
                  section: "ssh-piv"
                  icon: "󰄀"
                  title: "Use the PIV applet over PKCS#11"
                  description: root.ssh.pkcs11Module.length > 0
                    ? "Points OpenSSH at " + root.ssh.pkcs11Module + " so a keypair in a PIV slot can authenticate. Needs pcscd running."
                    : "No PKCS#11 module is installed yet — Setup adds one."
                  trailing: root.ssh.pkcs11InSshConfig ? "Configured" : ""
                  trailingColor: root.accent
                  enabledLook: root.ssh.pkcs11Module.length > 0
                  onActivated: root.runTerm(["ssh-piv"])
                }

                ActionRow {
                  width: parent.width
                  section: "gpg-ssh"
                  icon: "󰌾"
                  title: "Use gpg-agent as the SSH agent"
                  description: "Exposes an OpenPGP authentication subkey on the card as an SSH identity. Takes effect after logging out and back in, since it sets SSH_AUTH_SOCK for the session."
                  trailing: root.ssh.gpgSshEnabled ? "On" : "Off"
                  trailingColor: root.ssh.gpgSshEnabled ? root.accent : root.dimmer
                  onActivated: root.run(["gpg-ssh", root.ssh.gpgSshEnabled ? "off" : "on"], "Switching gpg-agent SSH support")
                }
              }

              // ---- disk ---------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.luks.devices && root.luks.devices.length > 0

                PanelSectionHeader { text: "Disk encryption"; foreground: root.foreground; fontFamily: root.fontFamily }

                ActionRow {
                  width: parent.width
                  section: "luks-enroll"
                  icon: "󰋊"
                  title: "Unlock this disk with the key at boot"
                  description: {
                    var d = (root.luks.devices && root.luks.devices.length > 0) ? root.luks.devices[0] : null
                    if (!d) return ""
                    return "Enrolls the key as a FIDO2 unlock method for " + d.device
                      + ". Your passphrase stays valid and remains the only way in if the key is lost — keep it."
                  }
                  trailing: {
                    var d = (root.luks.devices && root.luks.devices.length > 0) ? root.luks.devices[0] : null
                    if (!d) return ""
                    return d.fido2Tokens > 0 ? "Enrolled" : ""
                  }
                  trailingColor: root.accent
                  enabledLook: root.luks.hasCryptenroll
                  onActivated: root.runTerm(["luks-enroll"])
                }
              }

              PanelSeparator { foreground: root.foreground }

              ActionRow {
                width: parent.width
                section: "pam-forget"
                icon: "󰩹"
                title: "Undo everything on this page"
                description: "Removes every registered credential and takes pam_u2f back out of all four stacks. SSH keys and disk enrollments are left alone — those are removed where they were made."
                trailingColor: root.urgent
                onActivated: root.runTerm(["pam-forget"])
              }
            }

            // ================================================ ACCOUNTS ====
            Column {
              width: parent.width
              spacing: Style.space(20)
              visible: root.tab === "accounts"

              Column {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  text: "Signing into your accounts"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  text: "There are two ways an account can use this key, and most providers offer both.\n\nAs a security key or passkey, the registration happens in the browser on the provider's own page — no desktop can do it for you, so the list further down goes straight to the right settings page for each one.\n\nAs an authenticator, the provider shows you a secret and the key stores it. That part lives here: codes are generated from the key itself, so they survive a reinstall and never sit in a phone app."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }

              // ---- add ----------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader { text: "Add an authenticator account"; foreground: root.foreground; fontFamily: root.fontFamily }

                ActionRow {
                  width: parent.width
                  section: "oath-scan"
                  icon: "󰐮"
                  title: "Scan the QR code off the screen"
                  description: "Drag a box around the QR code the provider is showing and the account is added from it. Far less error-prone than copying a base32 secret by hand."
                  enabledLook: !root.oath.locked
                  onActivated: root.runTerm(["oath-scan"])
                }

                Text {
                  text: "Or type it in — providers always offer the secret as text behind a “can't scan the code?” link."
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  TextField {
                    id: issuerField
                    width: (parent.width - Style.space(8)) * 0.4
                    placeholderText: "Issuer (Google)"
                    foreground: root.foreground
                    accent: root.accent
                    font.family: root.fontFamily
                    text: root.newIssuer
                    hasCursor: root.focusSection === "oath-issuer"
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                    onTextChanged: root.newIssuer = text
                    onHoveredChanged: if (hovered) root.focusSection = "oath-issuer"
                  }
                  TextField {
                    id: nameField
                    width: (parent.width - Style.space(8)) * 0.6
                    placeholderText: "Account (you@gmail.com)"
                    foreground: root.foreground
                    accent: root.accent
                    font.family: root.fontFamily
                    text: root.newName
                    hasCursor: root.focusSection === "oath-name"
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                    onTextChanged: root.newName = text
                    onHoveredChanged: if (hovered) root.focusSection = "oath-name"
                  }
                }

                TextField {
                  id: secretField
                  width: parent.width
                  placeholderText: "Base32 secret from the provider"
                  password: true
                  foreground: root.foreground
                  accent: root.accent
                  font.family: root.fontFamily
                  text: root.newSecret
                  hasCursor: root.focusSection === "oath-secret"
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                  onTextChanged: root.newSecret = text
                  onHoveredChanged: if (hovered) root.focusSection = "oath-secret"
                  onAccepted: root.submitAccount()
                }

                Toggle {
                  width: parent.width
                  label: "Require a touch for this account"
                  description: "Reading a code then needs the key physically touched. Malware on this machine cannot pull codes in the background."
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  checked: root.newTouch
                  hasCursor: root.focusSection === "oath-touch"
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                  onHovered: function(h) { if (h) root.focusSection = "oath-touch" }
                  onClicked: { root.focusSection = "oath-touch"; root.newTouch = !root.newTouch }
                }

                Button {
                  text: "Add to the key"
                  iconText: "󰐕"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  hasCursor: root.focusSection === "oath-add"
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                  onHovered: function(h) { if (h) root.focusSection = "oath-add" }
                  onClicked: { root.focusSection = "oath-add"; root.submitAccount() }
                }
              }

              // ---- stored accounts ----------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader { text: "On the key"; foreground: root.foreground; fontFamily: root.fontFamily }

                Text {
                  text: root.oath.locked
                    ? "The OATH applet is password protected. Unlock it with `ykman oath access` in a terminal, then refresh."
                    : ((root.oath.accounts && root.oath.accounts.length > 0)
                        ? "Pick one to put its current code on the clipboard — it is cleared after one paste. Click ✕ to remove an account."
                        : "No accounts stored yet.")
                  color: root.oath.locked ? root.urgent : root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: root.oath.accounts || []
                  delegate: Row {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(8)

                    ActionRow {
                      width: parent.width - deleteButton.width - Style.space(8)
                      section: "oath:" + modelData.id
                      icon: "󰥔"
                      title: modelData.name
                      description: modelData.issuer.length > 0 ? modelData.issuer : ""
                      trailing: "Copy code"
                      onActivated: root.generateCode(modelData.id)
                    }

                    Button {
                      id: deleteButton
                      iconText: "󰩹"
                      bordered: true
                      foreground: root.urgent
                      accent: root.urgent
                      fontFamily: root.fontFamily
                      tooltipText: "Delete this account from the key"
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.deleteAccount(modelData.id)
                    }
                  }
                }
              }

              // ---- providers ----------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader { text: "Register as a security key"; foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: "These open the page where each provider adds a security key or passkey. Have the key plugged in first — the browser asks for a touch partway through."
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: root.providers
                  delegate: ActionRow {
                    required property var modelData
                    width: parent.width
                    section: "prov:" + modelData.id
                    icon: modelData.icon
                    title: modelData.name
                    description: modelData.note
                    trailing: "Open ↗"
                    onActivated: root.openUrl(modelData.url)
                  }
                }
              }
            }

            // =================================================== SETUP ====
            Column {
              width: parent.width
              spacing: Style.space(20)
              visible: root.tab === "setup"

              Column {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  text: root.deps.missing > 0
                    ? root.deps.missing + " of " + (root.deps.deps ? root.deps.deps.length : 0) + " supporting packages are missing"
                    : "Everything this plugin needs is installed"
                  color: root.deps.missing > 0 ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  text: "None of these ship with Omarchy. Each one backs a specific page here, so a missing package shows up as a page that cannot do its job rather than an error."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }

              ActionRow {
                width: parent.width
                section: "install-deps"
                icon: "󰏔"
                title: root.deps.missing > 0 ? "Install what is missing" : "Re-check and repair"
                description: "Opens a terminal, installs the packages through omarchy-pkg-add, and enables pcscd.socket. You will be asked for your password."
                trailing: root.deps.missing > 0 ? root.deps.missing + " missing" : "All present"
                trailingColor: root.deps.missing > 0 ? root.urgent : root.accent
                onActivated: root.runTerm(["install-deps"])
              }

              Column {
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader { text: "Packages"; foreground: root.foreground; fontFamily: root.fontFamily }

                Repeater {
                  model: root.deps.deps || []
                  delegate: Row {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(10)

                    Text {
                      text: modelData.present ? "󰄬" : "󰅖"
                      color: modelData.present ? root.accent : root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      width: 18
                      horizontalAlignment: Text.AlignHCenter
                    }

                    Column {
                      width: parent.width - 28
                      spacing: Style.space(1)

                      Text {
                        text: modelData.pkg
                        color: modelData.present ? root.foreground : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      Text {
                        text: modelData.why
                        color: root.dimmer
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        width: parent.width
                        wrapMode: Text.WordWrap
                      }
                    }
                  }
                }
              }

              PanelSeparator { foreground: root.foreground }

              Column {
                width: parent.width
                spacing: Style.space(4)

                PanelSectionHeader { text: "Smartcard daemon"; foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: root.deps.pcscdRunning
                    ? "pcscd.socket is active. The PIV and OpenPGP applets are reachable."
                    : "pcscd.socket is not active. The PIV and OpenPGP applets will not answer until it is — the install above enables it."
                  color: root.deps.pcscdRunning ? root.dim : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(4)

                PanelSectionHeader { text: "From a terminal"; foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: "Everything this panel does is a subcommand of the script it ships with. `omarchy-yubikey doctor` prints the whole picture, and `omarchy-yubikey --help` lists the rest."
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }
            }

            // Bottom breathing room so the last row is not flush with the edge.
            Item { width: parent.width; height: Style.space(8) }
          }
        }
      }

      // ---- confirmation ----------------------------------------------------
      //
      // Only the two directions that destroy something reach this: switching an
      // applet off, and deleting a stored account. Everything more dangerous
      // than that is a terminal prompt instead.
      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        property var action: null
        background: root.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onConfirmed: {
          opened = false
          if (action) { action(); action = null }
        }
        onCanceled: { opened = false; action = null }
      }
    }
  }
}
