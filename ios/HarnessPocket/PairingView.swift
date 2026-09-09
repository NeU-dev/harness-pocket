import SwiftUI
import VisionKit

struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @State private var url = ""
    @State private var code = ""
    @State private var showScanner = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "sparkle").font(.system(size: 50, weight: .light)).foregroundStyle(PocketTheme.accent).padding(.top, 50)
                    Text("あなたのDGXを、\nもっと身近に。").font(.system(size: 34, weight: .semibold, design: .rounded)).lineSpacing(7)
                    Text("自宅のAIと話すための、小さな入口。\n最初にDGX SparkとiPhoneをつなぎます。").font(.subheadline).foregroundStyle(PocketTheme.secondary).lineSpacing(5)
                    VStack(alignment: .leading, spacing: 17) {
                        VStack(alignment: .leading, spacing: 7) { Text("接続先").font(.caption.weight(.medium)).foregroundStyle(PocketTheme.secondary); TextField("https://spark-…ts.net:8443", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        Divider()
                        VStack(alignment: .leading, spacing: 7) { Text("端末登録コード").font(.caption.weight(.medium)).foregroundStyle(PocketTheme.secondary); TextField("DGXで発行したコード", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.system(.body, design: .monospaced)) }
                    }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 22))
                    Button { Task { await model.pair(url: url, code: code) } } label: { HStack { Spacer(); if model.busy { ProgressView().tint(.white) } else { Text("DGXと接続する").fontWeight(.semibold); Image(systemName: "arrow.right") }; Spacer() }.padding(17).foregroundStyle(.white).background(PocketTheme.buttonFill, in: Capsule()) }.disabled(model.busy || code.isEmpty || url.isEmpty)
                    if DataScannerViewController.isSupported { Button { showScanner = true } label: { Label("QRコードを読み取る", systemImage: "qrcode.viewfinder") }.frame(maxWidth: .infinity) }
                    Text("外出先ではiPhoneのTailscaleをオンにしてください。登録コードはDGX側で発行し、10分間・1回のみ有効です。").font(.caption).foregroundStyle(PocketTheme.secondary).lineSpacing(4)
                }.padding(.horizontal, 27).padding(.bottom, 30).frame(maxWidth: 600)
            }.background(PocketTheme.background).task { url = model.serverURL }
                .sheet(isPresented: $showScanner) { QRScanner { text in
                    guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: String], let server = json["url"], let value = json["code"] else { model.error = "Harness Pocketの登録QRコードを読み取ってください"; showScanner = false; return }
                    url = server; code = value; showScanner = false
                } }
        }
    }
}
struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var handled = false
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !handled else { return }
            for item in addedItems { if case .barcode(let barcode) = item, let value = barcode.payloadStringValue { handled = true; dataScanner.stopScanning(); onCode(value); break } }
        }
    }
}
