import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: configPage

    property alias cfg_symbols: symbolsField.text
    property alias cfg_updateInterval: updateIntervalSpinBox.value
    property alias cfg_displayMode: displayModeCombo.currentIndex
    property alias cfg_carouselWidth: carouselWidthSpinBox.value
    property alias cfg_carouselSpeed: carouselSpeedSpinBox.value

    property string cfg_symbolsDefault: "^IXIC,^GSPC,^RUT,^DJI"
    property int cfg_updateIntervalDefault: 5
    property int cfg_displayModeDefault: 0
    property int cfg_carouselWidthDefault: 360
    property int cfg_carouselSpeedDefault: 50

    Kirigami.FormLayout {
        TextField {
            id: symbolsField
            Kirigami.FormData.label: i18n("Symbols (comma separated):")
            placeholderText: "^IXIC, ^GSPC, ^RUT, ^DJI, AAPL, BTC-USD"
            Layout.fillWidth: true
        }

        Label {
            text: i18n("Default Indices: ^IXIC (NASDAQ), ^GSPC (S&P 500), ^RUT (Russell 2000), ^DJI (Dow Jones)")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        SpinBox {
            id: updateIntervalSpinBox
            Kirigami.FormData.label: i18n("Refresh interval (seconds):")
            from: 2
            to: 3600
            stepSize: 1
            value: 5
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Layout & Display Mode")
        }

        ComboBox {
            id: displayModeCombo
            Kirigami.FormData.label: i18n("Display Mode:")
            model: [
                i18n("Auto-fit All Tickers (Side-by-Side)"),
                i18n("Carousel Ticker Tape (News Channel Style)")
            ]
            Layout.fillWidth: true
        }

        SpinBox {
            id: carouselWidthSpinBox
            visible: displayModeCombo.currentIndex === 1
            Kirigami.FormData.label: i18n("Widget Width (px):")
            from: 100
            to: 2000
            stepSize: 10
            value: 360
        }

        SpinBox {
            id: carouselSpeedSpinBox
            visible: displayModeCombo.currentIndex === 1
            Kirigami.FormData.label: i18n("Scroll Speed (px/sec):")
            from: 15
            to: 250
            stepSize: 5
            value: 50
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Notes & API Guidelines")
        }

        Kirigami.InlineMessage {
            visible: true
            type: Kirigami.MessageType.Information
            showCloseButton: false
            Layout.fillWidth: true
            text: i18n("<b>Recommended limits:</b> Up to <b>20 total unique symbols</b> across all widgets.<br>Multiple widgets on your panels automatically share a single batch request every refresh interval to prevent hitting rate limits.")
        }

        Label {
            text: i18n("• <b>Maximum Tickers:</b> The batch endpoint accepts up to <b>20 symbols</b> per request. If you configure more than 20 symbols, fallback single requests are used.<br>" +
                       "• <b>Multiple Widgets:</b> You can add multiple instances of this widget to different panels. All instances are synchronized and deduplicated into a single API call.<br>" +
                       "• <b>Rate Limits:</b> At 5-second intervals, the widget makes ~720 calls/hour (well below Yahoo Finance's ~2,000 requests/hour IP threshold).")
            font: Kirigami.Theme.smallFont
            textFormat: Text.RichText
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            opacity: 0.85
        }
    }
}
