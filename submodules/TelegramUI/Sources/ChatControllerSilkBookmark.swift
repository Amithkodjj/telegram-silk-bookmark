import Foundation
import UIKit
import Display
import TelegramCore
import ChatMessageItemView
import ChatControllerInteraction
import SilkBookmark

extension ChatControllerImpl {
    private func silkBookmarkDefaultsKey(_ peerId: EnginePeer.Id) -> String {
        return "silkBookmark.\(self.context.account.peerId.toInt64()).\(peerId.toInt64())"
    }

    private func silkBookmarkKey(_ id: EngineMessage.Id) -> Int64 {
        return (Int64(id.namespace) << 32) | Int64(UInt32(bitPattern: id.id))
    }

    func installSilkBookmarkIfNeeded() {
        guard self.silkBookmarkView == nil, case let .peer(peerId) = self.chatLocation, self.subject == nil, case .standard(.default) = self.mode else {
            return
        }
        let historyContainer = self.chatDisplayNode.historyNodeContainer.view
        guard let superview = historyContainer.superview else {
            return
        }

        let view = SilkBookmarkView()
        self.silkBookmarkView = view
        superview.insertSubview(view, aboveSubview: historyContainer)

        view.messageAt = { [weak self] point in
            guard let self, let view = self.silkBookmarkView else {
                return nil
            }
            var result: SilkBookmarkMessage?
            self.chatDisplayNode.historyNode.forEachVisibleItemNode { node in
                guard result == nil, let itemNode = node as? ChatMessageItemView, let item = itemNode.item, item.message.id.namespace == Namespaces.Message.Cloud else {
                    return
                }
                let frame = itemNode.view.convert(itemNode.contentFrame(), to: view)
                if frame.insetBy(dx: -10.0, dy: -6.0).contains(point) {
                    result = SilkBookmarkMessage(key: self.silkBookmarkKey(item.message.id), frame: frame)
                }
            }
            return result
        }

        view.messageWithKey = { [weak self] key, usingPresentation in
            guard let self, let view = self.silkBookmarkView else {
                return nil
            }
            var result: SilkBookmarkMessage?
            self.chatDisplayNode.historyNode.forEachVisibleItemNode { node in
                guard result == nil, let itemNode = node as? ChatMessageItemView, let item = itemNode.item else {
                    return
                }
                guard item.content.contains(where: { self.silkBookmarkKey($0.0.id) == key }) else {
                    return
                }
                let frame: CGRect
                if usingPresentation, let source = itemNode.layer.presentation(), let target = view.layer.presentation() {
                    frame = source.convert(itemNode.contentFrame(), to: target)
                } else {
                    frame = itemNode.view.convert(itemNode.contentFrame(), to: view)
                }
                result = SilkBookmarkMessage(key: key, frame: frame)
            }
            return result
        }

        view.visibleMessageFrames = { [weak self] usingPresentation in
            guard let self, let view = self.silkBookmarkView else {
                return []
            }
            var result: [CGRect] = []
            self.chatDisplayNode.historyNode.forEachVisibleItemNode { node in
                guard let itemNode = node as? ChatMessageItemView else {
                    return
                }
                if usingPresentation, let source = itemNode.layer.presentation(), let target = view.layer.presentation() {
                    result.append(source.convert(itemNode.contentFrame(), to: target))
                } else {
                    result.append(itemNode.view.convert(itemNode.contentFrame(), to: view))
                }
            }
            return result
        }

        view.listProbe = { [weak self] in
            guard let self, let view = self.silkBookmarkView else {
                return nil
            }
            var result: (AnyHashable, CGFloat)?
            self.chatDisplayNode.historyNode.forEachVisibleItemNode { node in
                if result == nil, let itemNode = node as? ChatMessageItemView {
                    result = (AnyHashable(ObjectIdentifier(itemNode)), itemNode.view.convert(CGPoint.zero, to: view).y)
                }
            }
            return result
        }

        view.bookmarkChanged = { [weak self] key in
            guard let self else {
                return
            }
            if let key {
                UserDefaults.standard.set(key, forKey: self.silkBookmarkDefaultsKey(peerId))
            } else {
                UserDefaults.standard.removeObject(forKey: self.silkBookmarkDefaultsKey(peerId))
            }
        }

        view.goToBookmark = { [weak self] key in
            guard let self else {
                return
            }
            let id = EngineMessage.Id(peerId: peerId, namespace: Int32(truncatingIfNeeded: key >> 32), id: Int32(truncatingIfNeeded: key))
            self.navigateToMessage(messageLocation: .id(id, NavigateToMessageParams(timestamp: nil, quote: nil)), animated: true)
        }

        if let saved = UserDefaults.standard.object(forKey: self.silkBookmarkDefaultsKey(peerId)) as? Int64 {
            view.setBookmark(saved)
        }
        self.updateSilkBookmarkVisibility()
        if let layout = self.validLayout {
            self.updateSilkBookmarkLayout(layout)
        }
    }

    func updateSilkBookmarkLayout(_ layout: ContainerViewLayout) {
        guard let view = self.silkBookmarkView else {
            return
        }
        var navigationBottom = self.navigationLayout(layout: layout).navigationFrame.maxY
        if let panelsBottom = self.chatDisplayNode.headerPanelsBottomEdge {
            navigationBottom = max(navigationBottom, panelsBottom)
        }
        let area = self.chatDisplayNode.frameForVisibleArea()
        view.update(
            size: layout.size,
            dock: CGPoint(x: layout.size.width - layout.safeInsets.right - 40.0, y: navigationBottom - 30.0),
            visibleTop: navigationBottom,
            visibleBottom: area.maxY
        )
    }

    func updateSilkBookmarkVisibility() {
        guard let view = self.silkBookmarkView else {
            return
        }
        let interfaceState = self.presentationInterfaceState
        view.setContentHidden(interfaceState.interfaceState.selectionState != nil || interfaceState.search != nil)
    }
}
