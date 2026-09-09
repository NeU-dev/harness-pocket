import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

struct DraftAttachment: Identifiable, Codable {
    let id: String
    let name: String
    let kind: String
    let mediaType: String
    let size: Int
    var url: URL { Self.directory.appendingPathComponent(id) }
    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Attachments")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func make(data: Data, name: String, image: Bool) throws -> DraftAttachment {
        var bytes = data
        var fileName = name
        if image {
            guard let source = UIImage(data: data) else { throw PocketError.message("画像を読み込めませんでした") }
            let scale = min(1, 2048 / max(source.size.width, source.size.height))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: CGSize(width: source.size.width * scale, height: source.size.height * scale), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: CGSize(width: source.size.width * scale, height: source.size.height * scale)))
                source.draw(in: CGRect(x: 0, y: 0, width: source.size.width * scale, height: source.size.height * scale))
            }
            guard let jpeg = rendered.jpegData(compressionQuality: 0.85) else { throw PocketError.message("画像を変換できませんでした") }
            bytes = jpeg; fileName = (name as NSString).deletingPathExtension + ".jpg"
        }
        guard bytes.count <= 10 * 1024 * 1024 else { throw PocketError.message("添付は1個10MBまでです") }
        let item = DraftAttachment(id: UUID().uuidString, name: fileName, kind: image ? "image" : "file", mediaType: image ? "image/jpeg" : "application/octet-stream", size: bytes.count)
        try bytes.write(to: item.url, options: [.atomic, .completeFileProtection])
        return item
    }
    func payload() throws -> [String: Any] { ["name": name, "kind": kind, "mediaType": mediaType, "data": try Data(contentsOf: url).base64EncodedString()] }
}

struct AttachmentStrip: View {
    let items: [DraftAttachment]
    var remove: ((DraftAttachment) -> Void)?
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    HStack(spacing: 7) {
                        if item.kind == "image" {
                            DraftThumbnail(item: item)
                        } else { Image(systemName: "doc").foregroundStyle(PocketTheme.accent) }
                        VStack(alignment: .leading) { Text(item.name).lineLimit(1); Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)).foregroundStyle(PocketTheme.secondary) }.font(.caption).frame(maxWidth: 150)
                        if let remove { Button { remove(item) } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("\(item.name)を外す") }
                    }.padding(8).background(PocketTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }.scrollIndicators(.hidden).foregroundStyle(PocketTheme.text)
    }
}

private struct DraftThumbnail: View {
    let item: DraftAttachment
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo") }
        }.frame(width: 42, height: 42).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
            .task(id: item.id) {
                let url = item.url
                image = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 126, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil as UIImage? }
                    return UIImage(cgImage: thumbnail)
                }.value
            }
    }
}

struct MessageAttachment: Identifiable, Equatable {
    let id: String
    let kind: String
    let name: String
    let path: String
    init(_ value: [String: Any]) {
        id = value["attachmentId"] as? String ?? value["path"] as? String ?? UUID().uuidString
        kind = value["kind"] as? String ?? "file"
        name = value["name"] as? String ?? "添付ファイル"
        path = value["path"] as? String ?? ""
    }
}
struct SentAttachmentView: View {
    @EnvironmentObject var model: AppModel
    let attachment: MessageAttachment
    @State private var image: UIImage?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 250).clipShape(RoundedRectangle(cornerRadius: 12)) }
            Label(attachment.name, systemImage: attachment.kind == "image" ? "photo" : "doc").font(.caption)
            if let error { Text(error).font(.caption).foregroundStyle(PocketTheme.secondary) }
        }.task(id: attachment.id) {
            guard attachment.kind == "image", let api = model.api, let sessionID = model.currentID else { return }
            do {
                let result = try await api.request("v1/sessions/\(sessionID)/attachment", query: [URLQueryItem(name: "id", value: attachment.id)])
                if let base64 = result["data"] as? String, let bytes = Data(base64Encoded: base64) { image = UIImage(data: bytes) }
            } catch { self.error = "画像を読み込めませんでした" }
        }
    }
}
