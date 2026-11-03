import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/api.js" as Api

PlasmoidItem {
    id: root

    // Render directly inline inside the panel (no popup dialog)
    preferredRepresentation: fullRepresentation

    // Unique instance ID so multiple widgets on panels share the Api.js singleton cleanly
    readonly property string instanceId: "instance_" + String(Plasmoid.id || Math.random())

    // List of quote objects for this widget instance
    property var stockData: []
    // Estimate of one full ticker strip width in pixels (used by Carousel mode without restarting on price ticks)
    property real stripEstimatedWidth: 0

    readonly property string configuredSymbols: {
        const s = (Plasmoid.configuration.symbols || "").trim();
        return s.length > 0 ? s : "^IXIC,^GSPC,^RUT,^DJI";
    }
    readonly property bool hasData: stockData.length > 0

    // Display Mode: 0 = Auto-fit all tickers side-by-side, 1 = Carousel news ticker tape
    readonly property int displayMode: Plasmoid.configuration.displayMode || 0
    readonly property bool isCarouselMode: displayMode === 1
    readonly property int carouselWidth: Math.max(100, Plasmoid.configuration.carouselWidth || 360)
    readonly property int carouselSpeed: Math.max(15, Plasmoid.configuration.carouselSpeed || 50)

    Plasmoid.icon: "org.kde.plasma.stockticker"
    Plasmoid.title: i18n("Stock Ticker")

    toolTipMainText: i18n("Market Quotes (Click to Refresh)")
    toolTipSubText: {
        if (!root.hasData) {
            return i18n("Fetching market data...");
        }
        return root.stockData.map(function(s) {
            const name = s.displayName || s.symbol;
            const price = Number(s.regularMarketPrice).toFixed(2);
            const change = Number(s.regularMarketChangePercent || 0).toFixed(2);
            const sign = Number(change) >= 0 ? "+" : "";
            return `${name} (${s.symbol}): ${price} (${sign}${change}%)`;
        }).join("\n");
    }

    // Register this instance with the shared singleton API manager
    function syncWithApi(forceRefresh) {
        Api.registerInstance(root.instanceId, root.configuredSymbols, function(results) {
            root.stockData = results || [];
        });
        Api.refreshAllInstances(forceRefresh);
    }

    Component.onCompleted: {
        syncWithApi(false);
    }

    Component.onDestruction: {
        Api.unregisterInstance(root.instanceId);
    }

    // Refresh data every N seconds (default 5s).
    // If multiple widget instances exist, Api.refreshAllInstances deduplicates
    // requests so they share a single batched HTTP call.
    Timer {
        id: refreshTimer
        interval: Math.max(2, Plasmoid.configuration.updateInterval || 5) * 1000
        running: true
        repeat: true
        onTriggered: {
            Api.refreshAllInstances(false);
        }
    }

    Connections {
        target: Plasmoid.configuration
        function onSymbolsChanged() {
            syncWithApi(true);
        }
        function onUpdateIntervalChanged() {
            refreshTimer.restart();
        }
    }

    // Reusable component that lays out the full strip of all tickers side-by-side
    Component {
        id: tickerStripComponent

        Row {
            id: stripRow
            spacing: Kirigami.Units.largeSpacing

            Repeater {
                model: root.stockData

                delegate: Row {
                    id: singleTickerDelegate
                    spacing: Kirigami.Units.smallSpacing

                    readonly property bool isPositive: (modelData.regularMarketChangePercent || 0) >= 0

                    // Display Name / Symbol (e.g. NASDAQ, S&P 500, AAPL)
                    PlasmaComponents.Label {
                        text: modelData.displayName || modelData.symbol
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // Price (e.g. 18239.92)
                    PlasmaComponents.Label {
                        text: Number(modelData.regularMarketPrice).toFixed(2)
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // Percent Change (e.g. +1.25%)
                    PlasmaComponents.Label {
                        text: {
                            const pct = Number(modelData.regularMarketChangePercent || 0).toFixed(2);
                            return (singleTickerDelegate.isPositive ? "+" : "") + pct + "%";
                        }
                        color: singleTickerDelegate.isPositive
                            ? Kirigami.Theme.positiveTextColor
                            : Kirigami.Theme.negativeTextColor
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // Subtle separator dot between tickers
                    PlasmaComponents.Label {
                        visible: root.isCarouselMode || index < (root.stockData.length - 1)
                        text: "•"
                        opacity: 0.45
                        leftPadding: Kirigami.Units.smallSpacing
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    }

    fullRepresentation: Item {
        id: panelContainer

        // Mode 0 (Auto-fit): Dynamically expand panel slot to fit all tickers side-by-side
        // Mode 1 (Carousel): Use user-configured fixed width
        readonly property real targetWidth: {
            if (!root.hasData) {
                return loadingLabel.implicitWidth + Kirigami.Units.largeSpacing * 2;
            }
            if (root.isCarouselMode) {
                return root.carouselWidth;
            }
            return autoFitLoader.implicitWidth + Kirigami.Units.largeSpacing * 2;
        }

        Layout.minimumWidth: targetWidth
        Layout.preferredWidth: targetWidth
        Layout.maximumWidth: root.isCarouselMode ? root.carouselWidth : Number.POSITIVE_INFINITY
        Layout.fillHeight: true

        // Loading indicator before first quote batch arrives
        PlasmaComponents.Label {
            id: loadingLabel
            anchors.centerIn: parent
            visible: !root.hasData
            text: i18n("Loading quotes...")
            font.bold: true
            opacity: 0.7
        }

        // =====================================================================
        // MODE 0: Auto-Fit All Tickers Side-by-Side (Default)
        // =====================================================================
        Loader {
            id: autoFitLoader
            anchors.centerIn: parent
            active: root.hasData && !root.isCarouselMode
            visible: active
            sourceComponent: tickerStripComponent
        }

        // =====================================================================
        // MODE 1: Carousel / News Channel Ticker Tape (Configurable Width)
        // =====================================================================
        Item {
            id: carouselViewport
            anchors.fill: parent
            visible: root.hasData && root.isCarouselMode
            clip: true

            property real scrollOffset: 0
            readonly property real singleStripWidth: stripPrimary.implicitWidth + Kirigami.Units.largeSpacing

            // Smoothly step the marquee every 16ms (~60 FPS) without resetting when stockData updates every 5s!
            Timer {
                id: marqueeStepTimer
                interval: 16
                repeat: true
                running: carouselViewport.visible
                    && carouselViewport.singleStripWidth > 0
                    && !clickArea.containsMouse
                onTriggered: {
                    const step = (root.carouselSpeed * 16) / 1000.0;
                    let nextOffset = carouselViewport.scrollOffset - step;
                    if (carouselViewport.singleStripWidth > 0 && Math.abs(nextOffset) >= carouselViewport.singleStripWidth) {
                        nextOffset += carouselViewport.singleStripWidth;
                    }
                    carouselViewport.scrollOffset = nextOffset;
                }
            }

            // Two copies placed back-to-back create a seamless infinite news ticker loop
            Row {
                id: marqueeTrack
                x: carouselViewport.scrollOffset
                anchors.verticalCenter: parent.verticalCenter
                spacing: Kirigami.Units.largeSpacing

                Loader {
                    id: stripPrimary
                    active: root.hasData && root.isCarouselMode
                    sourceComponent: tickerStripComponent
                }

                Loader {
                    id: stripDuplicate
                    active: root.hasData && root.isCarouselMode
                    sourceComponent: tickerStripComponent
                }
            }
        }

        MouseArea {
            id: clickArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                Api.refreshAllInstances(true);
            }
        }
    }
}
