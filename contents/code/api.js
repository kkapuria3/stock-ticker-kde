.pragma library

/**
 * Shared state across all widget instances in the same plasmashell process.
 * Because of `.pragma library`, multiple instances of the Stock Ticker widget
 * on the user's panels share this singleton module, deduplicating and batching
 * all symbols into a single network request!
 */

const DISPLAY_NAMES = {
    "^IXIC": "NASDAQ",
    "^GSPC": "S&P 500",
    "^RUT": "RUSSELL",
    "^DJI": "DOW"
};

function getDisplayName(symbol, shortName) {
    if (DISPLAY_NAMES[symbol]) {
        return DISPLAY_NAMES[symbol];
    }
    return symbol;
}

// Active widget instances: Map of instanceId -> { symbols: [...], callback: fn }
var registeredInstances = {};
// Shared quote cache: Map of symbol -> quoteObject
var quoteCache = {};
var isFetching = false;
var fetchStartedTimestamp = 0;
var lastFetchTimestamp = 0;
var minFetchGapMs = 1500;
var requestTimeoutMs = 10000; // Watchdog timeout so a hung socket never blocks future updates

/**
 * Register or update a widget instance's symbols and listener callback.
 */
function registerInstance(instanceId, symbols, callback) {
    const cleanSymbols = (Array.isArray(symbols) ? symbols : String(symbols).split(","))
        .map(function(s) { return s.trim().toUpperCase(); })
        .filter(function(s) { return s.length > 0; });

    registeredInstances[instanceId] = {
        symbols: cleanSymbols,
        callback: callback
    };

    // Immediately deliver cached data if we already have it
    deliverCachedToInstance(instanceId);
}

/**
 * Unregister a widget instance when destroyed.
 */
function unregisterInstance(instanceId) {
    delete registeredInstances[instanceId];
}

/**
 * Deliver cached quote objects to a specific instance in its configured symbol order.
 */
function deliverCachedToInstance(instanceId) {
    const entry = registeredInstances[instanceId];
    if (!entry || typeof entry.callback !== "function") return;

    const results = [];
    for (let i = 0; i < entry.symbols.length; i++) {
        const sym = entry.symbols[i];
        if (quoteCache[sym]) {
            // Shallow copy so QML always detects a fresh object reference
            const q = quoteCache[sym];
            results.push({
                symbol: q.symbol,
                displayName: q.displayName,
                regularMarketPrice: q.regularMarketPrice,
                regularMarketChange: q.regularMarketChange,
                regularMarketChangePercent: q.regularMarketChangePercent,
                currency: q.currency
            });
        }
    }
    if (results.length > 0) {
        entry.callback(results);
    }
}

/**
 * Broadcast updated cache to all registered widget instances.
 */
function notifyAllInstances() {
    for (const instanceId in registeredInstances) {
        deliverCachedToInstance(instanceId);
    }
}

/**
 * Collect the deduplicated union of all symbols across all active widget instances.
 */
function getAllUniqueSymbols() {
    const seen = {};
    const list = [];
    for (const instanceId in registeredInstances) {
        const syms = registeredInstances[instanceId].symbols || [];
        for (let i = 0; i < syms.length; i++) {
            const s = syms[i];
            if (!seen[s]) {
                seen[s] = true;
                list.push(s);
            }
        }
    }
    return list;
}

/**
 * Extract the most up-to-date market price from a response item.
 * In Yahoo Finance's spark endpoint, `meta.regularMarketPrice` can sometimes lag,
 * whereas the last non-null value in `indicators.quote[0].close` has the latest intraday tick.
 */
function extractLatestPrice(respItem, meta) {
    try {
        if (respItem && respItem.indicators && respItem.indicators.quote && respItem.indicators.quote.length > 0) {
            const closes = respItem.indicators.quote[0].close;
            if (Array.isArray(closes)) {
                for (let i = closes.length - 1; i >= 0; i--) {
                    if (closes[i] !== null && closes[i] !== undefined && !isNaN(closes[i])) {
                        return Number(closes[i]);
                    }
                }
            }
        }
    } catch (e) {
        // Fallback to meta
    }
    return (meta && meta.regularMarketPrice !== undefined) ? Number(meta.regularMarketPrice) : 0;
}

/**
 * Parse a Yahoo Finance chart/spark response object into a normalized quote object.
 */
function parseRespToQuote(respItem, fallbackSymbol) {
    if (!respItem || !respItem.meta) return null;
    const meta = respItem.meta;
    const sym = (meta.symbol || fallbackSymbol || "").toUpperCase();
    const price = (meta.regularMarketPrice !== undefined && meta.regularMarketPrice > 0)
        ? Number(meta.regularMarketPrice)
        : extractLatestPrice(respItem, meta);
    const prevClose = Number(meta.chartPreviousClose || meta.previousClose || price);
    const change = price - prevClose;
    const changePercent = prevClose !== 0 ? (change / prevClose) * 100 : 0;

    return {
        symbol: sym,
        displayName: getDisplayName(sym, meta.shortName),
        regularMarketPrice: price,
        regularMarketChange: change,
        regularMarketChangePercent: changePercent,
        currency: meta.currency || "USD"
    };
}

/**
 * Fallback single-symbol chart fetch if spark endpoint fails.
 */
function fetchChartFallback(symbols, cacheBuster, onComplete) {
    if (!symbols || symbols.length === 0) {
        onComplete();
        return;
    }

    let completed = 0;
    let finished = false;

    function checkDone() {
        if (!finished && completed >= symbols.length) {
            finished = true;
            onComplete();
        }
    }

    for (let i = 0; i < symbols.length; i++) {
        (function(sym) {
            const url = "https://query1.finance.yahoo.com/v8/finance/chart/" + encodeURIComponent(sym) + "?range=1d&interval=1m&_t=" + cacheBuster;
            const xhr = new XMLHttpRequest();
            xhr.timeout = 8000;
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    if (xhr.status === 200) {
                        try {
                            const data = JSON.parse(xhr.responseText);
                            if (data.chart && data.chart.result && data.chart.result.length > 0) {
                                const q = parseRespToQuote(data.chart.result[0], sym);
                                if (q) quoteCache[sym] = q;
                            }
                        } catch (e) {
                            console.error("StockTicker: Chart parse error for", sym, e);
                        }
                    }
                    completed++;
                    checkDone();
                }
            };
            xhr.ontimeout = function() {
                completed++;
                checkDone();
            };
            xhr.onerror = function() {
                completed++;
                checkDone();
            };
            xhr.open("GET", url);
            xhr.setRequestHeader("User-Agent", "Mozilla/5.0 (X11; Linux x86_64)");
            xhr.setRequestHeader("Cache-Control", "no-cache, no-store, must-revalidate");
            xhr.setRequestHeader("Pragma", "no-cache");
            xhr.send();
        })(symbols[i]);
    }
}

/**
 * Fetches all unique symbols across all widget instances in ONE single batch HTTP call
 * using Yahoo Finance's `/v7/finance/spark` endpoint.
 */
function refreshAllInstances(force) {
    const allSymbols = getAllUniqueSymbols();
    if (allSymbols.length === 0) return;

    const now = Date.now();

    // Watchdog: If a previous fetch got stuck (e.g. across system sleep/wake or network drop)
    // for more than requestTimeoutMs (10s), forcibly unlock isFetching so we never hang!
    if (isFetching) {
        if ((now - fetchStartedTimestamp) > requestTimeoutMs) {
            console.warn("StockTicker: Previous request timed out, resetting fetch lock.");
            isFetching = false;
        } else {
            return;
        }
    }

    if (!force && (now - lastFetchTimestamp) < minFetchGapMs) {
        notifyAllInstances();
        return;
    }

    isFetching = true;
    fetchStartedTimestamp = now;
    lastFetchTimestamp = now;

    // Append `&_t=` cache-buster so Qt's QNetworkAccessManager & Yahoo CDN never serve cached HTTP responses
    // Use `interval=1m` for the freshest 1-minute resolution quotes
    const encodedSymbols = allSymbols.map(function(s) { return encodeURIComponent(s); }).join(",");
    const url = "https://query1.finance.yahoo.com/v7/finance/spark?symbols=" + encodedSymbols
        + "&range=1d&interval=1m&indicators=close&includeTimestamps=false&includePrePost=false&_t=" + now;

    const xhr = new XMLHttpRequest();
    xhr.timeout = 8000;

    let handled = false;
    function finishFetch() {
        if (handled) return;
        handled = true;
        isFetching = false;
        notifyAllInstances();
    }

    xhr.ontimeout = function() {
        console.warn("StockTicker: Spark batch request timed out.");
        finishFetch();
    };

    xhr.onerror = function() {
        console.warn("StockTicker: Spark batch network error.");
        finishFetch();
    };

    xhr.onreadystatechange = function() {
        if (xhr.readyState === XMLHttpRequest.DONE) {
            if (handled) return;

            if (xhr.status === 200) {
                try {
                    const data = JSON.parse(xhr.responseText);
                    const results = (data.spark && data.spark.result) ? data.spark.result : [];
                    let parsedCount = 0;

                    for (let i = 0; i < results.length; i++) {
                        const item = results[i];
                        const sym = (item.symbol || "").toUpperCase();
                        const resp = (item.response && item.response.length > 0) ? item.response[0] : null;
                        if (resp && resp.meta) {
                            const quote = parseRespToQuote(resp, sym);
                            if (quote) {
                                quoteCache[sym] = quote;
                                parsedCount++;
                            }
                        }
                    }

                    if (parsedCount > 0) {
                        finishFetch();
                        return;
                    }
                } catch (e) {
                    console.error("StockTicker: Spark batch parse error:", e);
                }
            }

            // Fallback to v8/finance/chart if spark returned non-200 or empty
            fetchChartFallback(allSymbols, now, function() {
                finishFetch();
            });
        }
    };

    xhr.open("GET", url);
    xhr.setRequestHeader("User-Agent", "Mozilla/5.0 (X11; Linux x86_64)");
    xhr.setRequestHeader("Cache-Control", "no-cache, no-store, must-revalidate");
    xhr.setRequestHeader("Pragma", "no-cache");
    xhr.send();
}
