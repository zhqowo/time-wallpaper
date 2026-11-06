import Cocoa
import Foundation

// MARK: - 配置
var LAT = 29.87, LON = 121.55          // 由 IP 定位覆盖
var LOC_CITY = "宁波"
var lastLocateAt = Date(timeIntervalSince1970: 0)
let LOCATE_TTL: TimeInterval = 6 * 3600
var LANG_ZH: Bool = {
    if let v = UserDefaults.standard.object(forKey: "TimeWallpaperLang") as? Bool { return v }
    let langs = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
    return (langs.first ?? "en").hasPrefix("zh")
}()

func t(_ zh: String, _ en: String) -> String { LANG_ZH ? zh : en }
func phaseName(_ key: String) -> String {
    let zh = ["predawn":"凌晨","dawn":"黎明","sunrise":"日出","morning":"上午",
              "day":"正午","afternoon":"下午","dusk":"黄昏","bluehour":"暮色","night":"夜"]
    let en = ["predawn":"Pre-dawn","dawn":"Dawn","sunrise":"Sunrise","morning":"Morning",
              "day":"Midday","afternoon":"Afternoon","dusk":"Dusk","bluehour":"Blue hour","night":"Night"]
    return LANG_ZH ? (zh[key] ?? key) : (en[key] ?? key)
}
// 壁纸目录：优先读 UserDefaults 的 WallDir，否则 ~/Pictures/TimeWallpaper
var WALLDIR: String = {
    if let s = UserDefaults.standard.string(forKey: "WallDir") { return NSString(string: s).expandingTildeInPath }
    return NSString(string: "~/Pictures/TimeWallpaper").expandingTildeInPath
}()
let TICK: TimeInterval = 300          // 5 分钟
let WEATHER_TTL: TimeInterval = 1800  // 天气缓存 30 分钟

struct Wx { var ts = Date(timeIntervalSince1970: 0)
           var cloud = 100.0, precip = 0.0, temp = 15.0, vis = 20000.0, code = 3 }

// MARK: - 太阳高度（NOAA 简化式）
func solarAltitude(_ date: Date) -> Double {
    let cal = Calendar(identifier: .gregorian)
    var utc = cal; utc.timeZone = TimeZone(identifier: "UTC")!
    let doy = Double(utc.ordinality(of: .day, in: .year, for: date) ?? 1)
    let c = utc.dateComponents([.hour, .minute, .second], from: date)
    let hourUTC = Double(c.hour ?? 0) + Double(c.minute ?? 0)/60.0 + Double(c.second ?? 0)/3600.0
    let g = 2.0 * Double.pi / 365.0 * (doy - 1 + (hourUTC - 12) / 24.0)
    let decl = 0.006918 - 0.399912*cos(g) + 0.070257*sin(g) - 0.006758*cos(2*g)
             + 0.000907*sin(2*g) - 0.002697*cos(3*g) + 0.001480*sin(3*g)
    let eqtime = 229.18 * (0.000075 + 0.001868*cos(g) - 0.032077*sin(g)
             - 0.014615*cos(2*g) - 0.040849*sin(2*g))
    let tst = hourUTC * 60.0 + eqtime + 4.0 * LON
    let ha = (tst / 4.0 - 180.0) * Double.pi / 180.0
    let latR = LAT * Double.pi / 180.0
    let cosZ = sin(latR)*sin(decl) + cos(latR)*cos(decl)*cos(ha)
    return 90.0 - acos(max(-1, min(1, cosZ))) * 180.0 / Double.pi
}


// MARK: - 太阳事件（日出/日落/昼长），阈值取真实日出 -0.833°
func solarAltitudeRaw(_ date: Date) -> Double { solarAltitude(date) }

func solarEvents(_ day: Date) -> (rise: Date?, set: Date?, daylight: Double) {
    let cal = Calendar.current
    let start = cal.startOfDay(for: day)
    var prev = solarAltitudeRaw(start)
    var rise: Date? = nil, set: Date? = nil
    var ri = start, si = start
    for i in 1...(24*60) {
        let t = start.addingTimeInterval(Double(i) * 60)
        let a = solarAltitudeRaw(t)
        if prev < -0.833 && a >= -0.833 && rise == nil { rise = t; ri = t }
        if prev >= -0.833 && a < -0.833 && set == nil { set = t; si = t }
        prev = a
    }
    let dl = (rise != nil && set != nil) ? si.timeIntervalSince(ri) : 0
    return (rise, set, dl)
}

// MARK: - 天文季节（二分二至，而非自然月）
func seasonCNRaw() -> String {
    let cal = Calendar.current
    let m = cal.component(.month, from: Date())
    let d = cal.component(.day, from: Date())
    // 春分约 3/20，夏至 6/21，秋分 9/22，冬至 12/21
    if m == 3 && d >= 20 { return "spring" }
    if m == 4 || m == 5 { return "spring" }
    if m == 6 && d < 21 { return "spring" }
    if m == 6 && d >= 21 { return "summer" }
    if m == 7 || m == 8 { return "summer" }
    if m == 9 && d < 22 { return "summer" }
    if m == 9 && d >= 22 { return "autumn" }
    if m == 10 || m == 11 { return "autumn" }
    if m == 12 && d < 21 { return "autumn" }
    if m == 12 && d >= 21 { return "winter" }
    if m == 1 || m == 2 { return "winter" }
    if m == 3 && d < 20 { return "winter" }
    return "autumn"
}

func seasonCN() -> String {
    let base = seasonCNRaw()
    guard LAT < 0 else { return base }            // 南半球：月份对应翻转
    switch base {
    case "spring": return "autumn"
    case "summer": return "winter"
    case "autumn": return "spring"
    default:       return "summer"
    }
}

// MARK: - 月相（照度 0..1 与月龄），用于夜间是否出月出图
func moonPhase(_ date: Date) -> (illum: Double, age: Double) {
    let ref = Date(timeIntervalSince1970: 947182440)  // 2000-01-06 18:14 UTC 新月
    let days = date.timeIntervalSince(ref) / 86400.0
    let syn = 29.530588853
    var age = days.truncatingRemainder(dividingBy: syn)
    if age < 0 { age += syn }
    let illum = (1 - cos(2 * Double.pi * age / syn)) / 2
    return (illum, age)
}

func phase(_ alt: Double, _ rising: Bool) -> String {
    if rising {
        if alt < -18 { return "predawn" }      // 天文晨昏之前
        if alt < -6  { return "dawn" }         // 晨昏蒙影（民用-航海）
        if alt < 6   { return "sunrise" }      // 黄金时刻
        if alt < 25  { return "morning" }
        return "day"
    } else {
        if alt > 25  { return "day" }
        if alt > 6   { return "afternoon" }
        if alt > -0.833 { return "dusk" }      // 日落前后（黄金时刻）
        if alt > -6  { return "dusk" }         // 民用晨昏
        if alt > -18 { return "bluehour" }     // 航海/天文晨昏
        return "night"
    }
}



// MARK: - 选图
var lastRainAt: Date? = nil
var lastPickHour: Int = -1

func pick(_ now: Date, _ wx: Wx) -> (file: String, why: String) {
    let alt = solarAltitude(now)
    let alt2 = solarAltitude(now.addingTimeInterval(60))
    let ph = phase(alt, alt2 > alt)
    let hour = Calendar.current.component(.hour, from: now)
    let month = Calendar.current.component(.month, from: now)
    let season = seasonCN()

    if wx.precip > 0.05 { lastRainAt = now }

    // 夜
    if ph == "night" {
        let auroraSeason = [11, 12, 1, 2, 3].contains(month)
        if auroraSeason && wx.cloud < 35 { return ("sk_aurora", "夜·晴 云量\(Int(wx.cloud))% → 极光") }
        let mp = moonPhase(now)
        if mp.illum > 0.35 && wx.cloud < 60 && hour >= 21 && hour <= 23 {
            return ("sk_moonrise", "夜·云量\(Int(wx.cloud))% 月相\(Int(mp.illum*100))% → 月出") }
        return ("night", "夜 云量\(Int(wx.cloud))%")
    }
    if ph == "predawn" || ph == "bluehour" {
        return (ph == "predawn" ? "predawn" : "bluehour", "\(ph) 太阳\(Int(alt))°")
    }
    if ph == "dawn" {
        if wx.vis < 1500 { return ("w_fog", "黎明·能见度\(Int(wx.vis/1000))km → 雾") }
        if wx.cloud < 30 && wx.vis > 5000 && hour >= 4 && hour <= 8 {
            return ("wx_cloudsea", "黎明·晴+高湿 → 云海") }
        return ("dawn", "黎明 云量\(Int(wx.cloud))%")
    }

    // 黄昏 / 暮色
    if ph == "dusk" {
        if wx.precip > 0.05 || (lastRainAt != nil && now.timeIntervalSince(lastRainAt!) < 5400 && wx.cloud < 80) {
            return ("wx_rainbow", "黄昏·刚下过雨 → 双彩虹") }
        if wx.code >= 95 { return ("wx_storm", "黄昏·雷暴") }
        return ("dusk", "黄昏 云量\(Int(wx.cloud))%")
    }

    // 白天：特殊事件 → 天气 → 季节
    if month == 6 && (21...24).contains(Calendar.current.component(.day, from: now)) && hour >= 19 && hour <= 23 {
        return ("cu_midsummer", "仲夏夜 → 篝火") }
    if (month == 9 && Calendar.current.component(.day, from: now) >= 15) || month == 10 {
        if hour >= 10 && hour <= 17 && wx.cloud > 40 { return ("cu_harvest", "秋收 → 丰收") } }
    if wx.code >= 95 { return ("wx_storm", "雷暴 code\(wx.code)") }
    if wx.precip > 0.05 || wx.code >= 71 && wx.code <= 77 {
        if wx.temp <= 1.0 || (wx.code >= 71 && wx.code <= 77) { return ("w_snow", "降水·低温 → 雪") }
        return ("w_rain", "降水\(String(format: "%.1f", wx.precip))mm → 雨")
    }
    if wx.vis < 2000 { return ("w_fog", "能见度\(Int(wx.vis/1000))km → 雾") }
    if wx.cloud < 25 { return ("w_clear", "云量\(Int(wx.cloud))% → 晴") }
    if ph == "morning" { return ("morning", "上午 云量\(Int(wx.cloud))%") }
    if ph == "afternoon" { return ("afternoon", "下午 云量\(Int(wx.cloud))%") }
    return ("se_\(season)", "白天·\(season) 云量\(Int(wx.cloud))%")
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var wx = Wx()
    var current = "—"
    var locked: String? = nil
    var autoOn = true
    var infoItem: NSMenuItem!
    var wxItem: NSMenuItem!
    var sunItem: NSMenuItem!
    var locItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "mountain.2.fill", accessibilityDescription: "时间壁纸")
            b.image?.isTemplate = true
        }
        try? FileManager.default.createDirectory(atPath: WALLDIR, withIntermediateDirectories: true)
        rebuildMenu()
        locate { self.tick() }
        timer = Timer.scheduledTimer(withTimeInterval: TICK, repeats: true) { _ in self.tick() }
    }

    func tick() {
        if wx.ts.timeIntervalSinceNow < -WEATHER_TTL || wx.ts == Date(timeIntervalSince1970: 0) {
            if Date().timeIntervalSince(lastLocateAt) > LOCATE_TTL {
                locate { self.fetchWeather { self.apply() } }
            } else {
                fetchWeather { self.apply() }
            }
        } else { apply() }
    }

    func apply() {
        guard autoOn, locked == nil else { updateTitle(); return }
        let now = Date()
        let (base, why) = pick(now, wx)
        let file = seasonal(base)
        current = file
        setWallpaper(base)
        log("\(why) | 云\(Int(wx.cloud))% 雨\(String(format: "%.1f", wx.precip))mm 能见\(Int(wx.vis/1000))km \(Int(wx.temp))°C → \(file)")
        statusItem.button?.toolTip = "\(file) · \(why)"
        updateTitle()
    }

    let phaseCN = ["predawn":"凌晨","dawn":"黎明","sunrise":"日出","morning":"上午",
                   "day":"正午","afternoon":"下午","dusk":"黄昏","bluehour":"暮色","night":"夜"]

    func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let d = line.data(using: .utf8) {
            let u = URL(fileURLWithPath: "/tmp/timewallpaper-app.log")
            if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(d); try? h.close() }
            else { try? d.write(to: u) }
        }
    }

    /// 当前状态对应的 SF Symbol
    // 把 se_<季节>_<类型> 归一化回通用类型，供图标/回退判断使用
    func baseName(_ n: String) -> String {
        if n.hasPrefix("se_") {
            let p = n.split(separator: "_")
            if p.count == 3 { return "w_" + p[2] }
            return "day"
        }
        return n
    }

    func symbolName() -> String {
        if locked != nil { return "pin.fill" }
        if !autoOn { return "pause.circle.fill" }
        let f = baseName(current)
        if f.hasPrefix("w_rain") { return "cloud.rain.fill" }
        if f.hasPrefix("w_snow") { return "cloud.snow.fill" }
        if f.hasPrefix("w_fog") { return "cloud.fog.fill" }
        if f.hasPrefix("wx_storm") { return "cloud.bolt.rain.fill" }
        if f.hasPrefix("wx_rainbow") { return "cloud.sun.rain.fill" }
        if f.hasPrefix("wx_cloudsea") { return "cloud.fill" }
        if f.hasPrefix("sk_aurora") { return "sparkles" }
        if f.hasPrefix("sk_moonrise") { return "moon.fill" }
        if f.hasPrefix("cu_midsummer") { return "flame.fill" }
        if f.hasPrefix("cu_harvest") { return "leaf.fill" }
        if f == "predawn" || f == "night" { return "moon.stars.fill" }
        if f == "dawn" || f == "sunrise" { return "sunrise.fill" }
        if f == "dusk" || f == "bluehour" { return "sunset.fill" }
        if f.hasPrefix("se_") || f == "day" || f == "morning" || f == "afternoon" {
            return wx.cloud < 30 ? "sun.max.fill" : "cloud.sun.fill"
        }
        return "mountain.2.fill"
    }

    func updateTitle() {
        let btn = statusItem.button
        let name = symbolName()
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        btn?.image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(cfg)
        btn?.image?.isTemplate = true
        btn?.title = (locked != nil) ? "" : " "
        if locked != nil { btn?.title = " 🔒" }
        if !autoOn && locked == nil { btn?.title = " ⏸" }
        let now = Date()
        let alt = solarAltitude(now)
        let rising = solarAltitude(now.addingTimeInterval(60)) > alt
        let ph = phaseName(phase(alt, rising))
        btn?.toolTip = String(format: t("%@ · %@ · 云量%.0f%% %.1fmm %.0f°C","%@ · %@ · cloud %.0f%% %.1fmm %.0f°C"),
                              ph, current, wx.cloud, wx.precip, wx.temp)
    }

    func resolve(_ name: String) -> String? {
        func path(_ n: String) -> String? {
            for ext in ["png", "jpg"] {
                let p = "\(WALLDIR)/\(n).\(ext)"
                if FileManager.default.fileExists(atPath: p) { return p }
            }
            return nil
        }
        func has(_ n: String) -> Bool { path(n) != nil }
        if has(name) { return name }
        let alt = ["w_clear":"day","w_rain":"day","w_fog":"day","w_snow":"day",
                   "wx_rainbow":"dusk","wx_cloudsea":"dawn","wx_storm":"day",
                   "cu_harvest":"day","cu_midsummer":"dusk","sk_aurora":"night","sk_moonrise":"night",
                   "se_spring":"day","se_summer":"day","se_autumn":"day","se_winter":"day"]
        if let a = alt[name], has(a) { return a }
        return has("day") ? "day" : nil
    }

    // 季节优先：天气/特殊时段若有对应季节版本则优先使用（缺图自动回退通用版）
    func seasonal(_ name: String) -> String {
        let map = ["w_rain":"rain","w_fog":"fog","w_snow":"snow",
                   "night":"night","predawn":"predawn","dusk":"dusk",
                   "morning":"morning","afternoon":"afternoon",
                   "dawn":"dawn","sunrise":"sunrise","bluehour":"bluehour"]
        guard let k = map[name] else { return name }
        let cand = "se_\(seasonCN())_\(k)"
        return pathOf(cand) != nil ? cand : name
    }

    func pathOf(_ n: String) -> String? {
        for ext in ["png", "jpg"] {
            let p = "\(WALLDIR)/\(n).\(ext)"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    func setWallpaper(_ name: String) {
        let name = seasonal(name)
        guard let real = resolve(name), let fp = pathOf(real) else { return }
        let url = URL(fileURLWithPath: fp)
        for s in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: s, options: [:])
        }
    }

    // 用 IP 定位（无需授权，城市级精度足够算太阳高度与取天气）
    func locate(completion: @escaping () -> Void) {
        guard let url = URL(string: "https://ipwho.is/") else { completion(); return }
        var rq = URLRequest(url: url); rq.timeoutInterval = 10
        URLSession.shared.dataTask(with: rq) { d, _, _ in
            defer { DispatchQueue.main.async { completion() } }
            guard let d = d,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (j["success"] as? Bool ?? true),
                  let la = j["latitude"] as? Double, let lo = j["longitude"] as? Double else { return }
            LAT = la; LON = lo
            if let c = j["city"] as? String, !c.isEmpty { LOC_CITY = c }
            lastLocateAt = Date()
        }.resume()
    }

    func fetchWeather(completion: @escaping () -> Void) {
        let u = "https://api.open-meteo.com/v1/forecast?latitude=\(LAT)&longitude=\(LON)"
              + "&current=temperature_2m,precipitation,weather_code,cloud_cover,visibility&timezone=auto"
        guard let url = URL(string: u) else { completion(); return }
        URLSession.shared.dataTask(with: url) { d, _, _ in
            defer { DispatchQueue.main.async { completion() } }
            guard let d = d,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let cur = j["current"] as? [String: Any] else { return }
            var w = Wx(); w.ts = Date()
            w.cloud = (cur["cloud_cover"] as? Double) ?? 100
            w.precip = (cur["precipitation"] as? Double) ?? 0
            w.temp = (cur["temperature_2m"] as? Double) ?? 15
            w.vis = (cur["visibility"] as? Double) ?? 20000
            w.code = (cur["weather_code"] as? Int) ?? 3
            DispatchQueue.main.async { self.wx = w }
        }.resume()
    }

    func rebuildMenu() {
        let m = NSMenu()
        infoItem = NSMenuItem(title: t("当前：","Now: ") + current, action: nil, keyEquivalent: "")
        m.addItem(infoItem)
        wxItem = NSMenuItem(title: t("天气：—","Weather: —"), action: nil, keyEquivalent: "")
        m.addItem(wxItem)
        sunItem = NSMenuItem(title: t("天文：—","Astronomy: —"), action: nil, keyEquivalent: "")
        m.addItem(sunItem)
        locItem = NSMenuItem(title: t("定位：—","Location: —"), action: nil, keyEquivalent: "")
        m.addItem(locItem)
        m.delegate = self
        m.addItem(NSMenuItem.separator())
        m.addItem(NSMenuItem(title: t("立即刷新","Refresh now"), action: #selector(refresh), keyEquivalent: "r").with { $0.target = self })
        m.addItem(NSMenuItem(title: t("重新定位","Re-detect location"), action: #selector(relocate), keyEquivalent: "l").with { $0.target = self })
        let auto = NSMenuItem(title: t("自动切换","Auto switch"), action: #selector(toggleAuto), keyEquivalent: "")
        auto.state = autoOn ? .on : .off; auto.target = self
        m.addItem(auto)
        let lang = NSMenuItem(title: t("语言：中文 / English","Language: English / 中文"), action: #selector(toggleLang), keyEquivalent: "")
        lang.target = self
        m.addItem(lang)
        m.addItem(NSMenuItem.separator())

        let lockItem = NSMenuItem(title: t("手动锁定","Lock to…"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: WALLDIR)) ?? [])
            .filter { $0.hasSuffix(".png") || $0.hasSuffix(".jpg") }
            .filter { !$0.hasPrefix("_") }
            .sorted()
        for f in files {
            let it = NSMenuItem(title: (f as NSString).deletingPathExtension, action: #selector(lockTo(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = f; sub.addItem(it)
        }
        if files.isEmpty { sub.addItem(NSMenuItem(title: t("（图片目录为空）","(no images found)"), action: nil, keyEquivalent: "")) }
        lockItem.submenu = sub; m.addItem(lockItem)
        let unlock = NSMenuItem(title: t("解除锁定 / 回自动","Unlock / back to auto"), action: #selector(unlock), keyEquivalent: "")
        unlock.target = self; m.addItem(unlock)

        m.addItem(NSMenuItem.separator())
        m.addItem(NSMenuItem(title: t("打开图片文件夹","Open image folder"), action: #selector(openDir), keyEquivalent: "").with { $0.target = self })
        m.addItem(NSMenuItem(title: t("退出","Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let now = Date()
        let alt = solarAltitude(now)
        let rising = solarAltitude(now.addingTimeInterval(60)) > alt
        let ph = phaseName(phase(alt, rising))
        infoItem.title = t("当前：","Now: ") + "\(ph) · \(current)" + (locked != nil ? t("（已锁定）"," (locked)") : "")
        wxItem.title = String(format: t("天气：云量%3d%% 降水%.1fmm 能见度%dkm %.0f°C","Weather: cloud %3d%% rain %.1fmm vis %dkm %.0f°C"),
                              Int(wx.cloud), wx.precip, Int(wx.vis/1000), wx.temp)
        let ev = solarEvents(now)
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        let h = Int(ev.daylight/3600), mm = Int(ev.daylight.truncatingRemainder(dividingBy: 3600)/60)
        let mp = moonPhase(now)
        locItem.title = String(format: t("定位：%@ %.2f°N %.2f°E（IP 定位）","Location: %@ %.2f°N %.2f°E (IP-based)"), LOC_CITY, LAT, LON)
        let riseS = ev.rise.map{df.string(from:$0)} ?? "—"
        let setS  = ev.set.map{df.string(from:$0)} ?? "—"
        sunItem.title = LANG_ZH
            ? "天文：日出 \(riseS) · 日落 \(setS) · 昼长 \(h)h\(String(format:"%02d",mm))m · 月相 \(Int(mp.illum*100))%"
            : "Astronomy: sunrise \(riseS) · sunset \(setS) · daylight \(h)h\(String(format:"%02d",mm))m · moon \(Int(mp.illum*100))%"
    }

    @objc func refresh() { fetchWeather { self.rebuildMenu(); self.apply() } }
    @objc func relocate() { locate { self.fetchWeather { self.rebuildMenu(); self.apply() } } }
    @objc func toggleAuto() { autoOn.toggle(); rebuildMenu(); apply() }
    @objc func unlock() { locked = nil; rebuildMenu(); apply() }
    @objc func toggleLang() {
        LANG_ZH.toggle()
        UserDefaults.standard.set(LANG_ZH, forKey: "TimeWallpaperLang")
        rebuildMenu(); updateTitle()
    }
    @objc func lockTo(_ s: NSMenuItem) {
        guard let f = s.representedObject as? String else { return }
        locked = f; current = f; setWallpaper(f); rebuildMenu()
    }
    @objc func openDir() { NSWorkspace.shared.open(URL(fileURLWithPath: WALLDIR)) }
}

extension NSMenuItem { func with(_ f: (NSMenuItem) -> Void) -> NSMenuItem { f(self); return self } }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
