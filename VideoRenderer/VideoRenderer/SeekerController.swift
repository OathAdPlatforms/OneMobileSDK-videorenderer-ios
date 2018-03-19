//  Copyright 2018, Oath Inc.
//  Licensed under the terms of the MIT License. See LICENSE.md file in project root for terms.

import Foundation
import AVFoundation
import CoreMedia

public final class SeekerController {
    public typealias Dispatch = (Event) -> Void
    
    public enum Event {
        case startSeek
        case stopSeek
    }
    
    public let dispatcher: Dispatch
    public let player: AVPlayer
    
    public init(with player: AVPlayer, dispatcher: @escaping Dispatch) {
        self.player = player
        self.dispatcher = dispatcher
    }
    
    public var currentTime: CMTime?
    private var activeSeekingTime: CMTime?
    
    public func process(to newTime: CMTime?) {
        guard self.currentTime != newTime else { return }
        self.currentTime = newTime
        
        guard let time = newTime else { return }
        guard activeSeekingTime == nil else { return }
        activeSeekingTime = time
        dispatcher(.startSeek)
        player.seek(to: time,
                    toleranceBefore: CMTimeMake(0, 1),
                    toleranceAfter: CMTimeMake(1, 2)) { [weak self] _ in
                        guard let `self` = self else { return }
                        self.activeSeekingTime = nil
                        self.dispatcher(.stopSeek)
        }
    }
}
