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
                XCTAssertEqual(loaded.size, image.size)
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

    func testPasteControlAndDrawingCanvasAcceptImageProvidersAndNativePaste() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 5, height: 5)).image { _ in }
        let provider = NSItemProvider(object: image)
        let text = NSItemProvider(object: "caption" as NSString)
        var received = 0
        let receiver = StickerPasteReceiver { providers in received += providers.count }
        XCTAssertFalse(receiver.canPaste([text]))
        XCTAssertTrue(receiver.canPaste([text, provider]))
        receiver.paste(itemProviders: [text, provider])
        XCTAssertEqual(received, 2)

        let canvas = FittedCanvasView()
        canvas.onPasteImages = { _ in received += 1 }
        XCTAssertTrue(canvas.canPaste([provider]))
        canvas.paste(itemProviders: [provider])
        XCTAssertEqual(received, 3)

        let clipboard = UIPasteboard.general
        let previous = clipboard.items
        defer { clipboard.items = previous }
        clipboard.image = image
        XCTAssertTrue(canvas.canPerformAction(#selector(canvas.paste(_:)), withSender: nil))
        canvas.paste(nil)
        XCTAssertEqual(received, 4)
        XCTAssertNotNil(canvas.inputView) // image paste keeps the lasso keyboard suppressed
    }
}
