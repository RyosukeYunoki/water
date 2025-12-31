import SwiftUI
import UserNotifications
import GoogleMobileAds
import StoreKit // ★追加: レビュー機能用

// MARK: - Data Management

// 設定可能な目標値を管理するクラス
class GoalManager: ObservableObject {
    static let shared = GoalManager()
    
    @Published var dailyGoal: Int = 2000 // デフォルト2L
    
    private let goalKey = "daily_goal_ml"
    
    init() {
        loadGoal()
    }
    
    func setGoal(_ newGoal: Int) {
        dailyGoal = newGoal
        saveGoal()
    }
    
    private func saveGoal() {
        UserDefaults.standard.set(dailyGoal, forKey: goalKey)
    }
    
    private func loadGoal() {
        let saved = UserDefaults.standard.integer(forKey: goalKey)
        if saved > 0 {
            dailyGoal = saved
        }
    }
    
    // デフォルト値から変更されたかチェックするメソッド
    func isGoalCustomized() -> Bool {
        return UserDefaults.standard.object(forKey: goalKey) != nil
    }
}


extension DateFormatter {
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()
}

class StableNotificationManager: ObservableObject {
    static let shared = StableNotificationManager()
    
    @Published var isNotificationEnabled = false
    @Published var isProcessing = false
    @Published var notificationInterval = 2
    @Published var startTime = Calendar.current.date(from: DateComponents(hour: 8, minute: 0))!
    @Published var endTime = Calendar.current.date(from: DateComponents(hour: 22, minute: 0))!
    
    private let notificationIdentifierPrefix = "water_reminder_"
    
    init() {
        loadSettings()
        Task {
            await checkNotificationStatus()
        }
    }
    
    func checkNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            let isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if self.isNotificationEnabled != isAuthorized {
                self.isNotificationEnabled = isAuthorized
                self.saveSettings()
            }
            print("通知ステータス確認: \(settings.authorizationStatus.rawValue), isEnabled: \(self.isNotificationEnabled)")
        }
    }
    
    func requestNotificationPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound, .provisional]
            )
            
            await MainActor.run {
                self.isNotificationEnabled = granted
                self.saveSettings()
            }
            
            if granted {
                await scheduleWaterReminders()
                print("通知許可取得成功")
            } else {
                print("通知許可拒否")
            }
            
            return granted
        } catch {
            await MainActor.run {
                print("通知許可要求エラー: \(error)")
                self.isNotificationEnabled = false
                self.saveSettings()
            }
            return false
        }
    }
    
    func toggleNotifications(enabled: Bool) async {
        await MainActor.run {
            if self.isProcessing { return }
            self.isProcessing = true
        }
        defer { Task { @MainActor in self.isProcessing = false } }

        if enabled { // トグルがONになった場合
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                await scheduleWaterReminders()
                print("通知を有効化（許可済み）")
            default:
                let granted = await requestNotificationPermission()
                if !granted {
                    await MainActor.run { self.isNotificationEnabled = false }
                }
                print("通知許可結果: \(granted)")
            }
        } else { // トグルがOFFになった場合
            await cancelAllNotifications()
            print("通知を無効化")
        }
    }
    
    func scheduleWaterReminders() async {
        // 1. 既存の通知をすべてキャンセル
        await cancelAllNotifications()
        
        // 2. 通知が有効になっているか確認
        let isEnabled = await MainActor.run { self.isNotificationEnabled }
        guard isEnabled else {
            print("通知が無効のため、スケジューリングをスキップ")
            return
        }
        
        // 3. 今日の水分摂取量が目標に達しているか確認
        let todayIntake = await MainActor.run { WaterStore.shared.todayIntake }
        let goal = await MainActor.run { GoalManager.shared.dailyGoal }
        
        if todayIntake >= goal {
            print("目標達成済みのため、通知をスケジュールしません")
            return
        }
        
        // 4. ユーザーが通知を許可しているか最終確認
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            print("通知許可がないため、スケジューリングを中止")
            await MainActor.run {
                self.isNotificationEnabled = false
                self.saveSettings()
            }
            return
        }
        
        // 5. 通知設定（開始時間、終了時間、間隔）を取得
        let (start, end) = await MainActor.run { (self.startTime, self.endTime) }
        let interval = await MainActor.run { self.notificationInterval }
        
        // 6. 繰り返し通知のみをスケジュールする（★ここが修正点です）
        let repeatNotifications = await scheduleSimpleRepeatingNotifications(startTime: start, endTime: end, interval: interval, goal: goal)
        
        print("通知スケジュール完了 - 繰り返し通知を \(repeatNotifications)個 登録しました")
    }
    
    private func scheduleNotificationsForDate(date: Date, startTime: Date, endTime: Date, interval: Int, goal: Int, isToday: Bool) async -> Int {
        let calendar = Calendar.current
        let now = Date()
        let currentTotalMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        
        let startHour = calendar.component(.hour, from: startTime)
        let startMinute = calendar.component(.minute, from: startTime)
        let endHour = calendar.component(.hour, from: endTime)
        let endMinute = calendar.component(.minute, from: endTime)
        
        // 開始時刻と終了時刻を分単位で計算
        let startTotalMinutes = startHour * 60 + startMinute
        var endTotalMinutes = endHour * 60 + endMinute
        
        // 終了時刻が開始時刻より前の場合（日をまたぐ場合）、翌日として計算
        if endTotalMinutes < startTotalMinutes {
            endTotalMinutes += 24 * 60 // 24時間分（1440分）を加算
        }
        
        print("今日の通知計算 - 開始: \(String(format: "%d:%02d", startHour, startMinute)) (\(startTotalMinutes)分), 終了: \(String(format: "%d:%02d", endHour, endMinute)) (\(endTotalMinutes)分)")
        
        var notificationTotalMinutes = startTotalMinutes
        let intervalMinutes = interval * 60
        var notificationCount = 0
        let maxNotifications = 15
        
        while notificationTotalMinutes <= endTotalMinutes && notificationCount < maxNotifications {
            let notificationHour = (notificationTotalMinutes / 60) % 24 // 24時間で正規化
            let notificationMinute = notificationTotalMinutes % 60
            
            // 今日の場合、現在時刻より後の通知のみスケジュール
            if isToday {
                let currentTimeForComparison = currentTotalMinutes
                // notificationTimeForComparison: 今日の 0..1439 の範囲で比較
                let notificationTimeForComparison = notificationTotalMinutes > 24 * 60 ?
                    notificationTotalMinutes - 24 * 60 : notificationTotalMinutes
                
                if notificationTotalMinutes < 24 * 60 && notificationTimeForComparison <= currentTimeForComparison {
                    print("スキップ: \(String(format: "%d:%02d", notificationHour, notificationMinute)) (現在時刻 \(String(format: "%d:%02d", currentTotalMinutes / 60, currentTotalMinutes % 60)) より前)")
                    notificationTotalMinutes += intervalMinutes
                    continue
                }
            }
            
            let content = UNMutableNotificationContent()
            let messageData = getRandomWaterReminderMessage()
            content.title = messageData.title
            content.body = messageData.body
            content.sound = .default
            content.badge = 1
            
            content.userInfo = [
                "type": "water_reminder",
                "scheduled_hour": notificationHour,
                "scheduled_minute": notificationMinute,
                "goal_ml": goal,
                "timestamp": Date().timeIntervalSince1970
            ]
            
            // 今日の具体的な通知時刻を計算
            var targetDate = date
            if notificationTotalMinutes >= 24 * 60 {
                // 明日の日付
                targetDate = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            }
            
            var dateComponents = DateComponents()
            dateComponents.year = calendar.component(.year, from: targetDate)
            dateComponents.month = calendar.component(.month, from: targetDate)
            dateComponents.day = calendar.component(.day, from: targetDate)
            dateComponents.hour = notificationHour
            dateComponents.minute = notificationMinute
            
            // 今日の場合は一回限りの通知
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
            
            let identifier = "\(notificationIdentifierPrefix)today_\(notificationCount)_\(notificationHour)_\(notificationMinute)_\(Int(Date().timeIntervalSince1970))"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            
            do {
                try await UNUserNotificationCenter.current().add(request)
                let timeString = String(format: "%d:%02d", notificationHour, notificationMinute)
                let dateString = notificationTotalMinutes >= 24 * 60 ? "(明日)" : "(今日)"
                print("通知登録成功: \(timeString) \(dateString)")
                notificationCount += 1
            } catch {
                print("通知登録エラー (\(identifier)): \(error)")
            }
            
            notificationTotalMinutes += intervalMinutes
        }
        
        print("今日の通知スケジューリング完了: \(notificationCount)個の通知を登録")
        return notificationCount
    }
    
    func cancelAllNotifications() async {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let identifiersToRemove = requests
            .filter { $0.identifier.starts(with: notificationIdentifierPrefix) }
            .map { $0.identifier }
        
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiersToRemove)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiersToRemove)
        print("通知キャンセル完了: \(identifiersToRemove.count)個")
    }
    
    func getNextNotificationTime() -> String? {
        guard isNotificationEnabled else { return nil }
        
        let calendar = Calendar.current
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)
        
        let startHour = calendar.component(.hour, from: self.startTime)
        let startMinute = calendar.component(.minute, from: self.startTime)
        let endHour = calendar.component(.hour, from: self.endTime)
        let endMinute = calendar.component(.minute, from: self.endTime)
        
        // 現在時刻を分単位で計算
        let currentTotalMinutes = currentHour * 60 + currentMinute
        let startTotalMinutes = startHour * 60 + startMinute
        var endTotalMinutes = endHour * 60 + endMinute
        
        // 終了が開始より前なら日をまたぐ
        if endTotalMinutes < startTotalMinutes {
            endTotalMinutes += 24 * 60
        }
        
        var notificationTotalMinutes = startTotalMinutes
        let intervalMinutes = self.notificationInterval * 60
        
        while notificationTotalMinutes <= endTotalMinutes {
            // 比較は「今日の時刻」で行う（24時間で正規化）
            let notificationAsToday = notificationTotalMinutes % (24 * 60)
            if notificationAsToday > currentTotalMinutes {
                let hour = notificationAsToday / 60
                let minute = notificationAsToday % 60
                return String(format: "本日 %d:%02d", hour, minute)
            }
            notificationTotalMinutes += intervalMinutes
        }
        
        // 今日に通知がない場合は明日の最初の通知
        return String(format: "明日の %d:%02d", startHour, startMinute)
    }
    
    // 即座に次の通知をスケジュールする関数（テスト用）
    func scheduleImmediateTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "🧪 テスト通知"
        content.body = "通知設定が正しく動作しています！"
        content.sound = .default
        content.badge = 1
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let identifier = "\(notificationIdentifierPrefix)test"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("テスト通知をスケジュール: 5秒後")
        } catch {
            print("テスト通知エラー: \(error)")
        }
    }
    
    // シンプルな繰り返し通知（明日以降用）
    private func scheduleSimpleRepeatingNotifications(startTime: Date, endTime: Date, interval: Int, goal: Int) async -> Int {
        let calendar = Calendar.current
        
        let startHour = calendar.component(.hour, from: startTime)
        let startMinute = calendar.component(.minute, from: startTime)
        let endHour = calendar.component(.hour, from: endTime)
        let endMinute = calendar.component(.minute, from: endTime)
        
        print("繰り返し通知設定 - 開始: \(String(format: "%d:%02d", startHour, startMinute)), 終了: \(String(format: "%d:%02d", endHour, endMinute)), 間隔: \(interval)時間")
        
        let startTotalMinutes = startHour * 60 + startMinute
        var endTotalMinutes = endHour * 60 + endMinute
        
        // 終了時刻が開始時刻より前の場合（日をまたぐ場合）、翌日として計算
        if endTotalMinutes < startTotalMinutes {
            endTotalMinutes += 24 * 60
        }
        
        var notificationTotalMinutes = startTotalMinutes
        let intervalMinutes = interval * 60
        var notificationCount = 0
        let maxNotifications = 15
        
        while notificationTotalMinutes <= endTotalMinutes && notificationCount < maxNotifications {
            let notificationHour = (notificationTotalMinutes / 60) % 24
            let notificationMinute = notificationTotalMinutes % 60
            
            let content = UNMutableNotificationContent()
            let messageData = getRandomWaterReminderMessage()
            content.title = messageData.title
            content.body = messageData.body
            content.sound = .default
            content.badge = 1
            
            content.userInfo = [
                "type": "water_reminder",
                "scheduled_hour": notificationHour,
                "scheduled_minute": notificationMinute,
                "goal_ml": goal,
                "timestamp": Date().timeIntervalSince1970
            ]
            
            // 繰り返し通知用の設定
            var dateComponents = DateComponents()
            dateComponents.hour = notificationHour
            dateComponents.minute = notificationMinute
            
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let identifier = "\(notificationIdentifierPrefix)daily_\(notificationCount)_\(notificationHour)_\(notificationMinute)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            
            do {
                try await UNUserNotificationCenter.current().add(request)
                let timeString = String(format: "%d:%02d", notificationHour, notificationMinute)
                print("繰り返し通知登録成功: \(timeString)")
                notificationCount += 1
            } catch {
                print("繰り返し通知登録エラー (\(identifier)): \(error)")
            }
            
            notificationTotalMinutes += intervalMinutes
        }
        
        print("繰り返し通知スケジューリング完了: \(notificationCount)個")
        return notificationCount
    }
    
    // 次の通知時間を計算
    private func calculateNextNotificationTime(from currentTime: Date, startTime: Date, endTime: Date, interval: Int) async -> Date? {
        let calendar = Calendar.current
        let currentHour = calendar.component(.hour, from: currentTime)
        let currentMinute = calendar.component(.minute, from: currentTime)
        let currentTotalMinutes = currentHour * 60 + currentMinute
        
        let startHour = calendar.component(.hour, from: startTime)
        let startMinute = calendar.component(.minute, from: startTime)
        let endHour = calendar.component(.hour, from: endTime)
        let endMinute = calendar.component(.minute, from: endTime)
        
        let startTotalMinutes = startHour * 60 + startMinute
        var endTotalMinutes = endHour * 60 + endMinute
        
        // 終了時刻が開始時刻より前の場合（日をまたぐ場合）
        if endTotalMinutes < startTotalMinutes {
            endTotalMinutes += 24 * 60
        }
        
        let intervalMinutes = interval * 60
        var notificationTotalMinutes = startTotalMinutes
        
        // 現在時刻より後の最初の通知時間を見つける
        while notificationTotalMinutes <= endTotalMinutes {
            let notificationHour = (notificationTotalMinutes / 60) % 24
            let notificationMinute = notificationTotalMinutes % 60
            
            // 今日の通知時刻として比較（24時間で正規化）
            let todayNotificationMinutes = notificationTotalMinutes % (24 * 60)
            
            // notificationTotalMinutes が 24*60 以上の場合は「明日分」の候補なので、
            // 今日と比較するのは 24*60 未満のものだけ（todayNotificationMinutes はそのまま今日の時刻）
            if notificationTotalMinutes < 24 * 60 {
                if todayNotificationMinutes > currentTotalMinutes {
                    // 今日の通知（現在時刻より後）
                    var dateComponents = DateComponents()
                    dateComponents.year = calendar.component(.year, from: currentTime)
                    dateComponents.month = calendar.component(.month, from: currentTime)
                    dateComponents.day = calendar.component(.day, from: currentTime)
                    dateComponents.hour = notificationHour
                    dateComponents.minute = notificationMinute
                    return calendar.date(from: dateComponents)
                }
            } else {
                // notificationTotalMinutes >= 24*60 は翌日の候補
                // もしここで今日の候補が見つかっていれば既に return されているはずなので
                // ここではスキップ（翌日以降の扱い）
            }
            
            notificationTotalMinutes += intervalMinutes
        }
        
        // ここまで来た = ループで今日の候補は見つからなかった
        // ただし「現在時刻が今日の終了時刻より前」であれば、start から interval に沿って
        // 現在時刻より後の最初のスロットを改めて計算して今日中にスケジュールできるか試みる。
        // （日をまたぐ設定のとき endTotalMinutes は 24h を超えているため % で今日の終わりを取得）
        let todayEndTotalMinutes = endTotalMinutes % (24 * 60)
        if currentTotalMinutes < todayEndTotalMinutes {
            // start からの k を計算して次のスロットを求める
            let delta = currentTotalMinutes - startTotalMinutes
            var nextTotal = startTotalMinutes
            if delta >= 0 {
                // ceil((delta+1)/interval) を使って次のインデックスを取得
                let k = Int(ceil(Double(delta + 1) / Double(intervalMinutes)))
                nextTotal = startTotalMinutes + k * intervalMinutes
            } else {
                // 現在が start より前なら start を使う
                nextTotal = startTotalMinutes
            }
            
            // nextTotal が今日の範囲（0..1439）でかつ endTotalMinutes を超えないか確認
            if nextTotal <= endTotalMinutes && nextTotal < 24 * 60 {
                var dateComponents = DateComponents()
                dateComponents.year = calendar.component(.year, from: currentTime)
                dateComponents.month = calendar.component(.month, from: currentTime)
                dateComponents.day = calendar.component(.day, from: currentTime)
                dateComponents.hour = (nextTotal / 60) % 24
                dateComponents.minute = nextTotal % 60
                return calendar.date(from: dateComponents)
            }
        }
        
        // 今日に通知がない場合は明日の最初の通知時間
        var tomorrowComponents = DateComponents()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: currentTime) ?? currentTime
        tomorrowComponents.year = calendar.component(.year, from: tomorrow)
        tomorrowComponents.month = calendar.component(.month, from: tomorrow)
        tomorrowComponents.day = calendar.component(.day, from: tomorrow)
        tomorrowComponents.hour = startHour
        tomorrowComponents.minute = startMinute
        
        return calendar.date(from: tomorrowComponents)
    }
    
    // 次の通知を即座にスケジュール
    private func scheduleImmediateNextNotification(at date: Date, goal: Int) async {
        let content = UNMutableNotificationContent()
        let messageData = getRandomWaterReminderMessage()
        content.title = messageData.title
        content.body = messageData.body
        content.sound = .default
        content.badge = 1
        
        content.userInfo = [
            "type": "water_reminder",
            "goal_ml": goal,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        let calendar = Calendar.current
        var dateComponents = DateComponents()
        dateComponents.year = calendar.component(.year, from: date)
        dateComponents.month = calendar.component(.month, from: date)
        dateComponents.day = calendar.component(.day, from: date)
        dateComponents.hour = calendar.component(.hour, from: date)
        dateComponents.minute = calendar.component(.minute, from: date)
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let identifier = "\(notificationIdentifierPrefix)next_\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("次回通知登録成功: \(DateFormatter.timeFormatter.string(from: date))")
        } catch {
            print("次回通知登録エラー: \(error)")
        }
    }
    
    private func getRandomWaterReminderMessage() -> (title: String, body: String) {
        let messages = [
            (title: "💧 水分補給タイム", body: "美しい肌のために、今コップ1杯の水を飲みませんか？"),
            (title: "💧 美容のひととき", body: "内側から輝くために、お水でリフレッシュしましょう！"),
            (title: "💧 キレイの秘訣", body: "透明感のある肌は十分な水分から。今すぐ一口どうぞ♪"),
            (title: "💧 うるおい補給", body: "代謝アップのために、今日も水分補給を忘れずに！"),
            (title: "💧 美しい習慣", body: "理想の自分に近づくため、今お水を飲む時間です"),
            (title: "💧 デトックス時間", body: "老廃物を流して、すっきりとしたフェイスラインを目指しましょう"),
            (title: "💧 セルフケア", body: "あなたの美しさのために、水分補給でケアしてあげて"),
            (title: "💧 輝く時間", body: "肌の弾力性を保つために、今コップ1杯いかがですか？")
        ]
        
        return messages.randomElement() ?? messages[0]
    }
    
    func saveSettings() {
        UserDefaults.standard.set(isNotificationEnabled, forKey: "notification_enabled")
        UserDefaults.standard.set(notificationInterval, forKey: "notification_interval")
        UserDefaults.standard.set(startTime, forKey: "notification_start_time")
        UserDefaults.standard.set(endTime, forKey: "notification_end_time")
    }
    
    private func loadSettings() {
        isNotificationEnabled = UserDefaults.standard.bool(forKey: "notification_enabled")
        notificationInterval = UserDefaults.standard.integer(forKey: "notification_interval")
        if notificationInterval == 0 { notificationInterval = 2 }
        
        if let startTime = UserDefaults.standard.object(forKey: "notification_start_time") as? Date {
            self.startTime = startTime
        }
        if let endTime = UserDefaults.standard.object(forKey: "notification_end_time") as? Date {
            self.endTime = endTime
        }
    }
    
    func updateNotificationSettings(interval: Int, startTime: Date, endTime: Date) {
        self.notificationInterval = interval
        self.startTime = startTime
        self.endTime = endTime
        saveSettings()
        
        if isNotificationEnabled {
            Task {
                await scheduleWaterReminders()
            }
        }
    }
}


final class WaterStore: ObservableObject {
    static let shared = WaterStore()

    @Published var records: [String: Int] = [:]
    @Published var todayIntake: Int = 0
    @Published var showingGoalAchieved = false
    @Published var hasShownGoalToday = false
    
    // ★追加: レビュー表示のトリガー用フラグ
    @Published var shouldRequestReview = false

    private let key = "waterHistory_v1"
    private let achievementKey = "achievement_shown_"
    // ★追加: 初回記録済みかどうかの保存キー
    private let hasRecordedFirstTimeKey = "has_recorded_first_time_v1"

    init() {
        load()
        todayIntake = records[todayKey()] ?? 0
        loadTodayAchievementStatus()
    }

    func add(intake: Int) {
        let key = todayKey()
        var current = records[key] ?? 0
        let newTotal = current + intake
        
        if newTotal > 3000 {
            current = 3000
        } else {
            current += intake
        }
        
        records[key] = current
        todayIntake = current
        save()
        
        checkGoalAchievement(newIntake: current)
        
        // ★追加: 初回記録チェックを実行
        checkFirstRecordingForReview()
    }
    
    // ★追加: 初めての記録ならレビューフラグを立てるメソッド
    private func checkFirstRecordingForReview() {
        // まだ初回記録フラグが保存されていない（＝初めて）場合
        if !UserDefaults.standard.bool(forKey: hasRecordedFirstTimeKey) {
            // フラグを保存（次回以降は呼ばれないようにする）
            UserDefaults.standard.set(true, forKey: hasRecordedFirstTimeKey)
            
            // UIの更新やアニメーションと被らないように少しだけ遅らせて通知
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.shouldRequestReview = true
            }
        }
    }

    func setToday(_ value: Int) {
        let key = todayKey()
        records[key] = value
        todayIntake = value
        save()
        
        if value == 0 {
            hasShownGoalToday = false
            saveTodayAchievementStatus()
        }
    }
    
    private func checkGoalAchievement(newIntake: Int) {
        let goal = GoalManager.shared.dailyGoal
        
        if newIntake >= goal && !hasShownGoalToday {
            showingGoalAchieved = true
            hasShownGoalToday = true
            saveTodayAchievementStatus()
            
            Task {
                await StableNotificationManager.shared.cancelAllNotifications()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeOut(duration: 0.5)) {
                    self.showingGoalAchieved = false
                }
            }
        }
    }
    
    private func saveTodayAchievementStatus() {
        UserDefaults.standard.set(hasShownGoalToday, forKey: achievementKey + todayKey())
    }
    
    private func loadTodayAchievementStatus() {
        hasShownGoalToday = UserDefaults.standard.bool(forKey: achievementKey + todayKey())
    }

    func intake(on date: Date) -> Int {
        let k = keyFor(date)
        return records[k] ?? 0
    }

    func lastNDays(_ n: Int) -> [Int] {
        var arr: [Int] = []
        for i in (0..<n).reversed() {
            let d = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            arr.append(intake(on: d))
        }
        return arr
    }

    func consecutiveStreak() -> Int {
        var streak = 0
        var dayOffset = 0
        let goal = GoalManager.shared.dailyGoal
        while true {
            let d = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date())!
            let v = intake(on: d)
            if v >= goal {
                streak += 1
            } else {
                break
            }
            dayOffset += 1
            if dayOffset > 365 { break }
        }
        return streak
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            print("Save error", error)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key) {
            do {
                let decoded = try JSONDecoder().decode([String: Int].self, from: data)
                records = decoded
            } catch {
                print("Load error", error)
                records = [:]
            }
        } else {
            records = [:]
        }
    }

    private func todayKey() -> String {
        keyFor(Date())
    }

    private func keyFor(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

// MARK: - Main App & Delegate

@main
struct AquaBeautyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("hasSeenIntro") var hasSeenIntro: Bool = false

    var body: some Scene {
        WindowGroup {
            if hasSeenIntro {
                ContentView()
                    .onAppear {
                        Task {
                            await StableNotificationManager.shared.scheduleWaterReminders()
                        }
                    }
            } else {
                NavigationView {
                    IntroView()
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        MobileAds.shared.start(completionHandler: nil)
        UNUserNotificationCenter.current().delegate = self
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        return true
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge, .list])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let type = userInfo["type"] as? String, type == "water_reminder" {
            print("水分補給通知がタップされました")
        }
        completionHandler()
    }
    
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        completionHandler(.noData)
    }
}

// MARK: - Views

struct ContentView: View {
    @ObservedObject var store = WaterStore.shared
    @ObservedObject var goalManager = GoalManager.shared
    @State private var showingIntro = false
    @State private var showingResetAlert = false
    
    // ★追加: レビューリクエスト用のアクション
    @Environment(\.requestReview) var requestReview

    var body: some View {
        NavigationView {
            ZStack {
                ScrollView {
                    VStack(spacing: 32) {
                        VStack(spacing: 16) {
                            HStack {
                                Text("今日の水分補給")
                                    .font(.system(size: 24, weight: .light, design: .rounded))
                                
                                Spacer()
                                
                                HStack(spacing: 16) {
                                    NavigationLink(destination: GoalSettingsView()) {
                                        Image(systemName: "target").font(.system(size: 20))
                                    }
                                    NavigationLink(destination: StableNotificationSettingsView()) {
                                        Image(systemName: "bell").font(.system(size: 20))
                                    }
                                    Button(action: { showingIntro = true }) {
                                        Image(systemName: "info.circle").font(.system(size: 20))
                                    }
                                }
                                .foregroundColor(Color.accentRose)
                            }
                            .padding(.horizontal, 20)

                            ModernProgressCircle(progress: Double(store.todayIntake) / Double(goalManager.dailyGoal))
                                .frame(width: 220, height: 220)

                            Text("目標まで残り \(max(0, goalManager.dailyGoal - store.todayIntake)) mL")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 16)

                        EnhancedQuickAddSection()
                        .padding(.horizontal, 20)

                        HStack(spacing: 16) {
                            StatsCard(
                                title: "連続達成", value: "\(store.consecutiveStreak())", unit: "日",
                                icon: "flame.fill", color: Color.accentRose
                            )
                            StatsCard(
                                title: "今日の進捗",
                                value: String(format: "%.0f", min(Double(store.todayIntake) / Double(goalManager.dailyGoal), 1.0) * 100),
                                unit: "%", icon: "chart.line.uptrend.xyaxis", color: Color.deepRose
                            )
                        }
                        .padding(.horizontal, 20)

                        HStack(spacing: 16) {
                            Button(action: { showingResetAlert = true }) {
                                HStack {
                                    Image(systemName: "arrow.counterclockwise")
                                    Text("リセット")
                                }
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(uiColor: .systemBackground))
                                .foregroundColor(Color.accentRose)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.accentRose.opacity(0.3), lineWidth: 1)
                                )
                                .shadow(color: Color.shadowGray.opacity(0.3), radius: 8, x: 0, y: 4)
                            }

                            NavigationLink(destination: HistoryView()) {
                                HStack {
                                    Image(systemName: "chart.bar")
                                    Text("履歴")
                                }
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(LinearGradient.accent)
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .shadow(color: Color.accentRose.opacity(0.4), radius: 8, x: 0, y: 4)
                            }
                        }
                        .padding(.horizontal, 20)
                        
                        // 👇 BannerAdView の確認
                        BannerAdView()
                            .frame(width: 320, height: 50)
                            .padding(.bottom, 8)

                        Spacer(minLength: 32)
                    }
                }
                .background(LinearGradient.background.ignoresSafeArea())
                .preferredColorScheme(.light)
                .navigationBarTitle("", displayMode: .inline)
                .navigationBarHidden(true)
                .sheet(isPresented: $showingIntro) { IntroView() }
                .alert("記録をリセットしますか？", isPresented: $showingResetAlert) {
                    Button("キャンセル", role: .cancel) { }
                    Button("リセット", role: .destructive) {
                        withAnimation(.spring()) {
                            store.setToday(0)
                            Task {
                                await StableNotificationManager.shared.scheduleWaterReminders()
                            }
                        }
                    }
                } message: {
                    Text("今日の水分補給記録（\(store.todayIntake)mL）がすべて削除されます。この操作は元に戻せません。")
                }
                
                if store.showingGoalAchieved {
                    GoalAchievementView(isShowing: $store.showingGoalAchieved)
                        .transition(.opacity)
                        .zIndex(999)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        // ★追加: WaterStoreのフラグを監視してレビューを表示
        .onChange(of: store.shouldRequestReview) { shouldRequest in
            if shouldRequest {
                requestReview()
                store.shouldRequestReview = false
            }
        }
    }
}

// MARK: - Component Views

struct ModernProgressCircle: View {
    @ObservedObject var store = WaterStore.shared
    var progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.5), lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(min(progress, 1.0)))
                .stroke(
                    LinearGradient.aqua,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(Angle(degrees: -90))
                .animation(.easeInOut(duration: 1.0), value: progress)

            VStack(spacing: 8) {
                Text("\(Int(store.todayIntake))")
                    .font(.system(size: 32, weight: .light, design: .rounded))
                Text("mL")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                Text(String(format: "%.0f%% 達成", min(progress, 1.0) * 100))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(Color.deepAqua)
            }
            .foregroundColor(.primary)
        }
        .padding(24)
        .background(
            Circle()
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: Color.shadowGray.opacity(0.2), radius: 20, x: 0, y: 10)
        )
    }
}

struct StatsCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)

            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))

            HStack(alignment: .bottom, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .light, design: .rounded))
                Text(unit)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .padding(.bottom, 2)
            }
        }
        .foregroundColor(.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.shadowGray.opacity(0.2), radius: 10, x: 0, y: 5)
    }
}

struct GoalAchievementView: View {
    @Binding var isShowing: Bool
    @State private var scale: CGFloat = 0.1
    @State private var rotation: Double = 0
    @State private var sparkleOpacity: Double = 0
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            
            VStack(spacing: 30) {
                ZStack {
                    ForEach(0..<8) { i in
                        RoundedRectangle(cornerRadius: 4)
                            .frame(width: 60, height: 4)
                            .foregroundColor(Color.accentRose.opacity(0.8))
                            .rotationEffect(.degrees(Double(i) * 45 + rotation))
                            .opacity(sparkleOpacity)
                    }
                    
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.yellow, .orange, Color.accentRose],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .scaleEffect(scale)
                        .rotationEffect(.degrees(rotation * 0.5))
                }
                
                VStack(spacing: 15) {
                    Text("🎉 目標達成！ 🎉")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("今日の水分補給目標を達成しました！")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text("お疲れさまでした✨")
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundColor(Color.accentRose.opacity(0.8))
                }
                .foregroundColor(.white)
                .scaleEffect(scale)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { scale = 1.0 }
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { rotation = 360 }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { sparkleOpacity = 1.0 }
        }
    }
}

// MARK: - Settings & History Screens

struct GoalSettingsView: View {
    @ObservedObject var goalManager = GoalManager.shared
    @State private var tempGoal: Double = 2000
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("1日の目標設定").font(.titleText)
                    
                    VStack(spacing: 20) {
                        HStack {
                            Text("目標量").font(.mediumText)
                            Spacer()
                            Text("\(Int(tempGoal))mL")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundColor(Color.accentRose)
                        }
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Slider(value: $tempGoal, in: 1500...3000, step: 500)
                                .accentColor(Color.accentRose)
                            
                            HStack {
                                Text("1.5L").font(.captionText)
                                Spacer()
                                Text("3L").font(.captionText)
                            }.foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Text("推奨目標量について").font(.semiboldCaption)
                            VStack(spacing: 8) {
                                GoalDescriptionRow(volume: "1.5L", description: "最低限の水分補給")
                                GoalDescriptionRow(volume: "2L", description: "一般的な推奨量")
                                GoalDescriptionRow(volume: "2.5L", description: "美容・健康重視")
                                GoalDescriptionRow(volume: "3L", description: "アクティブな方向け")
                            }
                        }
                        .padding(16)
                        .background(Color.accentRose.opacity(0.1))
                        .cornerRadius(12)
                    }
                }
                .padding(20)
                .background(Color(uiColor: .systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: Color.shadowGray.opacity(0.2), radius: 10, x: 0, y: 5)
                
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    goalManager.setGoal(Int(tempGoal))
                    Task {
                        await StableNotificationManager.shared.scheduleWaterReminders()
                    }
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "target")
                        Text("目標を設定")
                    }
                    .font(.mediumText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(LinearGradient.accent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color.accentRose.opacity(0.4), radius: 12, x: 0, y: 6)
                }
                .padding(.horizontal, 20)
                
                // 👇 BannerAdView の確認
                BannerAdView()
                    .frame(width: 320, height: 50)
                    .padding(.bottom, 8)
                
                Spacer(minLength: 32)
            }
            .padding(20)
        }
        .background(LinearGradient.background.ignoresSafeArea())
        .preferredColorScheme(.light)
        .navigationTitle("目標設定")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            tempGoal = Double(goalManager.dailyGoal)
        }
    }
}

struct GoalDescriptionRow: View {
    let volume: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("•").font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(minWidth: 8, alignment: .leading)
            Text(volume).font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(minWidth: 35, alignment: .leading)
            Text(description).font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(Color.accentRose)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - シンプルな通知設定アニメーション
struct SimpleNotificationConfirmationView: View {
    let message: String
    @State private var scale: CGFloat = 0.8
    @State private var opacity: Double = 0
    @State private var bellBounce: CGFloat = 1.0
    @State private var showText = false
    @State private var sparkleOpacity: Double = 0
    
    var body: some View {
        ZStack {
            // 背景
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .opacity(opacity)
            
            VStack(spacing: 24) {
                // アイコン部分
                ZStack {
                    // 簡単なキラキラ効果
                    ForEach(0..<4) { i in
                        Image(systemName: "sparkle")
                            .font(.system(size: 16))
                            .foregroundColor(Color.accentRose.opacity(0.6))
                            .offset(
                                x: [30, -30, 25, -25][i],
                                y: [-30, -30, 30, 30][i]
                            )
                            .opacity(sparkleOpacity)
                            .scaleEffect(sparkleOpacity)
                    }
                    
                    // メインのベルアイコン
                    Image(systemName: "bell.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentRose, Color.deepRose],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .scaleEffect(bellBounce)
                }
                
                // テキスト
                if showText {
                    VStack(spacing: 12) {
                        Text("設定完了")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.accentRose)
                        
                        Text(message)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color.accentRose.opacity(0.2), radius: 15, x: 0, y: 8)
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .onAppear {
            // アニメーション開始
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                scale = 1.0
                opacity = 1.0
            }
            
            // ベルのバウンス
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5).delay(0.2)) {
                bellBounce = 1.2
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8).delay(0.4)) {
                bellBounce = 1.0
            }
            
            // キラキラ効果
            withAnimation(.easeInOut(duration: 0.8).delay(0.3)) {
                sparkleOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 1.0).delay(1.0)) {
                sparkleOpacity = 0
            }
            
            // テキスト表示
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.5)) {
                showText = true
            }
            
            // 触覚フィードバック
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}


struct StableNotificationSettingsView: View {
    @ObservedObject var notificationManager = StableNotificationManager.shared
    @State private var tempInterval: Double = 2
    @State private var tempStartTime = Date()
    @State private var tempEndTime = Date()
    @Environment(\.presentationMode) var presentationMode
    
    @State private var showConfirmation = false
    @State private var nextNotificationMessage = ""

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("水分補給リマインダー").font(.titleText)
                        StableNotificationToggle(notificationManager: notificationManager)
                    }
                    .padding(20)
                    .background(Color(uiColor: .systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color.shadowGray.opacity(0.2), radius: 10, x: 0, y: 5)
                    
                    if notificationManager.isNotificationEnabled {
                        VStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("通知設定").font(.titleText)
                                
                                HStack {
                                    Text("間隔").font(.mediumText)
                                    Spacer()
                                    Text("\(Int(tempInterval))時間ごと").font(.mediumText).foregroundColor(Color.accentRose)
                                }
                                
                                Slider(value: $tempInterval, in: 1...4, step: 1).accentColor(Color.accentRose)
                            }
                            
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("開始時間").font(.captionText).foregroundColor(.secondary)
                                    DatePicker("", selection: $tempStartTime, displayedComponents: .hourAndMinute).labelsHidden()
                                }
                                Spacer()
                                VStack(alignment: .leading) {
                                    Text("終了時間").font(.captionText).foregroundColor(.secondary)
                                    DatePicker("", selection: $tempEndTime, displayedComponents: .hourAndMinute).labelsHidden()
                                }
                            }
                            .accentColor(Color.accentRose)
                        }
                        .padding(20)
                        .background(Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: Color.shadowGray.opacity(0.2), radius: 10, x: 0, y: 5)
                        
                        Button(action: saveSettingsAndShowAnimation) {
                            HStack {
                                Image(systemName: "bell.badge")
                                Text("通知設定を保存")
                            }
                            .font(.mediumText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(LinearGradient.accent)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: Color.accentRose.opacity(0.4), radius: 12, x: 0, y: 6)
                        }
                        .disabled(notificationManager.isProcessing)
                        .opacity(notificationManager.isProcessing ? 0.6 : 1.0)
                        .padding(.horizontal, 20)
                    }
                    
                    // 👇 BannerAdView の確認
                    BannerAdView()
                        .frame(width: 320, height: 50)
                        .padding(.bottom, 8)
                    Spacer(minLength: 32)
                    
                    
                }
                .padding(20)
            }
            .background(LinearGradient.background.ignoresSafeArea())
            .preferredColorScheme(.light)
            .navigationTitle("通知設定")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                tempInterval = Double(notificationManager.notificationInterval)
                tempStartTime = notificationManager.startTime
                tempEndTime = notificationManager.endTime
            }
            
            if showConfirmation {
                SimpleNotificationConfirmationView(message: nextNotificationMessage)
            }
        }
    }
    
    private func saveSettingsAndShowAnimation() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        notificationManager.updateNotificationSettings(
            interval: Int(tempInterval),
            startTime: tempStartTime,
            endTime: tempEndTime
        )
        
        if let nextTime = notificationManager.getNextNotificationTime() {
            nextNotificationMessage = "次回の通知は\n\(nextTime)です"
        } else {
            nextNotificationMessage = "通知はオフになりました"
        }
        
        withAnimation {
            showConfirmation = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) {
            presentationMode.wrappedValue.dismiss()
        }
    }
}

struct StableNotificationToggle: View {
    @ObservedObject var notificationManager: StableNotificationManager
    @State private var showingPermissionAlert = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("通知を受け取る").font(.mediumText)
                Text("定期的に水分補給をお知らせします").font(.bodyText).foregroundColor(.secondary)
            }
            Spacer()
            
            if notificationManager.isProcessing {
                ProgressView().scaleEffect(0.8).frame(width: 51, height: 31)
            } else {
                Toggle("", isOn: $notificationManager.isNotificationEnabled)
                    .labelsHidden()
                    .onChange(of: notificationManager.isNotificationEnabled) { newValue in
                        handleToggleAction(isOn: newValue)
                    }
            }
        }
        .alert("通知許可が必要です", isPresented: $showingPermissionAlert) {
            Button("設定を開く") {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
                notificationManager.isNotificationEnabled = false
            }
            Button("キャンセル", role: .cancel) {
                notificationManager.isNotificationEnabled = false
            }
        } message: {
            Text("通知を受け取るには、iPhoneの設定でこのアプリの通知を許可してください。")
        }
    }
    
    private func handleToggleAction(isOn: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            if isOn {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                if settings.authorizationStatus == .denied {
                    await MainActor.run { showingPermissionAlert = true }
                    return
                }
            }
            await notificationManager.toggleNotifications(enabled: isOn)
        }
    }
}


// MARK: - 拡張されたクイック追加セクション

struct EnhancedQuickAddSection: View {
    @State private var showingCustomInput = false
    @State private var customAmount: String = ""
    
    var body: some View {
        VStack(spacing: 16) {
            Text("クイック追加")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)

            // 上段：既存のボタン
            HStack(spacing: 12) {
                ModernAddButton(amount: 200, icon: "mug", label: "コップ１杯分")
                ModernAddButton(amount: 250, icon: "waterbottle", label: "ペットボトル")
                ModernAddButton(amount: 330, icon: "waterbottle", label: "ペットボトル")
            }
            
            // 下段：新しいボタン
            HStack(spacing: 12) {
                ModernAddButton(amount: 500, icon: "waterbottle", label: "ペットボトル")
                ModernAddButton(amount: 600, icon: "waterbottle", label: "ペットボトル")
                ModernAddButton(amount: 1000, icon: "waterbottle.fill", label: "ペットボトル")
                CustomAddButton(showingCustomInput: $showingCustomInput)
            }
        }
        .sheet(isPresented: $showingCustomInput) {
            CustomWaterInputView(customAmount: $customAmount)
        }
    }
}

// MARK: - 改良されたModernAddButton（ラベル付き）
struct ModernAddButton: View {
    @ObservedObject var store = WaterStore.shared
    let amount: Int
    let icon: String
    let label: String?
    
    init(amount: Int, icon: String, label: String? = nil) {
        self.amount = amount
        self.icon = icon
        self.label = label
    }

    var body: some View {
        Button(action: {
            withAnimation(.spring()) {
                store.add(intake: amount)
            }
        }) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(Color.accentRose)

                Text("+\(amount)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                
                Text("mL")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                
                if let label = label {
                    Text(label)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, label != nil ? 12 : 16)
            .background(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color.shadowGray.opacity(0.3), radius: 8, x: 0, y: 4)
        }
    }
}

// MARK: - カスタム追加ボタン
struct CustomAddButton: View {
    @Binding var showingCustomInput: Bool
    
    var body: some View {
        Button(action: {
            showingCustomInput = true
        }) {
            VStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 20))
                    .foregroundColor(Color.deepAqua)

                Text("カスタム")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                
                Text("入力")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                
                Text("自由設定")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [Color.lightAqua.opacity(0.3), Color.crystalBlue.opacity(0.2)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.deepAqua.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: Color.shadowGray.opacity(0.3), radius: 8, x: 0, y: 4)
        }
    }
}

// MARK: - カスタム水分入力画面
struct CustomWaterInputView: View {
    @Binding var customAmount: String
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var store = WaterStore.shared
    
    @State private var selectedAmount: Int = 200
    @State private var showingConfirmation = false
    
    private let quickAmounts = [50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 550, 600, 700, 800, 900, 1000]
    
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient.background.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 16) {
                            Text("水分量を入力")
                                .font(.system(size: 24, weight: .light, design: .rounded))
                                .padding(.top, 20)
                            
                            // スライダー入力
                            VStack(spacing: 12) {
                                HStack {
                                    Text("量")
                                        .font(.system(size: 16, weight: .medium, design: .rounded))
                                    Spacer()
                                    Text("\(selectedAmount) mL")
                                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                                        .foregroundColor(Color.accentRose)
                                }
                                
                                Slider(
                                    value: Binding(
                                        get: { Double(selectedAmount) },
                                        set: { selectedAmount = Int($0) }
                                    ),
                                    in: 10...1000,
                                    step: 10
                                )
                                .accentColor(Color.accentRose)
                                
                                HStack {
                                    Text("10mL")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("1000mL")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(20)
                        .background(Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: Color.shadowGray.opacity(0.2), radius: 10, x: 0, y: 5)
                        
                        // クイック選択ボタン
                        VStack(alignment: .leading, spacing: 16) {
                            Text("よく使う量")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                            
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                                ForEach(quickAmounts, id: \.self) { amount in
                                    Button(action: {
                                        selectedAmount = amount
                                    }) {
                                        Text("\(amount)")
                                            .font(.system(size: 14, weight: .medium, design: .rounded))
                                            .foregroundColor(selectedAmount == amount ? .white : Color.accentRose)
                                            .frame(height: 36)
                                            .frame(maxWidth: .infinity)
                                            .background(
                                                selectedAmount == amount
                                                ? Color.accentRose
                                                : Color.accentRose.opacity(0.1)
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color.accentRose.opacity(0.3), lineWidth: 1)
                                            )
                                    }
                                }
                            }
                        }
                        .padding(20)
                        .background(Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: Color.shadowGray.opacity(0.2), radius: 10, x: 0, y: 5)
                        
                        Spacer()
                        
                        // 👇 BannerAdView の確認
                        BannerAdView()
                            .frame(width: 320, height: 50)
                            .padding(.bottom, 8)
                    }
                    .padding(20)
                }
                
                if showingConfirmation {
                    SimpleNotificationConfirmationView(message: "\(selectedAmount)mL を追加しました")
                        .transition(.opacity)
                }
            }
            .navigationTitle("カスタム入力")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("キャンセル") {
                    presentationMode.wrappedValue.dismiss()
                },
                trailing: Button("追加") {
                    addCustomAmount()
                }
                .disabled(selectedAmount < 10)
                .foregroundColor(selectedAmount >= 10 ? Color.accentRose : .gray)
            )
        }
    }
    
    private func addCustomAmount() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        withAnimation(.spring()) {
            store.add(intake: selectedAmount)
        }
        
        showingConfirmation = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            presentationMode.wrappedValue.dismiss()
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store = WaterStore.shared
    @ObservedObject var goalManager = GoalManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("過去7日間の記録").font(.titleText)
                    ModernBarChart(values: store.lastNDays(7), maxValue: max(2500, goalManager.dailyGoal))
                        .frame(height: 160)
                        .padding(20)
                        .background(Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: Color.shadowGray.opacity(0.2), radius: 15, x: 0, y: 8)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("今月のカレンダー").font(.titleText)
                    ImprovedCalendarView()
                        .padding(20)
                        .background(Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: Color.shadowGray.opacity(0.2), radius: 15, x: 0, y: 8)
                }
                Spacer(minLength: 32)
            }
            .padding(20)
        }
        .background(LinearGradient.background.ignoresSafeArea())
        .preferredColorScheme(.light)
        .navigationTitle("履歴")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Onboarding & Setup Views

struct IntroView: View {
    @State private var currentPage = 0
    
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.softPink, Color.lavenderMist], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            
            TabView(selection: $currentPage) {
                WelcomePage().tag(0)
                BeautyBenefitsPage().tag(1)
                HealthBenefitsPage().tag(2)
                AppFeaturesPage().tag(3)
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
            .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
        }
        .navigationBarHidden(true)
        .preferredColorScheme(.light)
    }
}

struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 40) {
            Spacer()
            ZStack {
                Circle().fill(Color.accentRose.opacity(0.2)).frame(width: 200, height: 200).blur(radius: 20)
                Circle().fill(Color.deepRose.opacity(0.1)).frame(width: 160, height: 160).offset(x: -20, y: -20).blur(radius: 15)
                Image(systemName: "drop.fill").resizable().scaledToFit().frame(width: 100, height: 100).foregroundStyle(LinearGradient.aqua)
            }
            
            VStack(spacing: 20) {
                Text("水分補給サポーター").font(.system(size: 40, weight: .light, design: .rounded))
                Text("内側から輝く美しさを").font(.system(size: 20, weight: .medium, design: .rounded)).foregroundColor(Color.accentRose)
                Text("水分補給で叶える、理想の私へ").font(.bodyText).multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            
            Spacer()
            HStack(spacing: 8) {
                Text("スワイプして詳細を見る")
                Image(systemName: "arrow.right")
            }.font(.captionText).padding(.bottom, 40)
        }.foregroundColor(.black)
    }
}

struct BeautyBenefitsPage: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 60)).foregroundStyle(LinearGradient.accent)
                Text("美容効果").font(.pageTitle)
            }
            VStack(spacing: 24) {
                BenefitCard(icon: "face.smiling", title: "透明感のある肌", description: "十分な水分で肌の新陳代謝を促進\n内側からツヤとハリをサポート")
                BenefitCard(icon: "drop.triangle", title: "むくみ解消", description: "適切な水分摂取で老廃物を排出\nすっきりとしたフェイスラインに")
                BenefitCard(icon: "leaf", title: "アンチエイジング", description: "細胞レベルでの水分補給により\n肌の弾力性を維持")
            }
            Spacer()
        }.padding(.horizontal, 20).foregroundColor(.black)
    }
}

struct HealthBenefitsPage: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "heart.fill").font(.system(size: 60)).foregroundStyle(LinearGradient.accent)
                Text("健康効果").font(.pageTitle)
            }
            VStack(spacing: 24) {
                BenefitCard(icon: "flame", title: "代謝アップ", description: "基礎代謝を約30%向上させ\n自然なダイエット効果をサポート")
                BenefitCard(icon: "brain.head.profile", title: "集中力向上", description: "脳への十分な酸素供給で\n思考力とパフォーマンスが向上")
                BenefitCard(icon: "figure.walk", title: "疲労回復", description: "血液循環を改善し\n日々の疲れをリフレッシュ")
            }
            Spacer()
        }.padding(.horizontal, 20).foregroundColor(.black)
    }
}

struct AppFeaturesPage: View {
    @AppStorage("hasSeenIntro") var hasSeenIntro: Bool = false
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "app.gift").font(.system(size: 60)).foregroundStyle(LinearGradient.accent)
                Text("アプリ機能").font(.pageTitle)
            }
            
            VStack(spacing: 20) {
                FeatureRow(icon: "chart.pie", text: "見やすい進捗表示")
                FeatureRow(icon: "calendar", text: "連続記録カレンダー")
                FeatureRow(icon: "bell", text: "やさしいリマインダー")
                FeatureRow(icon: "chart.bar", text: "詳細な履歴グラフ")
            }
            
            Spacer()
            
            if !hasSeenIntro {
                NavigationLink(destination: SetupView()) {
                    HStack {
                        Text("初期設定に進む").font(.system(size: 18, weight: .medium, design: .rounded))
                        Image(systemName: "arrow.right").font(.system(size: 16, weight: .medium))
                    }
                    .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(LinearGradient.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color.accentRose.opacity(0.4), radius: 12, x: 0, y: 6)
                }
                .isDetailLink(false).padding(.horizontal, 32).padding(.bottom, 100)
            } else {
                Spacer(minLength: 100)
            }
        }.foregroundColor(.black)
    }
}

struct BenefitCard: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 24)).foregroundColor(Color.accentRose).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(description).font(.bodyText).foregroundColor(.black.opacity(0.7)).lineLimit(nil)
            }
            Spacer()
        }
        .padding(16).background(Color.white.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.shadowGray.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20)).foregroundColor(Color.accentRose).frame(width: 30)
            Text(text).font(.mediumText)
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundColor(Color.accentRose)
        }.padding(.horizontal, 20)
    }
}

struct SetupView: View {
    @AppStorage("hasSeenIntro") var hasSeenIntro: Bool = false
    @ObservedObject var goalManager = GoalManager.shared
    @ObservedObject var notificationManager = StableNotificationManager.shared
    
    @State private var isGoalSet = false
    @State private var isNotificationSet = false
    @State private var showStep1 = false
    @State private var showStep2 = false
    @State private var showButton = false
    
    var body: some View {
        ZStack {
            LinearGradient.background.ignoresSafeArea()
            
            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 16) {
                    Text("はじめに").font(.system(size: 36, weight: .light, design: .rounded))
                    Text("美しい習慣を始めるために、\nまずは目標を設定しましょう。")
                        .font(.bodyText).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).lineSpacing(4)
                }
                
                VStack(spacing: 20) {
                    if showStep1 {
                        SetupStepView(step: "1", title: "目標設定", description: "1日の水分補給量を決めましょう", icon: "target", isCompleted: isGoalSet) {
                            GoalSettingsView()
                        }.transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                    }
                    if showStep2 {
                        SetupStepView(step: "2", title: "通知設定（任意）", description: "リマインダーで飲み忘れを防ぎます", icon: "bell.badge", isCompleted: isNotificationSet) {
                            StableNotificationSettingsView()
                        }.transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                
                Spacer()
                
                if showButton {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.spring()) { hasSeenIntro = true }
                    }) {
                        Text("水分補給サポーターを始める").font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(
                                LinearGradient(
                                    colors: allStepsCompleted() ? [Color.accentRose, Color.deepRose] : [Color.gray.opacity(0.4), Color.gray.opacity(0.6)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: allStepsCompleted() ? Color.accentRose.opacity(0.4) : .clear, radius: 12, x: 0, y: 6)
                    }
                    .disabled(!allStepsCompleted())
                    .padding(.horizontal, 32).padding(.bottom, 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            checkCompletionStatus()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3)) { showStep1 = true }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.5)) { showStep2 = true }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.7)) { showButton = true }
        }
    }
    
    private func checkCompletionStatus() {
        isGoalSet = goalManager.isGoalCustomized()
        isNotificationSet = notificationManager.isNotificationEnabled
    }
    
    private func allStepsCompleted() -> Bool {
        return isGoalSet
    }
}

struct SetupStepView<Destination: View>: View {
    let step: String, title: String, description: String, icon: String
    let isCompleted: Bool
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(isCompleted ? Color.accentRose : Color.gray.opacity(0.3), lineWidth: 2).frame(width: 50, height: 50)
                    if isCompleted {
                        Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).foregroundColor(Color.accentRose).transition(.scale.combined(with: .opacity))
                    } else {
                        Text(step).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(.secondary)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 18, weight: .medium, design: .rounded)).foregroundColor(.primary)
                    Text(description).font(.bodyText).foregroundColor(.secondary)
                }
                
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .medium)).foregroundColor(.gray.opacity(0.5))
            }
            .padding(16).background(Color(uiColor: .systemBackground)).clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.shadowGray.opacity(0.3), radius: 10, x: 0, y: 5)
        }
        .animation(.spring(), value: isCompleted)
    }
}

// MARK: - Calendar & Chart Components

struct ImprovedCalendarView: View {
    @ObservedObject var store = WaterStore.shared
    @ObservedObject var goalManager = GoalManager.shared
    @State private var selectedDate: Date = Date()
    @State private var currentMonthIndex: Int = 0
    
    private let calendar = Calendar.current
    private let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "yyyy年M月"; return f
    }()
    
    private var monthsData: [(date: Date, index: Int)] {
        ( -6...6 ).compactMap { i in
            calendar.date(byAdding: .month, value: i, to: Date()).map { ($0, i) }
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Text(monthFormatter.string(from: selectedDate))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.accentRose)
                Spacer()
            }.padding(.horizontal)
            
            HStack {
                ForEach(["日", "月", "火", "水", "木", "金", "土"], id: \.self) { weekday in
                    Text(weekday).font(.captionText).foregroundColor(.secondary).frame(maxWidth: .infinity)
                }
            }
            
            TabView(selection: $currentMonthIndex) {
                ForEach(monthsData, id: \.index) { monthData in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
                        ForEach(calendarDates(for: monthData.date), id: \.self) { date in
                            CalendarDayCell(
                                date: date, intake: store.intake(on: date), goal: goalManager.dailyGoal,
                                isToday: calendar.isDateInToday(date),
                                isCurrentMonth: calendar.isDate(date, equalTo: monthData.date, toGranularity: .month)
                            )
                        }
                    }.tag(monthData.index)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never)).frame(height: 250)
            .onChange(of: currentMonthIndex) { newIndex in
                if let newDate = calendar.date(byAdding: .month, value: newIndex, to: Date()) {
                    selectedDate = newDate
                }
            }
            
            HStack(spacing: 20) {
                LegendItem(color: Color.shadowGray.opacity(0.3), text: "未記録")
                LegendItem(color: Color.accentRose.opacity(0.4), text: "一部達成")
                LegendItem(color: Color.accentRose, text: "目標達成")
            }.font(.system(size: 12, weight: .medium, design: .rounded))
        }
    }
    
    private func calendarDates(for monthDate: Date) -> [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: monthDate) else { return [] }
        let firstOfMonth = monthInterval.start
        let daysFromSunday = (calendar.component(.weekday, from: firstOfMonth) - 1)
        guard let startDate = calendar.date(byAdding: .day, value: -daysFromSunday, to: firstOfMonth) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: startDate) }
    }
}

struct CalendarDayCell: View {
    let date: Date, intake: Int, goal: Int, isToday: Bool, isCurrentMonth: Bool
    private let calendar = Calendar.current
    
    var body: some View {
        VStack(spacing: 4) {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 14, weight: isToday ? .bold : .medium, design: .rounded))
                .foregroundColor(isToday ? Color.accentRose : .primary)
            
            Circle().frame(width: 8, height: 8).foregroundColor(circleColor)
        }.frame(width: 40, height: 50).opacity(isCurrentMonth ? 1.0 : 0.3)
    }
    
    private var circleColor: Color {
        guard isCurrentMonth else { return .clear }
        if intake >= goal { return Color.accentRose }
        if intake > 0 { return Color.accentRose.opacity(0.4) }
        return Color.shadowGray.opacity(0.3)
    }
}

struct LegendItem: View {
    let color: Color, text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().frame(width: 10, height: 10).foregroundColor(color)
            Text(text).foregroundColor(.secondary)
        }
    }
}

struct ModernBarChart: View {
    let values: [Int], maxValue: Int
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(values.indices, id: \.self) { i in
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.1)).frame(height: 100)
                        if values[i] > 0 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(i == values.count - 1 ? LinearGradient.aqua : LinearGradient.lightAqua)
                                .frame(height: max(8, CGFloat(values[i]) / CGFloat(maxValue) * 100))
                                .shadow(color: Color.aquaBlue.opacity(0.2), radius: 2, x: 0, y: 1)
                        }
                    }
                    Text(shortDayLabel(offset: i)).font(.captionText)
                        .foregroundColor(i == values.count - 1 ? Color.deepAqua : .secondary)
                }
            }
        }.animation(.easeInOut, value: values)
    }

    func shortDayLabel(offset: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: -(6 - offset), to: Date())!
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "ja_JP"); fmt.dateFormat = "E"
        return fmt.string(from: d)
    }
}

// MARK: - Extensions for Color & Font

extension Color {
    static let softPink = Color(red: 0.98, green: 0.94, blue: 0.96)
    static let blushPink = Color(red: 0.96, green: 0.91, blue: 0.94)
    static let accentRose = Color(red: 0.91, green: 0.54, blue: 0.73)
    static let deepRose = Color(red: 0.82, green: 0.41, blue: 0.64)
    static let lavenderMist = Color(red: 0.95, green: 0.93, blue: 0.98)
    static let shadowGray = Color(red: 0.91, green: 0.91, blue: 0.93)
    static let aquaBlue = Color(red: 0.40, green: 0.85, blue: 0.95)
    static let deepAqua = Color(red: 0.20, green: 0.70, blue: 0.90)
    static let lightAqua = Color(red: 0.70, green: 0.92, blue: 0.98)
    static let crystalBlue = Color(red: 0.55, green: 0.88, blue: 0.96)
}

extension LinearGradient {
    static let background = LinearGradient(colors: [Color.softPink, Color.blushPink], startPoint: .top, endPoint: .bottom)
    static let accent = LinearGradient(colors: [Color.accentRose, Color.deepRose], startPoint: .leading, endPoint: .trailing)
    static let aqua = LinearGradient(colors: [Color.crystalBlue, Color.deepAqua], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let lightAqua = LinearGradient(colors: [Color.lightAqua, Color.aquaBlue], startPoint: .top, endPoint: .bottom)
}

extension Font {
    static let titleText = Font.system(size: 20, weight: .medium, design: .rounded)
    static let mediumText = Font.system(size: 16, weight: .medium, design: .rounded)
    static let bodyText = Font.system(size: 14, weight: .regular, design: .rounded)
    static let captionText = Font.system(size: 12, weight: .medium, design: .rounded)
    static let semiboldCaption = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let pageTitle = Font.system(size: 28, weight: .light, design: .rounded)
}
