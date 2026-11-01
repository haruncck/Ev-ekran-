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
            displayVersion: "2.0",
            bundleVersion: "2",
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
                .microphone(purposeString: "Duman alarmı, kapı zili gibi sesleri tablette tanımak için. Ses kaydedilmez ve hiçbir yere gönderilmez.")
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "App"
        )
    ]
)
