import QtQuick
import Quickshell.Io
import qs.Ui

// Whether a YubiKey is plugged in, and a way into the panel.
//
// The check is inlined rather than delegated to the plugin's own script for two
// reasons: a bar widget is handed a `bar`, not its manifest, so it has no
// reliable way to find its sibling files; and this has to be cheap enough to
// run on a timer. `ykman list` spawns a Python interpreter and takes the better
// part of a second — reading idVendor out of sysfs costs nothing, needs no
// packages installed, and so keeps working before Setup has ever been run.
// 0x1050 is Yubico's USB vendor id.
BarWidget {
  id: root
  moduleName: "eusener.yubikey"

  property bool present: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: presence
    command: ["/bin/sh", "-c",
      "for v in /sys/bus/usb/devices/*/idVendor; do [ -r \"$v\" ] || continue; " +
      "[ \"$(cat \"$v\")\" = 1050 ] && { echo yes; exit 0; }; done; echo no"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.present = String(text || "").trim() === "yes"
    }
  }

  Timer {
    interval: 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!presence.running) presence.running = true
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.present ? "󰌆" : "󰌊"
    // Dimmed rather than hidden: a widget that vanishes when the key comes out
    // reads as a bar glitch, and "no key right now" is worth showing.
    dimmed: !root.present
    tooltipText: root.present ? "YubiKey connected" : "No YubiKey connected"
    onPressed: function(btn) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle eusener.yubikey '{}'")
    }
  }
}
