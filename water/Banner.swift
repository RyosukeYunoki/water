import SwiftUI
import GoogleMobileAds

struct BannerAdView: UIViewRepresentable {
    // テスト用広告ID（本番ではAdMobの管理画面のIDに変更）
    private let adUnitID = "ca-app-pub-3437354845588114/8518173942"

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = adUnitID
        banner.rootViewController = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}

