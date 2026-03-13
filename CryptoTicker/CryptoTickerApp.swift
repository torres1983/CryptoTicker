import SwiftUI
import AppKit

@main
struct CryptoTickerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 隐藏默认窗口，充当后台运行的“隐形占位符”
        Settings {
            EmptyView()
        }
    }
}

// MARK: - 设置面板 UI
struct SettingsView: View {
    // 默认把 SOLUSDT 放在第一位，它将成为状态栏的初始常驻显示
    @AppStorage("trackedSymbols") var trackedSymbols: String = "SOLUSDT,BTCUSDT,ETHUSDT"

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 10) {
                Text("关注的加密货币 (以逗号分隔):")
                    .font(.headline)
                
                TextField("例如: SOLUSDT,BTCUSDT", text: $trackedSymbols)
                    .textFieldStyle(.roundedBorder)
                
                Text("📌 列表的【第一个币种】将固定显示在状态栏上。")
                    .font(.caption)
                    .foregroundColor(.blue)
                Text("💡 提示：你可以直接点击状态栏下拉菜单中的币种将其置顶。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 400, height: 140)
    }
}

// MARK: - 核心逻辑
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    
    var cachedPrices: [String: Double] = [:]
    var previousPrices: [String: Double] = [:]
    var settingsWindow: NSWindow?

    // 获取当前关注的币种列表
    var symbols: [String] {
        let saved = UserDefaults.standard.string(forKey: "trackedSymbols") ?? "SOLUSDT,BTCUSDT,ETHUSDT"
        let list = saved.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty }
        return list.isEmpty ? ["SOLUSDT"] : list
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bitcoinsign.circle", accessibilityDescription: "Crypto")
            button.imagePosition = .imageLeft
        }
        
        statusItem.menu = NSMenu()
        updateMenu()
        startPolling()
        
        // 监听设置变化（包括在菜单里点击置顶后触发的变化）
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc func settingsChanged() {
        // 设置或顺序发生改变时，立即重新渲染菜单并获取最新价格
        updateMenu()
        Task { fetchPrice() }
    }

    // MARK: - 菜单与点击事件
    func updateMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        
        let titleItem = NSMenuItem(title: "实时永续合约价格 (点击置顶)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())
        
        let currentSymbols = symbols
        
        for (index, symbol) in currentSymbols.enumerated() {
            let coinName = symbol.replacingOccurrences(of: "USDT", with: "")
            
            // 为每个币种创建一个可点击的菜单项，绑定 pinSymbol 方法
            let menuItem = NSMenuItem(title: "", action: #selector(pinSymbol(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = symbol // 把币种名称存进菜单项里，方便点击时读取
            
            // 如果是第一个币种（即当前状态栏显示的币），加个小星星标识
            let prefix = (index == 0) ? "★ " : "    "
            
            if let price = cachedPrices[symbol] {
                // 应用涨跌颜色
                menuItem.attributedTitle = createAttributedTitle(symbol: symbol, coinName: prefix + coinName, price: price)
            } else {
                menuItem.title = "\(prefix)\(coinName): 获取中..."
            }
            menu.addItem(menuItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "设置 (Preferences)...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 CryptoTicker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // 点击菜单项将其置顶的方法
    @objc func pinSymbol(_ sender: NSMenuItem) {
        guard let clickedSymbol = sender.representedObject as? String else { return }
        
        var currentSymbols = self.symbols
        
        // 如果点击的已经是第一个，就不做处理
        if currentSymbols.first == clickedSymbol { return }
        
        // 将点击的币种从原位置移除，并插入到数组的最前面
        if let index = currentSymbols.firstIndex(of: clickedSymbol) {
            currentSymbols.remove(at: index)
            currentSymbols.insert(clickedSymbol, at: 0)
            
            // 将新的顺序写回 UserDefaults。
            // 这会自动触发我们上面写的 UserDefaults.didChangeNotification 监听器，进而刷新所有 UI。
            let newTrackedSymbols = currentSymbols.joined(separator: ",")
            UserDefaults.standard.set(newTrackedSymbols, forKey: "trackedSymbols")
        }
    }

    // MARK: - 窗口与网络请求
    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "CryptoTicker 设置"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            self.settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func startPolling() {
        fetchPrice()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.fetchPrice()
        }
    }

    func fetchPrice() {
        let currentSymbols = symbols
        guard !currentSymbols.isEmpty else { return }
        guard let primarySymbol = currentSymbols.first else { return }
        
        let urlString = "https://fapi.binance.com/fapi/v1/ticker/price"
        guard let url = URL(string: urlString) else { return }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                
                await MainActor.run {
                    if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        
                        // 1. 批量更新所有关注币种的缓存
                        for item in jsonArray {
                            if let sym = item["symbol"] as? String,
                               let priceStr = item["price"] as? String,
                               let price = Double(priceStr),
                               currentSymbols.contains(sym) {
                                
                                if let oldPrice = self.cachedPrices[sym] {
                                    self.previousPrices[sym] = oldPrice
                                }
                                self.cachedPrices[sym] = price
                            }
                        }
                        
                        // 2. 更新状态栏的主显示币种
                        let coinName = primarySymbol.replacingOccurrences(of: "USDT", with: "")
                        if let price = self.cachedPrices[primarySymbol] {
                            let coloredText = self.createAttributedTitle(symbol: primarySymbol, coinName: coinName, price: price)
                            self.statusItem.button?.attributedTitle = coloredText
                        } else {
                            self.statusItem.button?.title = "\(coinName): 无效数据"
                        }
                        
                        // 3. 刷新下拉菜单
                        self.updateMenu()
                        
                    } else {
                        self.statusItem.button?.title = "解析失败"
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusItem.button?.title = "网络超时"
                }
            }
        }
    }
    
    // 生成带有涨跌颜色的富文本
    func createAttributedTitle(symbol: String, coinName: String, price: Double) -> NSAttributedString {
        let formattedPrice = formatPrice(price)
        let text = "\(coinName): $\(formattedPrice)"
        
        var color: NSColor = .labelColor
        if let prevPrice = previousPrices[symbol] {
            if price > prevPrice {
                color = .systemGreen
            } else if price < prevPrice {
                color = .systemRed
            }
        }
        
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.menuBarFont(ofSize: 0)
        ]
        
        return NSAttributedString(string: text, attributes: attributes)
    }

    func formatPrice(_ price: Double) -> String {
        if price >= 1000 {
            return String(format: "%.0f", price)
        } else if price >= 1 {
            return String(format: "%.2f", price)
        } else {
            return String(format: "%.4f", price)
        }
    }
}
