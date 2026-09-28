import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.hemanthlis.openvpn-split-tunnel"
  ipcTarget: "io.github.hemanthlis.openvpn-split-tunnel"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string helperPath: String(Qt.resolvedUrl("scripts/openvpn-widget")).replace(/^file:\/\//, "")
  readonly property string configDirectory: String(setting("configDirectory", "~/.config/openvpn"))
  readonly property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 10)) || 10)
  readonly property bool anyActive: activeProfileName !== ""

  property var profiles: []
  property string activeProfileName: ""
  property string editPath: ""
  property string editName: ""
  property string renamePath: ""
  property string renameText: ""
  property string usernameText: ""
  property string passwordText: ""
  property string message: ""
  property string errorMessage: ""
  property string actionKind: ""
  property string actionPath: ""
  property string actionInput: ""
  property bool connectAfterSave: false
  property string routingPath: ""
  property string routingName: ""
  property bool routingSplit: true
  property bool routingIgnoreServer: false
  property string routingRoutesText: ""
  property string routingDnsText: ""
  property bool routingLoaded: false

  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  function parseResult(raw) {
    try {
      return JSON.parse(String(raw || "{}"))
    } catch (error) {
      return { ok: false, error: "The OpenVPN backend returned invalid data" }
    }
  }

  function refresh() {
    if (listProcess.running) return
    listProcess.command = [helperPath, "list", "--config-dir", configDirectory]
    listProcess.running = true
  }

  function openCredentials(profile, thenConnect) {
    closeRename()
    closeRouting()
    editPath = profile.path
    editName = profile.name
    usernameText = ""
    passwordText = ""
    connectAfterSave = thenConnect === true
    Qt.callLater(function() { usernameField.forceActiveFocus() })
  }

  function closeCredentials() {
    editPath = ""
    editName = ""
    usernameText = ""
    passwordText = ""
    connectAfterSave = false
    if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openRouting(profile) {
    closeCredentials()
    closeRename()
    routingPath = profile.path
    routingName = profile.name
    routingLoaded = false
    errorMessage = ""
    if (routingProcess.running) return
    routingProcess.command = [helperPath, "get-routing", "--config", profile.path]
    routingProcess.running = true
  }

  function closeRouting() {
    routingPath = ""
    routingName = ""
    routingLoaded = false
    if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function saveRouting() {
    var payload = {
      mode: routingSplit ? "split" : "full",
      routes: routingRoutesText,
      ignoreServerRoutes: routingIgnoreServer,
      dnsDomains: routingDnsText
    }
    runAction("save-routing", routingPath, JSON.stringify(payload) + "\n")
  }

  function openRename(profile) {
    closeCredentials()
    closeRouting()
    renamePath = profile.path
    renameText = profile.name
    Qt.callLater(function() {
      profileNameField.forceActiveFocus()
      profileNameField.selectAll()
    })
  }

  function closeRename() {
    renamePath = ""
    renameText = ""
    if (opened && editPath === "") Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function saveRename() {
    var name = renameText.trim()
    if (name === "") {
      errorMessage = "Profile name is required"
      return
    }
    runAction("rename", renamePath, JSON.stringify({ name: name }) + "\n")
  }

  function runAction(kind, path, input) {
    if (actionProcess.running) return
    actionKind = kind
    actionPath = path
    actionInput = input || ""
    message = ""
    errorMessage = ""
    actionProcess.command = [helperPath, kind, "--config", path]
    actionProcess.running = true
  }

  function activate(profile) {
    if (!profile || actionProcess.running) return
    if (profile.active) runAction("disconnect", profile.path)
    else if (profile.hasCredentials) runAction("connect", profile.path)
    else openCredentials(profile, true)
  }

  function saveCredentials() {
    var username = usernameText.trim()
    var password = passwordText
    if (username === "" || password === "") {
      errorMessage = "Username and password are required"
      return
    }
    var payload = JSON.stringify({ username: username, password: password }) + "\n"
    usernameText = ""
    passwordText = ""
    runAction("save-credentials", editPath, payload)
  }

  onOpenedChanged: if (opened) refresh()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  Process {
    id: listProcess
    running: false
    command: []
    stdout: StdioCollector { id: listOutput; waitForEnd: true }
    stderr: StdioCollector { id: listError; waitForEnd: true }
    onExited: function(exitCode) {
      var result = root.parseResult(listOutput.text)
      if (exitCode === 0 && result.ok) {
        root.profiles = result.profiles || []
        root.activeProfileName = ""
        for (var index = 0; index < root.profiles.length; index++) {
          if (root.profiles[index].active) {
            root.activeProfileName = root.profiles[index].name
            break
          }
        }
        if (!result.directoryExists)
          root.errorMessage = "Configuration directory not found: " + result.directory
        else if (root.errorMessage.indexOf("Configuration directory not found:") === 0)
          root.errorMessage = ""
      } else {
        root.errorMessage = result.error || String(listError.text || "Could not load OpenVPN profiles").trim()
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector { id: actionOutput; waitForEnd: true }
    stderr: StdioCollector { id: actionError; waitForEnd: true }
    onStarted: {
      if (root.actionInput !== "") {
        write(root.actionInput)
        root.actionInput = ""
      }
    }
    onExited: function(exitCode) {
      var completedKind = root.actionKind
      var completedPath = root.actionPath
      var shouldConnect = completedKind === "save-credentials" && root.connectAfterSave
      var result = root.parseResult(actionOutput.text)
      root.actionKind = ""
      root.actionPath = ""
      if (exitCode === 0 && result.ok) {
        root.message = result.message || "Done"
        root.errorMessage = ""
        if (completedKind === "save-credentials") root.closeCredentials()
        if (completedKind === "rename") root.closeRename()
        if (completedKind === "save-routing" || completedKind === "reset-routing") root.closeRouting()
        if (shouldConnect) Qt.callLater(function() { root.runAction("connect", completedPath) })
        else root.refresh()
      } else {
        root.errorMessage = result.error || String(actionError.text || "OpenVPN action failed").trim()
        root.connectAfterSave = false
      }
    }
  }

  Process {
    id: routingProcess
    running: false
    command: []
    stdout: StdioCollector { id: routingOutput; waitForEnd: true }
    stderr: StdioCollector { id: routingError; waitForEnd: true }
    onExited: function(exitCode) {
      var result = root.parseResult(routingOutput.text)
      if (exitCode === 0 && result.ok) {
        var routing = result.routing || {}
        root.routingSplit = routing.mode !== "full"
        root.routingIgnoreServer = routing.ignoreServerRoutes === true
        root.routingRoutesText = (routing.routes || []).join(", ")
        root.routingDnsText = (routing.dnsDomains || []).join(", ")
        root.routingLoaded = true
      } else {
        root.errorMessage = result.error || String(routingError.text || "Could not load routing settings").trim()
        root.closeRouting()
      }
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: root.anyActive ? "󰖂" : "󰦝"
    active: root.anyActive
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(400))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editPath !== "" || root.renamePath !== "" || root.routingPath !== ""
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { if (text === "r" || text === "R") root.refresh() }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.anyActive ? root.activeProfileName : "OpenVPN"
            meta: root.anyActive ? "CONNECTED" : "DISCONNECTED"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: root.anyActive ? "󰖂" : "󰦝"
                color: root.anyActive ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            width: parent.width
            text: root.configDirectory
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          Text {
            visible: root.message !== "" || root.errorMessage !== ""
            width: parent.width
            text: root.errorMessage !== "" ? root.errorMessage : root.message
            color: root.errorMessage !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          PanelSectionHeader {
            text: "PROFILES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.profiles.length === 0 && root.errorMessage === ""
            width: parent.width
            text: "No .ovpn or .conf files found. Choose a directory in the widget settings."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.profiles

              CursorSurface {
                required property var modelData
                width: parent.width
                implicitHeight: profileRow.implicitHeight + Style.space(12)
                current: modelData.active
                foreground: root.foreground

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.activate(modelData)
                }

                RowLayout {
                  id: profileRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(8)

                  Text {
                    text: modelData.active ? "󰖂" : "󰦝"
                    color: modelData.active ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                    Layout.alignment: Qt.AlignVCenter
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)

                    Text {
                      Layout.fillWidth: true
                      text: modelData.name
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: modelData.active
                      elide: Text.ElideRight
                    }
                    Text {
                      Layout.fillWidth: true
                      text: (modelData.active ? "Connected" : (modelData.hasCredentials ? "Credentials saved" : "Credentials required"))
                        + " · " + (modelData.routingMode === "full" ? "Full tunnel" : "Split tunnel")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  PanelActionButton {
                    visible: !modelData.active
                    iconText: "󰍂"
                    tooltipText: "Connect"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.activate(modelData)
                  }

                  PanelActionButton {
                    iconText: "󰛳"
                    tooltipText: "Routing settings"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.openRouting(modelData)
                  }

                  PanelActionButton {
                    visible: !modelData.active
                    iconText: "󰏫"
                    tooltipText: "Rename profile"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.openRename(modelData)
                  }

                  PanelActionButton {
                    visible: !modelData.active
                    iconText: "󰌆"
                    tooltipText: "Edit keyring credentials"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.openCredentials(modelData, false)
                  }

                  PanelActionButton {
                    visible: !modelData.active && (modelData.imported || modelData.hasCredentials)
                    iconText: "󰆴"
                    tooltipText: "Forget profile and credentials"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.runAction("forget", modelData.path)
                  }

                  PanelActionButton {
                    visible: modelData.active
                    iconText: "󰍃"
                    tooltipText: "Disconnect"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.runAction("disconnect", modelData.path)
                  }
                }
              }
            }
          }

          Column {
            visible: root.renamePath !== ""
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { width: parent.width; foreground: root.foreground }
            PanelSectionHeader {
              text: "PROFILE NAME"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: profileNameField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Profile name"
              text: root.renameText
              onTextChanged: root.renameText = text
              onAccepted: root.saveRename()
              Keys.onEscapePressed: root.closeRename()
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Save name"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: !actionProcess.running
                onClicked: root.saveRename()
              }
              Button {
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.closeRename()
              }
            }
          }

          Column {
            visible: root.routingPath !== ""
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { width: parent.width; foreground: root.foreground }
            PanelSectionHeader {
              text: "ROUTING · " + root.routingName.toUpperCase()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: !root.routingLoaded
              width: parent.width
              text: "Loading…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Toggle {
              visible: root.routingLoaded
              width: parent.width
              label: "Split tunnel"
              description: root.routingSplit
                ? "Only VPN resources go through the tunnel. Internet traffic keeps using your normal connection."
                : "All traffic, including internet, goes through the VPN."
              checked: root.routingSplit
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.routingSplit = !root.routingSplit
            }

            Column {
              visible: root.routingLoaded && root.routingSplit
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: "VPN networks (CIDR, comma separated)"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: routingRoutesField
                width: parent.width
                foreground: root.foreground
                placeholderText: "10.0.0.0/8, 172.16.0.0/12"
                text: root.routingRoutesText
                onTextChanged: root.routingRoutesText = text
                onAccepted: routingDnsField.forceActiveFocus()
                Keys.onEscapePressed: root.closeRouting()
              }

              Toggle {
                width: parent.width
                label: "Ignore routes pushed by server"
                description: root.routingIgnoreServer
                  ? "Only the networks listed above use the VPN."
                  : "Networks the server pushes are added to the list above."
                checked: root.routingIgnoreServer
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.routingIgnoreServer = !root.routingIgnoreServer
              }

              Text {
                width: parent.width
                text: "Resolve these domains with VPN DNS (optional)"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: routingDnsField
                width: parent.width
                foreground: root.foreground
                placeholderText: "corp.internal, office.lan"
                text: root.routingDnsText
                onTextChanged: root.routingDnsText = text
                onAccepted: root.saveRouting()
                Keys.onEscapePressed: root.closeRouting()
              }
            }

            Row {
              visible: root.routingLoaded
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Save routing"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: !actionProcess.running
                onClicked: root.saveRouting()
              }
              Button {
                text: "Reset"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !actionProcess.running
                onClicked: root.runAction("reset-routing", root.routingPath)
              }
              Button {
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.closeRouting()
              }
            }
          }

          Column {
            visible: root.editPath !== ""
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { width: parent.width; foreground: root.foreground }
            PanelSectionHeader {
              text: "CREDENTIALS · " + root.editName.toUpperCase()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: usernameField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Username"
              text: root.usernameText
              onTextChanged: root.usernameText = text
              onAccepted: passwordField.forceActiveFocus()
              Keys.onEscapePressed: root.closeCredentials()
            }

            TextField {
              id: passwordField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Password"
              password: true
              text: root.passwordText
              onTextChanged: root.passwordText = text
              onAccepted: root.saveCredentials()
              Keys.onEscapePressed: root.closeCredentials()
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: root.connectAfterSave ? "Save and connect" : "Save to keyring"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: !actionProcess.running
                onClicked: root.saveCredentials()
              }
              Button {
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.closeCredentials()
              }
            }
          }
        }
      }
    }
  }
}
