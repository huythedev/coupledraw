import XCTest
import PencilKit
import UniformTypeIdentifiers
import UIKit
@testable import CoupleDraw

@MainActor final class CanvasStoreTests: XCTestCase {
    private func temporaryStore() -> (CanvasStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (CanvasStore(root: root), root)
    }

    func testEditingOneCanvasDoesNotChangeOther() {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let partnerBefore = store.record(.second)
        store.updateBackground("#123456", on: .first)
        store.updateDrawing(PKDrawing().dataRepresentation(), on: .first)
        XCTAssertEqual(store.record(.second), partnerBefore)
        XCTAssertNotEqual(store.record(.first).canvasID, partnerBefore.canvasID)
        XCTAssertEqual(store.record(.first).backgroundHex, "#123456")
    }

    func testReloadPreservesSeparateCanvasIDsAndBackgrounds() {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.updateBackground("#ABCDEF", on: .first)
        store.updateBackground("#000000", on: .second)
        let reloaded = CanvasStore(root: root)
        XCTAssertEqual(reloaded.record(.first).canvasID, store.pair.firstCanvasID)
        XCTAssertEqual(reloaded.record(.second).canvasID, store.pair.secondCanvasID)
        XCTAssertEqual(reloaded.record(.first).backgroundHex, "#ABCDEF")
        XCTAssertEqual(reloaded.record(.second).backgroundHex, "#000000")
    }

    func testApplyCapturesImmutableRevisionAndRestoresOnlyItsCanvas() {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.updateBackground("#FF0000", on: .first)
        XCTAssertNotNil(store.apply(.first))
        let revision = try! XCTUnwrap(store.revisions.first)
        store.updateBackground("#0000FF", on: .first)
        XCTAssertEqual(revision.document.backgroundHex, "#FF0000")
        let partnerBefore = store.record(.second)
        store.restore(revision, to: .second)
        XCTAssertEqual(store.record(.second), partnerBefore)
        store.restore(revision, to: .first)
        XCTAssertEqual(store.record(.first).backgroundHex, "#FF0000")
    }

    func testDeleteAllRevisionsOnlyRemovesSelectedCanvasAndItsImages() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.updateBackground("#123456", on: .first)
        XCTAssertNotNil(store.apply(.first))
        XCTAssertNotNil(store.apply(.first))
        XCTAssertNotNil(store.apply(.together))
        let removed = store.revisions.filter { $0.canvasID == store.record(.first).canvasID }
        let kept = try XCTUnwrap(store.revisions.first { $0.canvasID == store.record(.together).canvasID })
        store.deleteAllRevisions(on: .first)
        XCTAssertEqual(store.revisions.map(\.id), [kept.id])
        XCTAssertEqual(store.record(.first).backgroundHex, "#123456")
        XCTAssertTrue(removed.allSatisfy { !FileManager.default.fileExists(atPath: store.imageURL(for: $0).path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(for: kept).path))
        XCTAssertEqual(CanvasStore(root: root).revisions.map(\.id), [kept.id])
    }

    func testClearDrawingPreservesBackgroundOtherCanvasAndAppliedHistory() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.updateBackground("#123456", on: .first)
        let other = store.record(.together)
        XCTAssertNotNil(store.apply(.first))
        let point = PKStrokePoint(location: CGPoint(x: 40, y: 40), timeOffset: 0,
                                  size: CGSize(width: 6, height: 6), opacity: 1, force: 1,
                                  azimuth: 0, altitude: .pi / 2)
        let stroke = PKStroke(ink: PKInk(.pen, color: .white),
                              path: PKStrokePath(controlPoints: [point], creationDate: Date()))
        store.updateDrawing(PKDrawing(strokes: [stroke]).dataRepresentation(), on: .first)
        store.clearCurrentDrawing(on: .first)
        XCTAssertTrue(try PKDrawing(data: store.record(.first).drawingData).strokes.isEmpty)
        XCTAssertEqual(store.record(.first).backgroundHex, "#123456")
        XCTAssertEqual(store.record(.together), other)
        XCTAssertEqual(store.revisions.count, 1)
        XCTAssertTrue(try PKDrawing(data: CanvasStore(root: root).record(.first).drawingData).strokes.isEmpty)
        store.clearCurrentDrawing(on: .second)
        XCTAssertEqual(store.record(.second).drawingData, Data())
    }

    func testSharedDraftLayersRemainSeparateAndApplyCombinesThem() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        func stroke(_ x: CGFloat) -> PKStroke {
            let point = PKStrokePoint(location: CGPoint(x: x, y: 200), timeOffset: 0,
                                      size: CGSize(width: 6, height: 6), opacity: 1,
                                      force: 1, azimuth: 0, altitude: .pi / 2)
            return PKStroke(ink: PKInk(.pen, color: .white),
                            path: PKStrokePath(controlPoints: [point], creationDate: Date()))
        }
        let base = PKDrawing(strokes: [stroke(20)]).dataRepresentation()
        let own = PKDrawing(strokes: [stroke(100)]).dataRepresentation()
        let partner = PKDrawing(strokes: [stroke(200)]).dataRepresentation()
        let baseRevision = SyncedRevision(source: "together", revision: 1, author: "A",
                                          backgroundHex: "#000000", backgroundPhoto: nil,
                                          drawingData: base, drawingHeight: store.record(.together).drawingHeight)
        try store.setSharedBase(baseRevision)
        store.enableLiveShared()
        store.updateSharedOwn(own)
        try store.updateSharedPartner(partner, drawingHeight: store.record(.together).drawingHeight)
        XCTAssertEqual(try PKDrawing(data: store.sharedReadOnlyData).strokes.count, 2)
        XCTAssertEqual(try PKDrawing(data: store.displayedRecord(.together).drawingData).strokes.count, 3)
        XCTAssertNotNil(store.apply(.together))
        XCTAssertEqual(try PKDrawing(data: XCTUnwrap(store.revisions.first).document.drawingData).strokes.count, 3)
        let applied = SyncedRevision(source: "together", revision: 2, author: "B",
                                     backgroundHex: "#123456", backgroundPhoto: nil,
                                     drawingData: store.displayedRecord(.together).drawingData,
                                     drawingHeight: store.record(.together).drawingHeight)
        try store.acceptRemote(applied, on: .together, localRole: "A", keepSharedBase: true)
        XCTAssertEqual(try PKDrawing(data: store.record(.together).drawingData).strokes.count, 1)
        XCTAssertEqual(try PKDrawing(data: store.displayedRecord(.together).drawingData).strokes.count, 3)
        XCTAssertEqual(store.revisions.first?.document.backgroundHex, "#123456")
        let reloaded = CanvasStore(root: root)
        reloaded.enableLiveShared()
        XCTAssertEqual(try PKDrawing(data: reloaded.displayedRecord(.together).drawingData).strokes.count, 3)
    }

    func testRendererUsesRequestedDeviceDimensions() throws {
        let record = CanvasRecord(ownerID: UUID(), backgroundHex: "#000000",
                                  targetSize: WallpaperSize(width: 1179, height: 2556))
        let image = try WallpaperRenderer.render(record)
        XCTAssertEqual(image.cgImage?.width, 1179)
        XCTAssertEqual(image.cgImage?.height, 2556)
        XCTAssertEqual(record.drawingSize.width / record.drawingSize.height,
                       CGFloat(1179) / CGFloat(2556), accuracy: 0.00001)
    }

    func testPhotoCanShrinkAndPanPastCanvasEdges() {
        let canvas = CGSize(width: 390, height: 844)
        let image = CGSize(width: 1600, height: 900)
        let fitted = BackgroundPhotoLayout.rect(imageSize: image, canvasSize: canvas,
                                                zoom: 1, offsetX: 0, offsetY: 0)
        XCTAssertLessThanOrEqual(fitted.minX, 0)
        XCTAssertLessThanOrEqual(fitted.minY, 0)
        XCTAssertGreaterThanOrEqual(fitted.maxX, canvas.width)
        XCTAssertGreaterThanOrEqual(fitted.maxY, canvas.height)
        let shrunk = BackgroundPhotoLayout.rect(imageSize: image, canvasSize: canvas,
                                                zoom: 0.1, offsetX: 0.5, offsetY: -0.25)
        XCTAssertEqual(shrunk.width, fitted.width * 0.1, accuracy: 0.001)
        XCTAssertEqual(shrunk.midX, canvas.width, accuracy: 0.001)
        XCTAssertEqual(shrunk.midY, canvas.height * 0.25, accuracy: 0.001)
        let zoomed = BackgroundPhotoLayout.rect(imageSize: image, canvasSize: canvas,
                                                zoom: 2, offsetX: 0, offsetY: 0)
        XCTAssertEqual(zoomed.width, fitted.width * 2, accuracy: 0.001)
    }

    func testOlderPhotoWithoutRotationDecodesAsUpright() throws {
        let previous = BackgroundPhoto(data: Data([1, 2, 3]), zoom: 0.4,
                                       offsetX: 0.2, offsetY: -0.1)
        let encoded = try JSONEncoder().encode(previous)
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        values.removeValue(forKey: "rotation")
        let oldData = try JSONSerialization.data(withJSONObject: values)
        XCTAssertEqual(try JSONDecoder().decode(BackgroundPhoto.self, from: oldData), previous)
    }

    func testWallpaperRenderUsesPhotoRotation() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 50)).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 50, y: 0, width: 50, height: 50))
        }
        var record = CanvasRecord(ownerID: UUID(), targetSize: WallpaperSize(width: 390, height: 844))
        record.backgroundPhoto = BackgroundPhoto(data: try XCTUnwrap(image.pngData()),
                                                 zoom: 0.2, rotation: 0)
        let upright = try WallpaperRenderer.render(record)
        record.backgroundPhoto?.rotation = 90
        let tilted = try WallpaperRenderer.render(record)
        XCTAssertNotEqual(upright.pngData(), tilted.pngData())
    }

    func testPhotoBackgroundSurvivesApplyReloadAndRemoteRevision() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let photo = BackgroundPhoto(data: try XCTUnwrap(image.jpegData(compressionQuality: 0.8)),
                                    zoom: 0.4, offsetX: 0.2, offsetY: -0.1, rotation: 27)
        let prepared = try BackgroundPhotoLayout.importJPEG(photo.data)
        XCTAssertLessThanOrEqual(prepared.count, 900_000)
        store.updateBackgroundPhoto(photo, on: .first)
        XCTAssertNotNil(store.apply(.first))
        let withPhoto = try WallpaperRenderer.render(store.record(.first))
        var withoutPhoto = store.record(.first)
        withoutPhoto.backgroundPhoto = nil
        XCTAssertNotEqual(withPhoto.pngData(), try WallpaperRenderer.render(withoutPhoto).pngData())
        XCTAssertEqual(CanvasStore(root: root).record(.first).backgroundPhoto, photo)
        XCTAssertEqual(store.revisions.first?.document.backgroundPhoto, photo)
        let remote = SyncedRevision(source: "a", revision: 1, author: "A",
                                    backgroundHex: "#000000", backgroundPhoto: photo,
                                    drawingData: Data(), drawingHeight: 844)
        try store.acceptRemote(remote, on: .second, localRole: "B")
        XCTAssertEqual(store.record(.second).backgroundPhoto, photo)
        store.updateBackground("#FFFFFF", on: .first)
        XCTAssertNil(store.record(.first).backgroundPhoto)
    }

    func testWhiteInkOnBlackWallpaperDoesNotChangeWithDeviceAppearance() throws {
        var record = CanvasRecord(ownerID: UUID(), backgroundHex: "#000000",
                                  targetSize: WallpaperSize(width: 390, height: 844))
        let points = (0..<5).map { index in
            PKStrokePoint(location: CGPoint(x: CGFloat(80 + index * 20), y: 100),
                          timeOffset: Double(index) / 60, size: CGSize(width: 14, height: 14),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: .white), path: path)
        record.drawingData = PKDrawing(strokes: [stroke]).dataRepresentation()
        var light: UIImage?
        var dark: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            light = try? WallpaperRenderer.render(record)
        }
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            dark = try? WallpaperRenderer.render(record)
        }
        let blank = try WallpaperRenderer.render(CanvasRecord(ownerID: UUID(),
                                  backgroundHex: "#000000", targetSize: record.targetSize))
        XCTAssertNotEqual(light?.pngData(), blank.pngData())
        XCTAssertEqual(light?.pngData(), dark?.pngData())
    }

    func testPartnerTargetChangeNeverChangesMine() {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = store.record(.first)
        store.updateTargetSize(WallpaperSize(width: 1206, height: 2622), on: .second)
        XCTAssertEqual(store.record(.first), mine)
        XCTAssertEqual(store.record(.second).targetSize.width, 1206)
        XCTAssertEqual(store.record(.second).targetSize.height, 2622)
        XCTAssertEqual(store.record(.second).drawingSize.width / store.record(.second).drawingSize.height,
                       CGFloat(1206) / CGFloat(2622), accuracy: 0.00001)
        let url = try! XCTUnwrap(store.apply(.second))
        let exported = try! XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        XCTAssertEqual(exported.width, 1206)
        XCTAssertEqual(exported.height, 2622)
    }

    func testLegacyCanvasMigratesFromFixedAspect() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.updateBackground("#123456", on: .first)
        let path = root.appendingPathComponent("first.json")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        old.removeValue(forKey: "targetSize")
        old.removeValue(forKey: "drawingHeight")
        try JSONSerialization.data(withJSONObject: old).write(to: path, options: .atomic)
        let reloaded = CanvasStore(root: root)
        XCTAssertEqual(reloaded.record(.first).drawingHeight,
                       WallpaperSize.thisIPhone.drawingHeight, accuracy: 0.00001)
        XCTAssertEqual(reloaded.record(.first).backgroundHex, "#123456")
    }

    func testThreeWallpaperChoicesUseIndependentCanvasIDs() {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = Set(WallpaperChoice.allCases.map { store.record($0.slot).canvasID })
        XCTAssertEqual(ids.count, 3)
        store.updateBackground("#AABBCC", on: .together)
        XCTAssertEqual(store.record(.first).backgroundHex, "#000000")
        XCTAssertEqual(store.record(.second).backgroundHex, "#000000")
        XCTAssertNotNil(store.apply(.together))
        XCTAssertEqual(store.revisions.first?.canvasID, store.record(.together).canvasID)
    }

    func testRemoteRevisionMapsToOneLocalCanvasAndKeepsItsTarget() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.updateTargetSize(WallpaperSize(width: 1179, height: 2556), on: .second)
        let mine = store.record(.first)
        let remote = SyncedRevision(source: "a", revision: 1, author: "A",
                                    backgroundHex: "#123456", backgroundPhoto: nil,
                                    drawingData: Data(), drawingHeight: 844)
        try store.acceptRemote(remote, on: .second, localRole: "B")
        XCTAssertEqual(store.record(.first), mine)
        XCTAssertEqual(store.record(.second).targetSize.width, 1179)
        XCTAssertEqual(store.record(.second).backgroundHex, "#123456")
        XCTAssertEqual(store.revisions.first?.authorID, store.pair.partnerUserID)
    }

    func testPairingURLAllowsPrivateHTTPAndPublicHTTPS() {
        for address in ["http://192.168.1.20:8787", "http://10.0.0.5:8787",
                        "http://172.16.0.2:8787", "http://172.31.255.2:8787",
                        "http://100.111.112.50:8787", "http://100.64.0.1:8787",
                        "http://100.127.255.254:8787", "http://my-mac.local:8787",
                        "https://pair.example.com"] {
            XCTAssertTrue(PairSync.allowsServerURL(URL(string: address)!), address)
        }
        for address in ["http://8.8.8.8:8787", "http://100.63.255.255:8787",
                        "http://100.128.0.1:8787", "http://172.32.0.2:8787",
                        "http://pair.example.com", "http://192.168.1.20:8787/other",
                        "http://user:pass@192.168.1.20:8787"] {
            XCTAssertFalse(PairSync.allowsServerURL(URL(string: address)!), address)
        }
    }

    func testInlinePhotoMigrationDeduplicatesFilesAndKeepsNetworkEncoding() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = BackgroundPhoto(data: Data([1, 2, 3]), rotation: 15)
        var old = store.record(.first)
        old.backgroundPhoto = photo
        try JSONEncoder().encode(old).write(to: root.appendingPathComponent("first.json"))
        let revision = AppliedRevision(id: UUID(), canvasID: old.canvasID, authorID: store.pair.myUserID,
                                       createdAt: Date(), document: old, imageFilename: "unused.png")
        try JSONEncoder().encode([revision]).write(to: root.appendingPathComponent("revisions.json"))
        let reloaded = CanvasStore(root: root)
        XCTAssertEqual(reloaded.record(.first).backgroundPhoto, photo)
        XCTAssertEqual(reloaded.revisions.first?.document.backgroundPhoto, photo)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("first.json"))) as? [String: Any])
        let storedPhoto = try XCTUnwrap(manifest["backgroundPhoto"] as? [String: Any])
        XCTAssertNil(storedPhoto["data"])
        XCTAssertNotNil(storedPhoto["file"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: LocalMediaFiles.folder(root).path).count, 1)
        XCTAssertEqual(try JSONDecoder().decode(BackgroundPhoto.self, from: JSONEncoder().encode(photo)), photo)
    }

    func testClearCacheKeepsDraftsHistoryAndRegeneratesWallpaperOffline() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.red.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let photo = BackgroundPhoto(data: try XCTUnwrap(image.jpegData(compressionQuality: 0.8)))
        store.updateBackgroundPhoto(photo, on: .first)
        let originalURL = try XCTUnwrap(store.apply(.first))
        let originalPNG = try Data(contentsOf: originalURL)
        let revision = try XCTUnwrap(store.revisions.first)
        store.updateBackground("#123456", on: .first)
        let orphan = try LocalMediaFiles.store(Data([7, 8, 9]), root: root)
        XCTAssertGreaterThan(try store.clearCache(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try LocalMediaFiles.path(orphan, root: root).path))
        XCTAssertEqual(store.revisions.count, 1)
        XCTAssertEqual(store.record(.first).backgroundHex, "#123456")
        XCTAssertEqual(try LocalMediaFiles.read(LocalMediaFiles.identifier(photo.data), root: root), photo.data)
        let reloaded = CanvasStore(root: root)
        XCTAssertEqual(reloaded.revisions.first?.document.backgroundPhoto, photo)
        XCTAssertEqual(try Data(contentsOf: reloaded.cachedWallpaperURL(for: revision)), originalPNG)
    }

    func testStickersKeepTransparencyPlacementAndSurviveReloadAndRemoteApply() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 50), format: format).image { context in
            UIColor.green.setFill(); context.cgContext.fill(CGRect(x: 25, y: 10, width: 50, height: 30))
        }
        let data = try StickerImages.prepare(image)
        let sticker = CanvasSticker(data: data, centerX: 0.25, centerY: 0.6, width: 0.3, rotation: 45)
        store.updateStickers([sticker], on: .first)
        XCTAssertNotNil(store.apply(.first))
        XCTAssertEqual(CanvasStore(root: root).record(.first).stickers, [sticker])
        var blank = store.record(.first)
        blank.stickers = []
        XCTAssertNotEqual(try WallpaperRenderer.render(blank).pngData(),
                          try WallpaperRenderer.render(store.record(.first)).pngData())
        var remote = SyncedRevision(source: "a", revision: 1, author: "A", backgroundHex: "#000000",
                                    backgroundPhoto: nil, drawingData: Data(), drawingHeight: 844)
        remote.stickers = [sticker]
        try store.acceptRemote(remote, on: .second, localRole: "B")
        XCTAssertEqual(store.record(.second).stickers, [sticker])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: LocalMediaFiles.folder(root).path).count, 1)
        XCTAssertEqual(try JSONDecoder().decode(CanvasSticker.self, from: JSONEncoder().encode(sticker)), sticker)
        let a = StickerImages.rect(sticker, imageSize: image.size, canvas: CGSize(width: 390, height: 844))
        let b = StickerImages.rect(sticker, imageSize: image.size, canvas: CGSize(width: 780, height: 1688))
        XCTAssertEqual(b.midX, a.midX * 2, accuracy: 0.001)
        XCTAssertEqual(b.width, a.width * 2, accuracy: 0.001)
    }

    func testImagePasteSkipsTextAndUnreadableClipboardItems() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        let broken = NSItemProvider()
        broken.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in
            done(Data([1, 2, 3]), nil); return nil
        }
        let providers = [NSItemProvider(object: "Copied caption" as NSString), broken, NSItemProvider(object: image)]
        let ready = expectation(description: "image copied after caption and broken image")
        StickerImages.load(providers) { result in
            do {
                let loaded = try result.get()
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(loaded.cgImage?.width, image.cgImage?.width)
                XCTAssertEqual(loaded.cgImage?.height, image.cgImage?.height)
            } catch { XCTFail(error.localizedDescription) }
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 10)
    }

    func testImagePasteTriesAlternateDataRepresentation() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 9, height: 7)).image { _ in UIColor.blue.setFill() }
        let png = try XCTUnwrap(image.pngData())
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { done in
            done(Data([0, 1]), nil); return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in
            done(png, nil); return nil
        }
        let ready = expectation(description: "usable PNG after broken JPEG")
        StickerImages.load([provider]) { result in
            do { XCTAssertEqual(try result.get().cgImage?.width, image.cgImage?.width) }
            catch { XCTFail(error.localizedDescription) }
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 10)
    }

    func testUnsupportedAndDamagedPastesReportFailure() async {
        let noImage = expectation(description: "text reports copy-image guidance")
        StickerImages.load([NSItemProvider(object: "https://example.com/picture.png" as NSString)]) { result in
            guard case .failure(let error) = result else { XCTFail("Text must not become a sticker"); noImage.fulfill(); return }
            XCTAssertEqual(error.localizedDescription, StickerImages.ImportError.noImage.localizedDescription)
            noImage.fulfill()
        }
        let damaged = NSItemProvider()
        damaged.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in
            done(Data([1]), nil); return nil
        }
        let unreadable = expectation(description: "damaged image reports error")
        StickerImages.load([damaged]) { result in
            guard case .failure(let error) = result else { XCTFail("Damaged image must not be accepted"); unreadable.fulfill(); return }
            XCTAssertEqual(error.localizedDescription, StickerImages.ImportError.unreadableImage.localizedDescription)
            unreadable.fulfill()
        }
        await fulfillment(of: [noImage, unreadable], timeout: 10)
    }

    func testDrawingCanvasAcceptImageProvidersAndNativePaste() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 5, height: 5)).image { _ in }
        let provider = NSItemProvider(object: image)
        var received = 0

        let canvas = FittedCanvasView()
        canvas.drawingAreaSize = CGSize(width: 390, height: 844)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let controller = UIViewController()
        controller.view = canvas
        window.rootViewController = controller
        window.makeKeyAndVisible()
        canvas.becomeFirstResponder()
        defer { canvas.resignFirstResponder(); window.isHidden = true }
        canvas.onPasteImages = { _ in received += 1 }
        XCTAssertTrue(canvas.canPaste([provider]))
        canvas.paste(itemProviders: [provider])
        XCTAssertEqual(received, 1)

        let clipboard = UIPasteboard.general
        let previous = clipboard.items
        defer { clipboard.items = previous }
        clipboard.image = image
        XCTAssertTrue(canvas.canPerformAction(#selector(canvas.paste(_:)), withSender: nil))
        canvas.paste(nil)
        XCTAssertEqual(received, 2)
        XCTAssertNotNil(canvas.inputView) // image paste keeps the lasso keyboard suppressed
    }

    func testFailedRemoteCanvasWritePreservesHistoryAndCanBeRetried() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNotNil(store.apply(.first))
        let previousIDs = store.revisions.map(\.id)
        let previousPartner = store.record(.second)
        let blocked = root.appendingPathComponent("second.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let remote = SyncedRevision(source: "b", revision: 1, author: "B", backgroundHex: "#123456",
                                    backgroundPhoto: nil, drawingData: Data(), drawingHeight: 844)
        XCTAssertThrowsError(try store.acceptRemote(remote, on: .second, localRole: "A"))
        XCTAssertEqual(store.record(.second), previousPartner)
        XCTAssertEqual(store.revisions.map(\.id), previousIDs)
        XCTAssertEqual(CanvasStore(root: root).revisions.map(\.id), previousIDs)
        try FileManager.default.removeItem(at: blocked)
        try store.acceptRemote(remote, on: .second, localRole: "A")
        XCTAssertEqual(CanvasStore(root: root).record(.second).backgroundHex, "#123456")
        XCTAssertEqual(store.revisions.count, previousIDs.count + 1)
    }

    func testRendererRejectsUnsafeDimensionsBeforeAllocatingAnImage() throws {
        var record = CanvasRecord(ownerID: UUID())
        XCTAssertThrowsError(try WallpaperRenderer.render(record, pixels: CGSize(width: CGFloat.infinity, height: 844)))
        XCTAssertThrowsError(try WallpaperRenderer.render(record, pixels: CGSize(width: 100_000, height: 844)))
        record.drawingHeight = .infinity
        XCTAssertThrowsError(try WallpaperRenderer.render(record))
    }

    func testDecodedImagesAreBoundedAndKeepTransparency() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 30), format: format).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 30))
        }
        let decoded = try XCTUnwrap(BackgroundPhotoLayout.image(XCTUnwrap(image.pngData())))
        XCTAssertLessThanOrEqual(try XCTUnwrap(decoded.cgImage).width, 2600)
        XCTAssertTrue([CGImageAlphaInfo.premultipliedFirst, .premultipliedLast, .first, .last]
            .contains(try XCTUnwrap(decoded.cgImage).alphaInfo))
        XCTAssertNil(BackgroundPhotoLayout.image(Data([1, 2, 3])))
        BackgroundPhotoLayout.clearImageCache()
    }

    private func isolatedSyncPreferences() -> () -> Void {
        let keys = ["syncEndpoint", "syncVersions", "syncDirty", "partnerAlertsEnabled", "syncRetryUntil"]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        return {
            for (key, value) in zip(keys, previous) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    private func stateReply(_ request: URLRequest, role: String = "A", items: [SyncedRevision] = [],
                            etag: String = "\"state\"", board: BoardUpdate? = nil) throws -> (Data, URLResponse) {
        var state: [String: Any] = ["role": role, "items": try JSONSerialization.jsonObject(with: JSONEncoder().encode(items)),
                                   "pushConfigured": false, "hasPartnerArt": !items.isEmpty,
                                   "boardProtocol": 1, "mediaProtocol": 1, "drafts": []]
        if let board { state["board"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(board)) }
        return (try JSONSerialization.data(withJSONObject: state),
                try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200,
                                            httpVersion: "HTTP/1.1", headerFields: ["ETag": etag])))
    }

    func testFailedRemoteRenderIsRetriedWithTheSameServerETag() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date()
        var phase = 0
        var testToken = ""
        let sync = PairSync(transport: { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"partner-v1\"" {
                return (Data(), try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 304,
                                                            httpVersion: "HTTP/1.1", headerFields: nil)))
            }
            let remote = SyncedRevision(source: "b", revision: 1, author: "B", backgroundHex: "#123456",
                                        backgroundPhoto: nil, drawingData: phase == 1 ? Data([1, 2, 3]) : Data(), drawingHeight: 844)
            return try self.stateReply(request, items: phase == 0 ? [] : [remote],
                                       etag: phase == 0 ? "\"initial\"" : "\"partner-v1\"")
        }, readToken: { testToken }, writeToken: { testToken = $0 }, clock: { now })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://audit.invalid", token: "test-private-sync-token-A", store: store)
        sync.stop()
        phase = 1
        await sync.refresh(store: store)
        XCTAssertTrue(sync.status.hasPrefix("Sync paused:"))
        XCTAssertTrue(store.revisions.isEmpty)
        now = now.addingTimeInterval(120)
        phase = 2
        await sync.refresh(store: store)
        XCTAssertEqual(store.record(.second).backgroundHex, "#123456")
        XCTAssertEqual(store.revisions.count, 1)
    }

    func testDelayedPublishCannotModifyANewPairingSession() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploading = expectation(description: "publish waiting for response")
        var reply: CheckedContinuation<(Data, URLResponse), Error>?
        var testToken = ""
        let sync = PairSync(transport: { request in
            if request.httpMethod == "POST" {
                return try await withCheckedThrowingContinuation { reply = $0; uploading.fulfill() }
            }
            return try self.stateReply(request, role: request.url?.host == "new-pair.invalid" ? "B" : "A")
        }, readToken: { testToken }, writeToken: { testToken = $0 })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://audit.invalid", token: "test-private-sync-token-A", store: store)
        sync.stop()
        sync.markDirty(.first)
        let snapshot = store.record(.first)
        let publishing = Task { await sync.publish(snapshot, slot: .first, store: store) }
        await fulfillment(of: [uploading], timeout: 5)
        try await sync.configure(endpoint: "https://new-pair.invalid", token: "test-private-sync-token-B", store: store)
        sync.stop()
        let newStatus = sync.status
        let oldReply = SyncedRevision(source: "a", revision: 1, author: "A", backgroundHex: snapshot.backgroundHex,
                                     backgroundPhoto: nil, drawingData: snapshot.drawingData, drawingHeight: snapshot.drawingHeight)
        try XCTUnwrap(reply).resume(returning: (JSONEncoder().encode(oldReply),
            XCTUnwrap(HTTPURLResponse(url: URL(string: "https://audit.invalid/v1/apply")!, statusCode: 200,
                                     httpVersion: "HTTP/1.1", headerFields: nil))))
        await publishing.value
        XCTAssertEqual(sync.role, "B")
        XCTAssertEqual(sync.status, newStatus)
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: "syncVersions")?[CanvasSlot.first.rawValue])
        XCTAssertTrue(UserDefaults.standard.stringArray(forKey: "syncDirty")?.contains(CanvasSlot.first.rawValue) == true)
    }

    func testEditsMadeDuringPublishStayDirtyAndSurviveRefresh() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploading = expectation(description: "publish waiting for response")
        var reply: CheckedContinuation<(Data, URLResponse), Error>?
        var items: [SyncedRevision] = []
        var testToken = ""
        let sync = PairSync(transport: { request in
            if request.httpMethod == "POST" {
                return try await withCheckedThrowingContinuation { reply = $0; uploading.fulfill() }
            }
            return try self.stateReply(request, items: items)
        }, readToken: { testToken }, writeToken: { testToken = $0 })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://audit.invalid", token: "test-private-sync-token-A", store: store)
        sync.stop()
        sync.markDirty(.first)
        let snapshot = store.record(.first)
        let publishing = Task { await sync.publish(snapshot, slot: .first, store: store) }
        await fulfillment(of: [uploading], timeout: 5)
        store.updateBackground("#ABCDEF", on: .first)
        sync.markDirty(.first)
        let oldReply = SyncedRevision(source: "a", revision: 1, author: "A", backgroundHex: snapshot.backgroundHex,
                                     backgroundPhoto: nil, drawingData: snapshot.drawingData, drawingHeight: snapshot.drawingHeight)
        try XCTUnwrap(reply).resume(returning: (JSONEncoder().encode(oldReply),
            XCTUnwrap(HTTPURLResponse(url: URL(string: "https://audit.invalid/v1/apply")!, statusCode: 200,
                                     httpVersion: "HTTP/1.1", headerFields: nil))))
        await publishing.value
        XCTAssertTrue(UserDefaults.standard.stringArray(forKey: "syncDirty")?.contains(CanvasSlot.first.rawValue) == true)
        items = [SyncedRevision(source: "a", revision: 2, author: "A", backgroundHex: snapshot.backgroundHex,
                                backgroundPhoto: nil, drawingData: snapshot.drawingData, drawingHeight: snapshot.drawingHeight)]
        await sync.refresh(store: store)
        XCTAssertEqual(store.record(.first).backgroundHex, "#ABCDEF")
    }

    func testSyncRedirectPolicyRefusesCredentialForwarding() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = try XCTUnwrap(URL(string: "https://audit.invalid/v1/state"))
        let task = session.dataTask(with: original)
        let redirect = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 302,
                                                   httpVersion: "HTTP/1.1", headerFields: nil))
        var redirected = URLRequest(url: try XCTUnwrap(URL(string: "http://different.invalid/v1/state")))
        redirected.setValue("Bearer test-private-token", forHTTPHeaderField: "Authorization")
        var called = false
        SyncRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                                       newRequest: redirected) { next in
            called = true
            XCTAssertNil(next)
        }
        XCTAssertTrue(called)
    }

    func testSharedBackgroundEditedDuringApplyIsKeptAsAnUnpublishedDraft() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploading = expectation(description: "shared Apply waiting for response")
        var reply: CheckedContinuation<(Data, URLResponse), Error>?
        let board = BoardUpdate(revision: 1, baseRevision: nil, strokes: [], removed: [])
        var testToken = ""
        let sync = PairSync(transport: { request in
            if request.httpMethod == "POST" {
                return try await withCheckedThrowingContinuation { reply = $0; uploading.fulfill() }
            }
            return try self.stateReply(request, board: board)
        }, readToken: { testToken }, writeToken: { testToken = $0 })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://audit.invalid", token: "test-private-sync-token-A", store: store)
        sync.stop()
        let snapshot = store.displayedRecord(.together)
        let applying = Task { await sync.applyWhiteboard(store: store) }
        await fulfillment(of: [uploading], timeout: 5)
        store.updateBackground("#ABCDEF", on: .together)
        sync.markDirty(.together)
        let applied = SyncedRevision(source: "together", revision: 1, author: "A", backgroundHex: snapshot.backgroundHex,
                                     backgroundPhoto: nil, drawingData: snapshot.drawingData, drawingHeight: snapshot.drawingHeight)
        try XCTUnwrap(reply).resume(returning: (JSONEncoder().encode(applied),
            XCTUnwrap(HTTPURLResponse(url: URL(string: "https://audit.invalid/v1/apply")!, statusCode: 200,
                                     httpVersion: "HTTP/1.1", headerFields: nil))))
        let succeeded = await applying.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.record(.together).backgroundHex, "#ABCDEF")
        XCTAssertEqual(store.revisions.first?.document.backgroundHex, snapshot.backgroundHex)
        XCTAssertTrue(UserDefaults.standard.stringArray(forKey: "syncDirty")?.contains(CanvasSlot.together.rawValue) == true)
    }

    private func relayRevision(source: String = "b", revision: Int = 1, drawingData: Data = Data(),
                               color: UIColor = .red) throws -> SyncedRevision {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        return SyncedRevision(source: source, revision: revision, author: source == "b" ? "B" : "A",
                              backgroundHex: "#123456",
                              backgroundPhoto: BackgroundPhoto(data: try XCTUnwrap(image.jpegData(compressionQuality: 0.8)),
                                                               zoom: 0.6, offsetX: 0.1, rotation: 20),
                              drawingData: drawingData, drawingHeight: 844,
                              stickers: [CanvasSticker(data: try XCTUnwrap(image.pngData()), centerX: 0.3,
                                                       centerY: 0.7, width: 0.2, rotation: -30)])
    }

    private func relayReply(_ request: URLRequest, items: [SyncedRevision] = [], referenceOnly: Bool = false,
                            inventory: [MediaReceipt]? = nil, requests: [String] = [],
                            etag: String = "\"relay\"") throws -> (Data, URLResponse) {
        var documents = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(items)) as? [[String: Any]])
        for index in documents.indices {
            if var photo = documents[index]["backgroundPhoto"] as? [String: Any], let data = items[index].backgroundPhoto?.data {
                photo["mediaID"] = LocalMediaFiles.identifier(data)
                if referenceOnly { photo.removeValue(forKey: "data") }
                documents[index]["backgroundPhoto"] = photo
            }
            var stickers = documents[index]["stickers"] as? [[String: Any]] ?? []
            for stickerIndex in stickers.indices {
                stickers[stickerIndex]["mediaID"] = LocalMediaFiles.identifier(try XCTUnwrap(items[index].stickers)[stickerIndex].data)
                if referenceOnly { stickers[stickerIndex].removeValue(forKey: "data") }
            }
            documents[index]["stickers"] = stickers
        }
        let state: [String: Any] = ["role": "A", "items": documents, "pushConfigured": false,
                                   "hasPartnerArt": items.contains { $0.source == "b" }, "boardProtocol": 1,
                                   "mediaProtocol": 2, "drafts": [], "mediaRequests": requests,
                                   "mediaInventory": try JSONSerialization.jsonObject(with: JSONEncoder().encode(inventory ?? items.map { MediaReceipt($0) })),
                                   "board": ["revision": 1, "strokes": [], "removed": []]]
        return try pairingHTTPReply(request, state, headers: ["ETag": etag, "X-CoupleDraw-Long-Poll": "1"])
    }

    private func relayAckReply(_ request: URLRequest) throws -> (Data, URLResponse) {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        return try pairingHTTPReply(request, ["accepted": try XCTUnwrap(body["receipts"]), "removedBytes": 0])
    }

    func testRelayOriginalsSurviveCacheClearAndRestartWithoutAVisibleCanvasCopy() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try relayRevision()
        let receipt = MediaReceipt(item)
        try store.retainRelayMedia([item], inventory: [receipt], identity: "pair", complete: true)
        XCTAssertNil(store.record(.second).backgroundPhoto) // A dirty draft may have skipped incorporation.
        let orphan = try LocalMediaFiles.store(Data([7, 8, 9]), root: root)
        XCTAssertGreaterThan(try store.clearCache(), 0)
        XCTAssertThrowsError(try LocalMediaFiles.read(orphan, root: root))
        let restarted = CanvasStore(root: root)
        XCTAssertEqual(try restarted.pendingRelayReceipts(identity: "pair"), [receipt])
        let request = URLRequest(url: URL(string: "https://relay.invalid/v1/state")!)
        let (payload, _) = try relayReply(request, items: [item], referenceOnly: true)
        XCTAssertTrue(try restarted.missingRelayMedia(in: payload, inventory: [receipt], identity: "pair").isEmpty)
        struct State: Decodable { let items: [SyncedRevision] }
        let restored = try restarted.decodeSynced(State.self, from: payload).items[0]
        XCTAssertEqual(restored.backgroundPhoto, item.backgroundPhoto)
        XCTAssertEqual(restored.stickers, item.stickers)
        try restarted.acceptRemote(restored, on: .second, localRole: "A")
        XCTAssertNotNil(try WallpaperRenderer.render(restarted.record(.second)).pngData())
        try restarted.confirmRelayReceipts([receipt], identity: "pair")
        XCTAssertTrue(try CanvasStore(root: root).pendingRelayReceipts(identity: "pair").isEmpty)
        _ = try restarted.clearCache()
        XCTAssertEqual(try restarted.relayImage(receipt.mediaIDs[0]), try store.relayImage(receipt.mediaIDs[0]))
    }

    func testReplacingRelayRevisionReleasesOnlyUnusedOldOriginalsAndIgnoresLateConfirmation() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try relayRevision()
        let next = try relayRevision(revision: 2, color: .blue)
        let own = try relayRevision(source: "a", color: .green)
        try store.retainRelayMedia([old, own], inventory: [MediaReceipt(old), MediaReceipt(own)], identity: "pair", complete: true)
        try store.retainRelayMedia([next], inventory: [MediaReceipt(next)], identity: "pair", complete: false)
        try store.confirmRelayReceipts([MediaReceipt(old)], identity: "pair")
        XCTAssertEqual(Set(try store.pendingRelayReceipts(identity: "pair").map(\.revision)), [1, 2])
        XCTAssertGreaterThan(try store.clearCache(), 0)
        for ident in MediaReceipt(old).mediaIDs { XCTAssertThrowsError(try store.relayImage(ident)) }
        for ident in MediaReceipt(next).mediaIDs + MediaReceipt(own).mediaIDs { XCTAssertNotNil(try store.relayImage(ident)) }
        try store.retainRelayMedia([old], inventory: [MediaReceipt(old)], identity: "pair", complete: false)
        XCTAssertEqual(try store.pendingRelayReceipts(identity: "pair").first { $0.source == "b" }?.revision, 2)
    }

    func testRelayHashMismatchAndMissingOriginalCannotBeAcknowledged() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try relayRevision()
        let receipt = MediaReceipt(item)
        let request = URLRequest(url: URL(string: "https://relay.invalid/v1/state")!)
        let (payload, _) = try relayReply(request, items: [item])
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        var documents = try XCTUnwrap(state["items"] as? [[String: Any]])
        var photo = try XCTUnwrap(documents[0]["backgroundPhoto"] as? [String: Any])
        photo["data"] = Data([1, 2, 3]).base64EncodedString()
        documents[0]["backgroundPhoto"] = photo
        state["items"] = documents
        struct State: Decodable { let items: [SyncedRevision] }
        XCTAssertThrowsError(try store.decodeSynced(State.self, from: JSONSerialization.data(withJSONObject: state)))
        try store.retainRelayMedia([item], inventory: [receipt], identity: "pair", complete: true)
        try FileManager.default.removeItem(at: LocalMediaFiles.path(receipt.mediaIDs[0], root: root))
        XCTAssertThrowsError(try store.pendingRelayReceipts(identity: "pair"))
        let (references, _) = try relayReply(request, items: [item], referenceOnly: true)
        XCTAssertEqual(try store.missingRelayMedia(in: references, inventory: [receipt], identity: "pair"), [receipt.mediaIDs[0]])
    }

    func testReceivedMediaIsAcknowledgedAfterPersistenceAndShortcutWorksAfterDeletion() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try relayRevision()
        var phase = 0
        var token = ""
        var acknowledgements = 0
        let transport: (URLRequest) async throws -> (Data, URLResponse) = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CoupleDraw-Media"), "2")
            if request.url?.path == "/v1/media/ack" {
                acknowledgements += 1
                XCTAssertEqual(CanvasStore(root: root).record(.second).backgroundPhoto, item.backgroundPhoto)
                XCTAssertEqual(store.revisions.first?.document.stickers, item.stickers)
                _ = try store.clearCache()
                for ident in MediaReceipt(item).mediaIDs { XCTAssertNotNil(try store.relayImage(ident)) }
                return try self.relayAckReply(request)
            }
            return try self.relayReply(request, items: phase == 0 ? [] : [item], referenceOnly: phase == 2)
        }
        let sync = PairSync(transport: transport, readToken: { token }, writeToken: { token = $0 })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://relay.invalid", token: "private-phone-A", store: store)
        sync.stop()
        phase = 1
        await sync.refresh(store: store)
        XCTAssertEqual(acknowledgements, 1)
        phase = 2
        sync.suspend()
        let restarted = PairSync(transport: transport, readToken: { token }, writeToken: { token = $0 })
        defer { restarted.suspend() }
        let reloaded = CanvasStore(root: root)
        try await restarted.refreshForShortcut(store: reloaded)
        XCTAssertEqual(reloaded.record(.second).backgroundPhoto, item.backgroundPhoto)
        XCTAssertEqual(acknowledgements, 1) // Confirmation survives process restart.
        XCTAssertNotNil(try Data(contentsOf: reloaded.cachedWallpaperURL(for: XCTUnwrap(reloaded.revisions.first))))
    }

    func testFailedRenderingAndManifestWritesNeverSendMediaReceipts() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date()
        var phase = 0
        var token = ""
        var acknowledgements = 0
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/media/ack" {
                acknowledgements += 1
                return try self.relayAckReply(request)
            }
            let item = try self.relayRevision(drawingData: phase == 1 ? Data([1, 2, 3]) : Data())
            return try self.relayReply(request, items: phase == 0 ? [] : [item])
        }, readToken: { token }, writeToken: { token = $0 }, clock: { now })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://relay.invalid", token: "private-phone-A", store: store)
        sync.stop()
        phase = 1
        await sync.refresh(store: store)
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertTrue(store.revisions.isEmpty)
        now = now.addingTimeInterval(120)
        phase = 2
        let manifest = root.appendingPathComponent("relay-media.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        await sync.refresh(store: store)
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertTrue(sync.status.hasPrefix("Sync paused:"))
        try FileManager.default.removeItem(at: manifest)
        now = now.addingTimeInterval(120)
        await sync.refresh(store: store)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertEqual(store.record(.second).backgroundHex, "#123456")
    }

    func testFailedReceiptRetriesOnUnchangedStateAndKeepsPendingConfirmationOnDisk() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try relayRevision()
        var now = Date()
        var phase = 0
        var token = ""
        var acknowledgements = 0
        let identity = LocalMediaFiles.identifier(Data("https://relay.invalid|private-phone-A".utf8))
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/media/ack" {
                acknowledgements += 1
                if phase == 1 { throw URLError(.networkConnectionLost) }
                return try self.relayAckReply(request)
            }
            if phase == 2 {
                return (Data(), try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 304,
                                                            httpVersion: "HTTP/1.1", headerFields: nil)))
            }
            return try self.relayReply(request, items: phase == 0 ? [] : [item])
        }, readToken: { token }, writeToken: { token = $0 }, clock: { now })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://relay.invalid", token: "private-phone-A", store: store)
        sync.stop()
        phase = 1
        await sync.refresh(store: store)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertEqual(try CanvasStore(root: root).pendingRelayReceipts(identity: identity), [MediaReceipt(item)])
        now = now.addingTimeInterval(120)
        phase = 2
        await sync.refresh(store: store)
        XCTAssertEqual(acknowledgements, 2)
        XCTAssertTrue(try CanvasStore(root: root).pendingRelayReceipts(identity: identity).isEmpty)
    }

    func testMissingOriginalRequestsResendWithoutReturningAPartialShortcutWallpaper() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try relayRevision()
        var phase = 0
        var token = ""
        var requests = 0
        var acknowledgements = 0
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/media/request" {
                requests += 1
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: [String]])
                XCTAssertEqual(body["mediaIDs"], MediaReceipt(item).mediaIDs)
                return try self.pairingHTTPReply(request, ["queued": true])
            }
            if request.url?.path == "/v1/media/ack" {
                acknowledgements += 1
                return try self.relayAckReply(request)
            }
            return try self.relayReply(request, items: phase == 0 ? [] : [item], referenceOnly: phase == 1)
        }, readToken: { token }, writeToken: { token = $0 })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://relay.invalid", token: "private-phone-A", store: store)
        sync.stop()
        phase = 1
        do { try await sync.refreshForShortcut(store: store); XCTFail("Missing media must stop the wallpaper action") }
        catch { XCTAssertTrue(error.localizedDescription.contains("resend")) }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertTrue(store.revisions.isEmpty)
        phase = 2
        try await sync.refreshForShortcut(store: store)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertEqual(store.record(.second).backgroundPhoto, item.backgroundPhoto)
    }

    func testResendUsesOnlyCurrentPairInventoryAndShortcutSkipsDonorUploads() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try relayRevision(source: "a")
        let ident = try XCTUnwrap(item.backgroundPhoto).data
        var phase = 0
        var token = ""
        var resends = 0
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/media/ack" { return try self.relayAckReply(request) }
            if request.url?.path == "/v1/media/restore" {
                resends += 1
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
                XCTAssertEqual(body["mediaID"], LocalMediaFiles.identifier(ident))
                XCTAssertEqual(body["data"], ident.base64EncodedString())
                return try self.pairingHTTPReply(request, ["restored": true])
            }
            let requested = phase == 3 ? [String(repeating: "f", count: 64)] :
                phase == 2 ? [LocalMediaFiles.identifier(ident)] : []
            return try self.relayReply(request, items: phase == 0 ? [] : [item], referenceOnly: phase > 1,
                                       requests: requested)
        }, readToken: { token }, writeToken: { token = $0 })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://relay.invalid", token: "private-phone-A", store: store)
        sync.stop()
        phase = 1
        await sync.refresh(store: store)
        phase = 2
        try await sync.refreshForShortcut(store: store)
        XCTAssertEqual(resends, 0)
        await sync.refresh(store: store)
        XCTAssertEqual(resends, 1)
        phase = 3
        await sync.refresh(store: store)
        XCTAssertEqual(resends, 1)
        XCTAssertTrue(sync.status.hasPrefix("Sync paused:"))
    }

    func testPublishedOwnAndSharedPhotosAreRetainedBeforeSenderReceipts() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var token = ""
        var receipts = Set<String>()
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/apply" {
                var body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                body["revision"] = 1
                body["author"] = "A"
                return try self.pairingHTTPReply(request, body, headers: ["X-CoupleDraw-Media": "2"])
            }
            if request.url?.path == "/v1/media/ack" {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                let incoming = try XCTUnwrap(body["receipts"] as? [[String: Any]])
                for receipt in incoming {
                    receipts.insert(try XCTUnwrap(receipt["source"] as? String))
                    for ident in try XCTUnwrap(receipt["mediaIDs"] as? [String]) { XCTAssertNotNil(try store.relayImage(ident)) }
                }
                return try self.relayAckReply(request)
            }
            return try self.relayReply(request)
        }, readToken: { token }, writeToken: { token = $0 })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://relay.invalid", token: "private-phone-A", store: store)
        sync.stop()
        let own = try relayRevision(source: "a")
        store.updateBackgroundPhoto(own.backgroundPhoto, on: .first)
        store.updateStickers(own.stickers ?? [], on: .first)
        XCTAssertNotNil(store.apply(.first))
        await sync.publish(store.record(.first), slot: .first, store: store)
        let shared = try relayRevision(source: "together", color: .blue)
        store.updateBackgroundPhoto(shared.backgroundPhoto, on: .together)
        store.updateStickers(shared.stickers ?? [], on: .together)
        sync.markDirty(.together)
        let applied = await sync.applyWhiteboard(store: store)
        XCTAssertTrue(applied)
        XCTAssertEqual(receipts, ["a", "together"])
        XCTAssertEqual(store.revisions.first?.document.backgroundPhoto, shared.backgroundPhoto)
    }

    func testDelayedReceiptCannotConfirmMediaForANewPairingSession() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try relayRevision()
        var phase = 0
        var token = ""
        var reply: CheckedContinuation<(Data, URLResponse), Error>?
        var acknowledgement: URLRequest?
        let requested = expectation(description: "Old pair receipt sent")
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/media/ack" {
                acknowledgement = request
                return try await withCheckedThrowingContinuation { reply = $0; requested.fulfill() }
            }
            return try self.relayReply(request, items: phase == 1 && request.url?.host == "relay.invalid" ? [item] : [])
        }, readToken: { token }, writeToken: { token = $0 })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://relay.invalid", token: "private-phone-A", store: store)
        sync.stop()
        phase = 1
        let receiving = Task { await sync.refresh(store: store) }
        await fulfillment(of: [requested], timeout: 5)
        try await sync.configure(endpoint: "https://new-pair.invalid", token: "new-private-phone", store: store)
        sync.stop()
        let newStatus = sync.status
        try XCTUnwrap(reply).resume(returning: relayAckReply(XCTUnwrap(acknowledgement)))
        await receiving.value
        XCTAssertEqual(sync.status, newStatus)
        let identity = LocalMediaFiles.identifier(Data("https://new-pair.invalid|new-private-phone".utf8))
        XCTAssertTrue(try store.pendingRelayReceipts(identity: identity).isEmpty)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("relay-media.json"))) as? [String: Any])
        XCTAssertEqual(manifest["identity"] as? String, identity)
    }

    private func pairingHTTPReply(_ request: URLRequest, _ body: [String: Any], status: Int = 200,
                                  headers: [String: String]? = nil) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: body),
         try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status,
                                     httpVersion: "HTTP/1.1", headerFields: headers)))
    }

    func testDefaultPairingServerAndInviteValidation() throws {
        XCTAssertEqual(PairSync.defaultEndpoint, "https://draw.huythedev.com")
        XCTAssertEqual(try PairSync.normalizedEndpoint(" draw.huythedev.com/ "), PairSync.defaultEndpoint)
        XCTAssertEqual(try PairSync.normalizedEndpoint("http://192.168.1.20:8787/"), "http://192.168.1.20:8787")
        let invite = PairingInvite(endpoint: "https://my-server.invalid:8443", code: "048273")
        XCTAssertEqual(PairingInvite(url: invite.url), invite)
        XCTAssertEqual(invite.formattedCode, "048 273")
        XCTAssertEqual(PairSync.normalizedPairingCode("048 273"), "048273")
        XCTAssertNil(PairSync.normalizedPairingCode("１２３４５６"))
        XCTAssertNil(PairSync.normalizedPairingCode("abc048273"))
        for raw in ["http://public.invalid", "https://a:b@server.invalid", "https://server.invalid/v1/state", "https://server.invalid?token=secret"] {
            XCTAssertThrowsError(try PairSync.normalizedEndpoint(raw))
        }
        for raw in ["coupledraw://pair?server=https://server.invalid&code=048273&code=111111",
                    "coupledraw://pair?server=http://public.invalid&code=048273",
                    "coupledraw://pair?server=https://server.invalid&code=048273#extra",
                    "coupledraw://open?server=https://server.invalid&code=048273"] {
            XCTAssertNil(PairingInvite(url: try XCTUnwrap(URL(string: raw))))
        }
    }

    func testCreatePairWaitsWithoutSendingExistingCredentialsOrChangingCurrentPair() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        UserDefaults.standard.set("https://existing.invalid", forKey: "syncEndpoint")
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var savedPairing: String?
        var testToken = "existing-private-token"
        var actions: [String] = []
        var partnerJoined = false
        let credential = String(repeating: "a", count: 64)
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/state" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + credential)
                return try self.stateReply(request)
            }
            XCTAssertNotNil(savedPairing)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.host, "draw.huythedev.com")
            actions.append(request.url!.lastPathComponent)
            if request.url?.lastPathComponent == "status" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "wait=20")
                XCTAssertEqual(request.timeoutInterval, 35)
            }
            if partnerJoined {
                return try self.pairingHTTPReply(request, ["state": "paired", "role": "A", "credential": credential])
            }
            return try self.pairingHTTPReply(request, ["state": "waiting", "code": "048273",
                                                      "expiresAt": Date().timeIntervalSince1970 + 300])
        }, readToken: { testToken }, writeToken: { testToken = $0 },
           readPairing: { savedPairing }, writePairing: { savedPairing = $0 })
        defer { sync.suspend() }
        try sync.beginPairing(.create, endpoint: PairSync.defaultEndpoint)
        let saved = try JSONDecoder().decode(PairingAttempt.self, from: Data(XCTUnwrap(savedPairing).utf8))
        XCTAssertEqual(saved.secret.count, 64)
        let firstCompleted = try await sync.resumePairing(store: store)
        let secondCompleted = try await sync.resumePairing(store: store)
        XCTAssertFalse(firstCompleted); XCTAssertFalse(secondCompleted)
        XCTAssertEqual(actions, ["create", "status"])
        XCTAssertEqual(sync.pairingAttempt?.invite?.formattedCode, "048 273")
        XCTAssertEqual(sync.endpoint, "https://existing.invalid")
        XCTAssertEqual(testToken, "existing-private-token")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "syncEndpoint"), "https://existing.invalid")
        partnerJoined = true
        let joined = try await sync.resumePairing(store: store)
        sync.stop()
        XCTAssertTrue(joined)
        XCTAssertEqual(sync.endpoint, PairSync.defaultEndpoint)
        XCTAssertEqual(sync.role, "A")
        XCTAssertEqual(testToken, credential)
        XCTAssertNil(savedPairing)
    }

    func testJoinPairRecoversAfterLostResponseAndAppRestart() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var savedPairing: String?
        var testToken = ""
        var originalSecret: String?
        let first = PairSync(transport: { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
            originalSecret = body["secret"]
            XCTAssertEqual(body["code"], "048273")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            throw URLError(.networkConnectionLost)
        }, readToken: { testToken }, writeToken: { testToken = $0 },
           readPairing: { savedPairing }, writePairing: { savedPairing = $0 })
        defer { first.suspend() }
        try first.beginPairing(.join, endpoint: PairSync.defaultEndpoint, code: "048 273")
        do { _ = try await first.resumePairing(store: store); XCTFail("Expected lost response") }
        catch { XCTAssertTrue(error is URLError) }
        XCTAssertNotNil(savedPairing)
        XCTAssertTrue(testToken.isEmpty)
        let credential = String(repeating: "b", count: 64)
        let restarted = PairSync(transport: { request in
            if request.url?.path == "/v1/pairing/join" {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
                XCTAssertEqual(body["secret"], originalSecret)
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return try self.pairingHTTPReply(request, ["state": "paired", "role": "B", "credential": credential])
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + credential)
            return try self.stateReply(request, role: "B")
        }, readToken: { testToken }, writeToken: { testToken = $0 },
           readPairing: { savedPairing }, writePairing: { savedPairing = $0 })
        defer { restarted.suspend() }
        let completed = try await restarted.resumePairing(store: store)
        restarted.stop()
        XCTAssertTrue(completed)
        XCTAssertNil(savedPairing)
        XCTAssertNil(restarted.pairingAttempt)
        XCTAssertEqual(restarted.endpoint, PairSync.defaultEndpoint)
        XCTAssertEqual(restarted.role, "B")
        XCTAssertEqual(testToken, credential)
    }

    func testFailedNewPairConnectionRetainsCurrentPairAndRecoverySecret() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var savedPairing: String?
        var testToken = ""
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/pairing/join" {
                return try self.pairingHTTPReply(request, ["state": "paired", "role": "B", "credential": String(repeating: "c", count: 64)])
            }
            if request.url?.host == "new-pair.invalid" {
                return try self.pairingHTTPReply(request, ["error": "Temporarily unavailable"], status: 503)
            }
            return try self.stateReply(request)
        }, readToken: { testToken }, writeToken: { testToken = $0 },
           readPairing: { savedPairing }, writePairing: { savedPairing = $0 })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://old-pair.invalid", token: "previous-private-token", store: store)
        sync.stop()
        try sync.beginPairing(.join, endpoint: "https://new-pair.invalid", code: "048273")
        let pending = savedPairing
        do { _ = try await sync.resumePairing(store: store); XCTFail("Expected failed state request") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Temporarily unavailable")) }
        sync.stop()
        XCTAssertEqual(sync.endpoint, "https://old-pair.invalid")
        XCTAssertEqual(sync.role, "A")
        XCTAssertEqual(testToken, "previous-private-token")
        XCTAssertEqual(savedPairing, pending)
        XCTAssertNotNil(sync.pairingAttempt)
    }

    func testPairingRejectsRedirectsAndIncorrectCredentialRoles() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var savedPairing: String?
        var testToken = "previous-private-token"
        var redirect = true
        let sync = PairSync(transport: { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return try self.pairingHTTPReply(request, ["state": "paired", "role": "A", "credential": String(repeating: "a", count: 64)],
                                             status: redirect ? 302 : 200, headers: redirect ? ["Location": "https://other.invalid"] : nil)
        }, readToken: { testToken }, writeToken: { testToken = $0 },
           readPairing: { savedPairing }, writePairing: { savedPairing = $0 })
        defer { sync.suspend() }
        try sync.beginPairing(.join, endpoint: PairSync.defaultEndpoint, code: "048273")
        do { _ = try await sync.resumePairing(store: store); XCTFail("Expected redirect rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("redirected")) }
        redirect = false
        do { _ = try await sync.resumePairing(store: store); XCTFail("Expected incorrect role rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Invalid sync")) }
        XCTAssertEqual(testToken, "previous-private-token")
        XCTAssertNotNil(savedPairing)
        XCTAssertTrue(sync.endpoint.isEmpty)
    }

    func testCancellingAnInviteDiscardsItsLateCreateResponse() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let requested = expectation(description: "Create sent")
        var reply: CheckedContinuation<(Data, URLResponse), Error>?
        var savedPairing: String?
        let sync = PairSync(transport: { request in
            if request.url?.lastPathComponent == "create" {
                return try await withCheckedThrowingContinuation { reply = $0; requested.fulfill() }
            }
            throw URLError(.cannotConnectToHost)
        }, readToken: { "" }, writeToken: { _ in },
           readPairing: { savedPairing }, writePairing: { savedPairing = $0 })
        defer { sync.suspend() }
        try sync.beginPairing(.create, endpoint: PairSync.defaultEndpoint)
        let creating = Task { try await sync.resumePairing(store: store) }
        await fulfillment(of: [requested], timeout: 5)
        try await sync.cancelPairing()
        let request = URLRequest(url: URL(string: PairSync.defaultEndpoint + "/v1/pairing/create")!)
        try XCTUnwrap(reply).resume(returning: pairingHTTPReply(request, ["state": "waiting", "code": "048273",
                                                                          "expiresAt": Date().timeIntervalSince1970 + 300]))
        do { _ = try await creating.value; XCTFail("Expected cancelled attempt") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(savedPairing)
        XCTAssertNil(sync.pairingAttempt)
        XCTAssertFalse(sync.configured)
    }

    func testPairingCannotStartUntilItsRecoverySecretIsStored() throws {
        var requests = 0
        let sync = PairSync(transport: { _ in requests += 1; throw URLError(.badURL) },
                            readToken: { "" }, writeToken: { _ in }, readPairing: { nil },
                            writePairing: { _ in throw PairSync.SyncError.configuration })
        defer { sync.suspend() }
        XCTAssertThrowsError(try sync.beginPairing(.create, endpoint: PairSync.defaultEndpoint))
        XCTAssertNil(sync.pairingAttempt)
        XCTAssertEqual(requests, 0)
    }

    func testLightweightShortcutKeepsAllOriginalsAndAcknowledgesOnlyAfterExport() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (main, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        main.updateBackground("#654321", on: .first)
        UserDefaults.standard.set("https://shortcut.invalid", forKey: "syncEndpoint")
        let chosen = try relayRevision()
        let other = try relayRevision(source: "a", drawingData: Data([1, 2, 3]), color: .blue)
        let shortcut = CanvasStore(root: root, shortcutChoice: .partner)
        var acknowledgements = 0
        var export: URL?
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/media/ack" {
                acknowledgements += 1
                XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(export).path))
                return try self.relayAckReply(request)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CoupleDraw-Wallpaper"), "partner")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CoupleDraw-Board-History"), "1")
            let (body, response) = try self.relayReply(request, items: [chosen, other])
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let items = try XCTUnwrap(json["items"] as? [[String: Any]])
            json["items"] = [items[0]]
            var mediaOnly = items[1]; mediaOnly["drawingData"] = ""
            json["mediaOnlyItems"] = [mediaOnly]
            json.removeValue(forKey: "board")
            return (try JSONSerialization.data(withJSONObject: json), response)
        }, readToken: { "private-phone-A" })
        defer { sync.suspend() }
        try await sync.refreshForShortcut(store: shortcut, choice: .partner)
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertTrue(shortcut.revisions.isEmpty)
        XCTAssertNil(shortcut.whiteboard)
        let identity = LocalMediaFiles.identifier(Data("https://shortcut.invalid|private-phone-A".utf8))
        XCTAssertEqual(try shortcut.pendingRelayReceipts(identity: identity).count, 2)
        export = try shortcut.wallpaperFileForShortcut(on: .second)
        _ = try main.clearCache()
        for item in [chosen, other] {
            for ident in MediaReceipt(item).mediaIDs { XCTAssertNotNil(try shortcut.relayImage(ident)) }
        }
        try await sync.acknowledgeShortcutMedia(store: shortcut)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertTrue(try shortcut.pendingRelayReceipts(identity: identity).isEmpty)
        let reopened = CanvasStore(root: root)
        XCTAssertEqual(reopened.revisions.count, 1)
        XCTAssertEqual(reopened.record(.first).backgroundHex, "#654321")
        XCTAssertEqual(reopened.record(.second).backgroundPhoto, chosen.backgroundPhoto)
    }

    func testRetryAfterPreventsRequestsAcrossFreshShortcutInstances() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        UserDefaults.standard.set("https://retry.invalid", forKey: "syncEndpoint")
        var now = Date(), requests = 0
        let transport: (URLRequest) async throws -> (Data, URLResponse) = { request in
            requests += 1
            if requests == 1 {
                return try self.pairingHTTPReply(request, ["error": "Busy"], status: 429,
                                                headers: ["Retry-After": "120"])
            }
            return try self.stateReply(request)
        }
        let first = PairSync(transport: transport, readToken: { "private-A" }, clock: { now })
        do { try await first.refreshForShortcut(store: store); XCTFail("429 must stop this invocation") }
        catch { XCTAssertTrue(error is SyncHTTPError) }
        let restarted = PairSync(transport: transport, readToken: { "private-A" }, clock: { now })
        do { try await restarted.refreshForShortcut(store: store); XCTFail("Retry-After must survive reinitialization") }
        catch { XCTAssertTrue(error is SyncHTTPError) }
        XCTAssertEqual(requests, 1)
        now = now.addingTimeInterval(122)
        try await restarted.refreshForShortcut(store: store)
        XCTAssertEqual(requests, 2)
    }

    func testSharedShortcutUsesLatestAppliedArtWhilePreservingDirtyBackgroundAndLegacyQueue() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (main, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        main.updateBackground("#0000FF", on: .together)
        UserDefaults.standard.set("https://shared-shortcut.invalid", forKey: "syncEndpoint")
        UserDefaults.standard.set([CanvasSlot.together.rawValue], forKey: "syncDirty")
        let shortcut = CanvasStore(root: root, shortcutChoice: .together)
        let applied = SyncedRevision(source: "together", revision: 1, author: "B", backgroundHex: "#00FF00",
                                     backgroundPhoto: nil, drawingData: Data(), drawingHeight: 844)
        let unselected = SyncedRevision(source: "b", revision: 1, author: "B", backgroundHex: "#123456",
                                        backgroundPhoto: nil, drawingData: Data([1, 2, 3]), drawingHeight: 844)
        let sync = PairSync(transport: { request in
            // Older servers ignore the wallpaper header and return all canvases.
            try self.stateReply(request, items: [applied, unselected])
        }, readToken: { "private-A" })
        defer { sync.suspend() }
        try await sync.refreshForShortcut(store: shortcut, choice: .together)
        XCTAssertNil(shortcut.whiteboard)
        XCTAssertEqual(shortcut.record(.together).backgroundHex, "#0000FF")
        let history = CanvasStore(root: root).revisions
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.document.backgroundHex, "#00FF00")
        XCTAssertEqual(shortcut.record(.second).backgroundHex, "#000000")
        XCTAssertTrue(UserDefaults.standard.stringArray(forKey: "syncDirty")?.contains(CanvasSlot.together.rawValue) == true)
    }

    func testStateFailuresBackOffWithoutRetryAfterAndResetOnSuccess() async throws {
        let restorePreferences = isolatedSyncPreferences()
        defer { restorePreferences() }
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        UserDefaults.standard.set("https://backoff.invalid", forKey: "syncEndpoint")
        var now = Date(), requests = 0, failing = true
        let sync = PairSync(transport: { request in
            requests += 1
            if failing { return try self.pairingHTTPReply(request, ["error": "Busy"], status: 503) }
            return try self.stateReply(request)
        }, readToken: { "private-A" }, clock: { now })
        defer { sync.suspend() }
        await sync.refresh(store: store)
        await sync.refresh(store: store)
        XCTAssertEqual(requests, 1)
        now = now.addingTimeInterval(2)
        await sync.refresh(store: store)
        XCTAssertEqual(requests, 2)
        failing = false
        now = now.addingTimeInterval(3)
        await sync.refresh(store: store)
        await sync.refresh(store: store)
        XCTAssertEqual(requests, 4)
    }
}
