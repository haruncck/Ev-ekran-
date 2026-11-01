// swift-tools-version: 5.6

// Swift Playgrounds app project (opens on iPad in Swift Playgrounds 4.x and on Mac in Xcode).
// "Ev Ekranı": shows the family home screen web app full screen and reads the Xiaomi LYWSD03MMC
// Bluetooth thermometer natively, handing each reading to the page.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Ev Ekrani",
    platforms: [
        .iOS("15.2")
    ],
    products: [
        .iOSApplication(
            name: "Ev Ekranı",
            targets: ["AppModule"],
            bundleIdentifier: "io.github.haruncck.evekrani",
            displayVersion: "2.1",
            bundleVersion: "3",
            appIcon: .placeholder(icon: .clock),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .bluetoothAlways(purposeString: "Evdeki Xiaomi sıcaklık ve nem sensörünü okumak için."),
                .microphone(purposeString: "Duman alarmı, kapı zili gibi sesleri tablette tanımak için. Ses kaydedilmez ve hiçbir yere gönderilmez."),
                .localNetwork(purposeString: "Evdeki TV ve akıllı cihazlara doğrudan bildirim ve komut göndermek için.")
            ],
            additionalInfoPlistContentFilePath: "InfoExtra.plist"
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "App"
        )
    ]
)
