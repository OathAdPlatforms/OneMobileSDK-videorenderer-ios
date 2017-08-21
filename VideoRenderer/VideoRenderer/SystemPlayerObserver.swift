//  Copyright © 2017 One by Aol : Publishers. All rights reserved.

import Foundation
import AVFoundation

public final class SystemPlayerObserver: NSObject {
    public enum Event {
        case didChangeRate(to: Float)
        case didChangeUrl(from: URL?, to: URL?)
        case didChangeItemStatus(from: AVPlayerItemStatus?, to: AVPlayerItemStatus)
        case didChangeItemDuration(from: CMTime?, to: CMTime?)
        case didFinishPlayback(withUrl: URL)
        case didChangeLoadedTimeRanges(to: [CMTimeRange])
        case didChangeAverageVideoBitrate(to: Double)
    }
    
    private var emit: Action<Event>
    private var player: AVPlayer
    private let center = NotificationCenter.default
    
    private var accessLogToken = nil as Any?
    private var timebaseRangeToken = nil as Any?
    public init(player: AVPlayer, emit: @escaping Action<Event>) {
        self.emit = emit
        self.player = player
        super.init()
        
        player.addObserver(self,
                           forKeyPath: #keyPath(AVPlayer.currentItem),
                           options: [.initial, .new, .old],
                           context: nil)
    }
    
    func didPlayToEnd(notification: NSNotification) {
        guard let item = notification.object as? AVPlayerItem else {
            return
        }
        guard let urlAsset = item.asset as? AVURLAsset else {
            fatalError("Asset is not AVURLAsset!")
        }
        
        emit(.didFinishPlayback(withUrl: urlAsset.url))
    }
    
    override public func observeValue(forKeyPath keyPath: String?,
                                      of object: Any?,
                                      change: [NSKeyValueChangeKey : Any]?,
                                      context: UnsafeMutableRawPointer?) {
        guard let keyPath = keyPath else { fatalError("Unexpected nil keypath!") }
        guard let change = change else { fatalError("Change should not be nil!") }
        
        func newValue<T>() -> T? {
            let change = change[NSKeyValueChangeKey.newKey]
            guard (change as? NSNull) == nil else { return nil }
            return change as? T
        }
        
        func newValueUnwrapped<T>() -> T {
            guard let newValue: T = newValue() else {
                fatalError("Unexpected nil in \(keyPath)! value!")
            }
            return newValue
        }
        
        func oldValue<T>() -> T? {
            return change[NSKeyValueChangeKey.oldKey] as? T
        }
        
        switch keyPath {
        case #keyPath(AVPlayer.currentItem):
            
            let oldItem = oldValue() as AVPlayerItem?
            /* Process old item */ do {
                oldItem?.removeObserver(self,
                                        forKeyPath: #keyPath(AVPlayerItem.status))
                oldItem?.removeObserver(self,
                                        forKeyPath: #keyPath(AVPlayerItem.duration))
                oldItem?.removeObserver(self,
                                        forKeyPath: #keyPath(AVPlayerItem.loadedTimeRanges))
                oldItem?.removeObserver(self,
                                        forKeyPath: #keyPath(AVPlayerItem.timebase))
                if let old = oldItem {
                    center.removeObserver(self,
                                          name: .AVPlayerItemDidPlayToEndTime,
                                          object: old)
                    if let token = accessLogToken {
                        center.removeObserver(token,
                                              name: .AVPlayerItemNewAccessLogEntry,
                                              object: old)
                    }
                }
            }
            
            let newItem = newValue() as AVPlayerItem?
            /* Process new item */ do {
                newItem?.addObserver(self,
                                     forKeyPath: #keyPath(AVPlayerItem.status),
                                     options: [.initial, .new, .old],
                                     context: nil)
                newItem?.addObserver(self,
                                     forKeyPath: #keyPath(AVPlayerItem.duration),
                                     options: [.initial, .new, .old],
                                     context: nil)
                newItem?.addObserver(self,
                                     forKeyPath: #keyPath(AVPlayerItem.loadedTimeRanges),
                                     options: [.initial, .new],
                                     context: nil)
                newItem?.addObserver(self,
                                     forKeyPath: #keyPath(AVPlayerItem.timebase),
                                     options: [.initial, .new],
                                     context: nil)
                
                if let new = newItem {
                    center.addObserver(
                        self,
                        selector: #selector(SystemPlayerObserver.didPlayToEnd),
                        name: .AVPlayerItemDidPlayToEndTime,
                        object: new)
                    accessLogToken = center.addObserver(
                        forName: .AVPlayerItemNewAccessLogEntry,
                        object: nil,
                        queue: nil) { [weak self] notification in
                            guard let item = notification.object as? AVPlayerItem
                                else { return }
                            guard let log = item.accessLog() else { return }
                            guard #available(iOS 10.0, tvOS 10.0, *) else { return }
                            
                            for event in log.events {
                                self?.emit(.didChangeAverageVideoBitrate(to: event.averageVideoBitrate))
                            }
                    }
                }
            }
            
            let oldUrl: URL? = {
                guard let oldItem = oldItem else { return nil }
                guard let asset = oldItem.asset as? AVURLAsset else {
                    fatalError("Asset is not AVURLAsset!")
                }
                return asset.url
            }()
            
            let newUrl: URL? = {
                guard let newItem = newItem else { return nil }
                guard let asset = newItem.asset as? AVURLAsset else {
                    fatalError("Asset is not AVURLAsset!")
                }
                return asset.url
            }()
            
            emit(.didChangeUrl(from: oldUrl, to: newUrl))
        case #keyPath(AVPlayerItem.status):
            let oldStatus = oldValue().flatMap(AVPlayerItemStatus.init)
            guard let newStatus = newValue().flatMap(AVPlayerItemStatus.init) else {
                fatalError("Unexpected nil in AVPlayerItem.status value!")
            }
            
            emit(.didChangeItemStatus(from: oldStatus, to: newStatus))
        case #keyPath(AVPlayerItem.duration):
            emit(.didChangeItemDuration(from: oldValue(), to: newValue()))
        case #keyPath(AVPlayerItem.loadedTimeRanges):
            guard let timeRanges: [CMTimeRange] = newValue() else { return }
            emit(.didChangeLoadedTimeRanges(to: timeRanges))
        case #keyPath(AVPlayerItem.timebase):
            if let token = timebaseRangeToken {
                center.removeObserver(token)
            }

            guard let timebase: CMTimebase = newValue() else { return }

            timebaseRangeToken = center.addObserver(
                forName: kCMTimebaseNotification_EffectiveRateChanged as NSNotification.Name,
                object: timebase,
                queue: nil) { [weak self] notification in
                    guard let object = notification.object else { return }
                    let timebase = object as! CMTimebase
                    let rate = CMTimebaseGetRate(timebase)
                    self?.emit(.didChangeRate(to: Float(rate)))
            }
        default:
            super.observeValue(
                forKeyPath: keyPath,
                of: object,
                change: change,
                context: context)
        }
    }
    
    deinit {
        player.currentItem?.removeObserver(self,
                                           forKeyPath: #keyPath(AVPlayerItem.status))
        player.currentItem?.removeObserver(self,
                                           forKeyPath: #keyPath(AVPlayerItem.duration))
        player.currentItem?.removeObserver(self,
                                           forKeyPath: #keyPath(AVPlayerItem.loadedTimeRanges))
        player.currentItem?.removeObserver(self,
                                           forKeyPath: #keyPath(AVPlayerItem.timebase))
        player.removeObserver(self,
                              forKeyPath: #keyPath(AVPlayer.currentItem))
        center.removeObserver(self,
                              name: .AVPlayerItemDidPlayToEndTime,
                              object: player.currentItem)
        if let token = accessLogToken {
            center.removeObserver(token,
                                  name: .AVPlayerItemNewAccessLogEntry,
                                  object: player.currentItem)
        }
        
        if let token = timebaseRangeToken {
            center.removeObserver(token,
                                  name: kCMTimebaseNotification_EffectiveRateChanged as NSNotification.Name,
                                  object: player.currentItem)
        }
    }
}
